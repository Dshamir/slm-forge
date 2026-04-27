#!/usr/bin/env bash
# skills/forge-shape/run.sh — SHAPE phase implementation.
#
# Reads:
#   - s3://FORGE_BUCKET/forge/<id>/data/curated/
#   - manifest.plan.{base_model, chat_template, tokenizer_strategy}
# Writes:
#   - s3://.../data/shaped/train.jsonl
#   - s3://.../data/shaped/val.jsonl
#   - s3://.../data/shaped/test.jsonl
#   - s3://.../metadata/tokenizer-stats.json
#   - manifest.artifacts.shaped_corpus_s3
#   - Advances phase to PROVISION.
#
# Shaping steps:
#   1. Download curated shards.
#   2. Convert each doc to the unified internal schema (D-007):
#        {id, domain, format, messages[], raw_text, metadata}
#      - messages[] is populated if the doc is chat/instruction-formatted
#      - raw_text is populated for pretrain-style docs
#   3. Shuffle (deterministic, seeded on forge_id).
#   4. Split 90/5/5 (configurable via FORGE_SHAPE_SPLIT).
#   5. Emit train.jsonl / val.jsonl / test.jsonl.
#   6. Compute approximate token stats (chars/4 heuristic for English).
#      Real tokenization is deferred to forge-train's data loader (Unsloth
#      or HF Trainer applies the base model's tokenizer at training time).
#      This keeps forge-shape dependency-free (no heavyweight HF import).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/s3.sh
source "${LIB}/s3.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-shape: forge-id required" >&2
  exit 64
fi

SPLIT="${FORGE_SHAPE_SPLIT:-90/5/5}"  # train/val/test percentages

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
DOMAIN=$(echo "$MANIFEST" | jq -r '.spec.domain // ""')
BASE_MODEL=$(echo "$MANIFEST" | jq -r '.plan.base_model // ""')
CHAT_TEMPLATE=$(echo "$MANIFEST" | jq -r '.plan.chat_template // "chatml"')
TOKENIZER_STRAT=$(echo "$MANIFEST" | jq -r '.plan.tokenizer_strategy // "reuse-base"')

EXISTING=$(echo "$MANIFEST" | jq -r '.artifacts.shaped_corpus_s3 // ""')
if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  echo "forge-shape: shaped_corpus_s3 already populated; skipping" >&2
  jq -n --arg fid "$FORGE_ID" '{
    status: "completed",
    next_phase: "PROVISION",
    skill: "forge-shape",
    forge_id: $fid,
    idempotent: true
  }'
  exit 0
fi

# ---- Locate input corpus ----------------------------------------------
# Prefer local v2 artifacts over the v1 S3 `data/curated/` path — v2 flow
# produces qa-filtered.jsonl (synth) or audited/cleaned.jsonl (audit)
# directly in the run dir. Still uploads shaped output to S3 because
# forge-train needs shaped_corpus_s3 to pull onto EC2.
REPO_ROOT="${SCRIPT_DIR}/../../.."
# Forge-id convention on v2 path: "v2-<run-id>". Strip prefix to find RUN_DIR.
RUN_ID_LOCAL="${FORGE_ID#v2-}"
RUN_DIR_LOCAL="${REPO_ROOT}/slm-forge/.runs/${RUN_ID_LOCAL}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CURATED_DIR="$WORK/curated"
SHAPED_DIR="$WORK/shaped"
mkdir -p "$CURATED_DIR" "$SHAPED_DIR"

INPUT_FILE=""
for candidate in \
  "$RUN_DIR_LOCAL/qa-filtered.jsonl" \
  "$RUN_DIR_LOCAL/qa.jsonl" \
  "$RUN_DIR_LOCAL/audited/cleaned.jsonl" \
  "$RUN_DIR_LOCAL/prepped.jsonl"
do
  if [[ -s "$candidate" ]]; then INPUT_FILE="$candidate"; break; fi
done

if [[ -n "$INPUT_FILE" ]]; then
  echo "[shape] using local v2 input: $INPUT_FILE" >&2
  cp "$INPUT_FILE" "$CURATED_DIR/input.jsonl"
else
  echo "[shape] no local v2 input found — falling back to S3 data/curated/..." >&2
  s3_sync_from "$FORGE_ID" "data/curated/" "$CURATED_DIR" >&2
fi

# Unified schema conversion. For the tiny fixture (plain docs with just
# {id, text}), "format"="pretrain" and raw_text is populated. Chat/
# instruction data would be detected here via presence of role fields.

UNIFIED="$WORK/unified.jsonl"
: > "$UNIFIED"

TOTAL=0
TOTAL_CHARS=0
MAX_LEN=0
MIN_LEN=999999999

while IFS= read -r -d '' shard; do
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    TOTAL=$((TOTAL + 1))
    text=$(echo "$line" | jq -r '.text // .content // ""')
    id=$(echo "$line" | jq -r '.id // empty')
    [[ -z "$id" ]] && id="doc-$(printf '%06d' $TOTAL)"
    meta=$(echo "$line" | jq -c '.metadata // {}')

    # Detect format: if the doc has .messages (role+content array) treat
    # as chat/instruction; otherwise pretrain.
    if echo "$line" | jq -e '.messages | type == "array"' >/dev/null 2>&1; then
      fmt="chat"
      messages=$(echo "$line" | jq -c '.messages')
      raw=""
    else
      fmt="pretrain"
      messages="[]"
      raw="$text"
    fi

    len=${#text}
    TOTAL_CHARS=$((TOTAL_CHARS + len))
    (( len > MAX_LEN )) && MAX_LEN=$len
    (( len < MIN_LEN )) && MIN_LEN=$len

    jq -cn \
      --arg id "$id" \
      --arg domain "$DOMAIN" \
      --arg format "$fmt" \
      --argjson messages "$messages" \
      --arg raw "$raw" \
      --argjson meta "$meta" \
      '{
        id: $id,
        domain: $domain,
        format: $format,
        messages: $messages,
        raw_text: $raw,
        metadata: $meta
      }' >> "$UNIFIED"
  done < "$shard"
done < <(find "$CURATED_DIR" -type f -name '*.jsonl' -not -name '_*' -print0)

if (( TOTAL == 0 )); then
  echo "forge-shape: zero curated docs found" >&2
  exit 1
fi

# ---- Stratified split by metadata.subtopic ----------------------------
# Within-subtopic deterministic shuffle (seeded on forge_id+subtopic),
# then 90/5/5 per subtopic, then a final cross-subtopic interleave so
# training doesn't see all-of-X then all-of-Y. Ensures every subtopic
# is represented in val/test (required for per-subtopic eval).
IFS='/' read -r TRAIN_PCT VAL_PCT TEST_PCT <<< "$SPLIT"
TRAIN_PCT="${TRAIN_PCT:-90}"
VAL_PCT="${VAL_PCT:-5}"
TEST_PCT="${TEST_PCT:-5}"

STRAT_REPORT="$WORK/shape-strat-report.json"
python3 - <<PY
import json, random, hashlib, sys
from collections import defaultdict

seed_str = "$FORGE_ID"
train_pct, val_pct = $TRAIN_PCT, $VAL_PCT

groups = defaultdict(list)
with open("$UNIFIED") as f:
    for line in f:
        d = json.loads(line)
        st = d.get("metadata", {}).get("subtopic", "unmapped")
        groups[st].append(line)

def stable_seed(s):
    return int(hashlib.sha256(s.encode()).hexdigest()[:16], 16)

train_lines, val_lines, test_lines = [], [], []
strat = {}
for st in sorted(groups):
    rows = groups[st]
    rng = random.Random(stable_seed(seed_str + ":" + st))
    rng.shuffle(rows)
    n = len(rows)
    n_train = n * train_pct // 100
    n_val = n * val_pct // 100
    train_lines.extend(rows[:n_train])
    val_lines.extend(rows[n_train:n_train + n_val])
    test_lines.extend(rows[n_train + n_val:])
    strat[st] = {"total": n, "train": n_train, "val": n_val,
                 "test": n - n_train - n_val}

for buf, label in ((train_lines, "train"), (val_lines, "val"), (test_lines, "test")):
    random.Random(stable_seed(seed_str + ":" + label + "_final")).shuffle(buf)

open("$SHAPED_DIR/train.jsonl", "w").writelines(train_lines)
open("$SHAPED_DIR/val.jsonl",   "w").writelines(val_lines)
open("$SHAPED_DIR/test.jsonl",  "w").writelines(test_lines)

total = sum(g["total"] for g in strat.values())
report = {"total": total, "by_subtopic": strat,
          "split_pct": {"train": train_pct, "val": val_pct, "test": $TEST_PCT}}
with open("$STRAT_REPORT", "w") as f:
    json.dump(report, f, indent=2)

print(f"[shape] stratified split: total={total}", file=sys.stderr)
for st, info in sorted(strat.items()):
    print(f"  {st:24s} total={info['total']:>6d} train={info['train']:>5d} val={info['val']:>4d} test={info['test']:>4d}", file=sys.stderr)
PY

TRAIN_LINES=$(wc -l < "$SHAPED_DIR/train.jsonl")
VAL_LINES=$(wc -l < "$SHAPED_DIR/val.jsonl")
TEST_LINES=$(wc -l < "$SHAPED_DIR/test.jsonl")

# ---- Token stats (char/4 approximation) -------------------------------
# For English the chars/4 rule of thumb is within ±15% of real BPE/
# SentencePiece counts. Real tokenization is applied by forge-train at
# data-loader time using the base model's tokenizer.

APPROX_TOKENS=$(( TOTAL_CHARS / 4 ))
MEAN_CHARS=0
if (( TOTAL > 0 )); then
  MEAN_CHARS=$(( TOTAL_CHARS / TOTAL ))
fi

STATS_FILE="$WORK/tokenizer-stats.json"
jq -n \
  --arg base_model "$BASE_MODEL" \
  --arg chat_template "$CHAT_TEMPLATE" \
  --arg tokenizer_strategy "$TOKENIZER_STRAT" \
  --argjson total_docs "$TOTAL" \
  --argjson train_docs "$TRAIN_LINES" \
  --argjson val_docs "$VAL_LINES" \
  --argjson test_docs "$TEST_LINES" \
  --argjson total_chars "$TOTAL_CHARS" \
  --argjson approx_total_tokens "$APPROX_TOKENS" \
  --argjson mean_doc_chars "$MEAN_CHARS" \
  --argjson max_doc_chars "$MAX_LEN" \
  --argjson min_doc_chars "$MIN_LEN" \
  --arg split "$SPLIT" \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    base_model: $base_model,
    chat_template: $chat_template,
    tokenizer_strategy: $tokenizer_strategy,
    tokenization_mode: "deferred-to-forge-train",
    total_doc_count: $total_docs,
    split: {
      mode: $split,
      train_docs: $train_docs,
      val_docs: $val_docs,
      test_docs: $test_docs
    },
    char_stats: {
      total_chars: $total_chars,
      mean_doc_chars: $mean_doc_chars,
      max_doc_chars: $max_doc_chars,
      min_doc_chars: $min_doc_chars
    },
    token_stats: {
      approximation: "chars/4 (English ±15% of BPE/SentencePiece)",
      approx_total_tokens: $approx_total_tokens,
      real_tokenization_deferred_to: "forge-train (applies base model tokenizer at data-loader time)"
    },
    completed_at: $completed_at
  }' > "$STATS_FILE"

# ---- Upload -----------------------------------------------------------

echo "[shape] total=$TOTAL train=$TRAIN_LINES val=$VAL_LINES test=$TEST_LINES approx_tokens=$APPROX_TOKENS" >&2

export FORGE_PHASE="SHAPE"
s3_put "$FORGE_ID" "$SHAPED_DIR/train.jsonl" "data/shaped/train.jsonl"
s3_put "$FORGE_ID" "$SHAPED_DIR/val.jsonl"   "data/shaped/val.jsonl"
s3_put "$FORGE_ID" "$SHAPED_DIR/test.jsonl"  "data/shaped/test.jsonl"
s3_put "$FORGE_ID" "$STATS_FILE" "metadata/tokenizer-stats.json"

SHAPED_URI=$(s3_uri_for "$FORGE_ID" "data/shaped/")

manifest_patch "$FORGE_ID" "
  .artifacts.shaped_corpus_s3 = \"${SHAPED_URI}\"
  | .phase = \"PROVISION\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"PROVISION\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"pending\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg uri "$SHAPED_URI" \
  --argjson total "$TOTAL" \
  --argjson train "$TRAIN_LINES" \
  --argjson val "$VAL_LINES" \
  --argjson test "$TEST_LINES" \
  --argjson tokens "$APPROX_TOKENS" \
  '{
    status: "completed",
    next_phase: "PROVISION",
    skill: "forge-shape",
    forge_id: $fid,
    shaped_corpus_s3: $uri,
    total_docs: $total,
    split: {train: $train, val: $val, test: $test},
    approx_total_tokens: $tokens
  }'
