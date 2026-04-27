#!/usr/bin/env bash
# skills/forge-curate/run.sh — CURATE phase implementation.
#
# Reads:
#   - s3://FORGE_BUCKET/forge/<id>/data/raw/
# Writes:
#   - s3://FORGE_BUCKET/forge/<id>/data/curated/shard-0001.jsonl
#   - s3://FORGE_BUCKET/forge/<id>/metadata/curation-stats.json
#   - manifest.artifacts.curated_corpus_s3
#   - Advances phase to SHAPE.
#
# Runs LOCALLY (not on EC2) per brief § D-007 / SKILL_SPECS step 0. This
# keeps curation cheap for ≤500GB corpora. Override FORGE_CURATE_REMOTE=1
# to force remote execution in future.
#
# M2 filters (minimal viable):
#   - Length filter:  drop docs < 50 chars OR > 100,000 chars
#   - Exact-hash dedup: SHA-256 of normalized text
#   - Domain tag:     inject spec.domain into metadata
#
# Deferred to M2+ hardening:
#   - fasttext language detection
#   - perplexity quality filter
#   - MinHash LSH near-dedup
#   - presidio PII scrubbing
# Those add real Python deps (fasttext, datasketch, presidio); the
# minimal pipeline is sufficient for M2 smoke and can be extended without
# touching upstream/downstream skills.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/s3.sh
source "${LIB}/s3.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-curate: forge-id required" >&2
  exit 64
fi

MIN_LEN="${FORGE_CURATE_MIN_LEN:-50}"
MAX_LEN="${FORGE_CURATE_MAX_LEN:-100000}"

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
DOMAIN=$(echo "$MANIFEST" | jq -r '.spec.domain // ""')

# ---- Idempotency -------------------------------------------------------

EXISTING=$(echo "$MANIFEST" | jq -r '.artifacts.curated_corpus_s3 // ""')
if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  echo "forge-curate: curated_corpus_s3 already populated; skipping" >&2
  jq -n --arg fid "$FORGE_ID" '{
    status: "completed",
    next_phase: "SHAPE",
    skill: "forge-curate",
    forge_id: $fid,
    idempotent: true
  }'
  exit 0
fi

# ---- Download raw → filter → write curated ----------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RAW_DIR="$WORK/raw"
CURATED_DIR="$WORK/curated"
mkdir -p "$RAW_DIR" "$CURATED_DIR"

echo "[curate] Syncing raw corpus from S3..." >&2
s3_sync_from "$FORGE_ID" "data/raw/" "$RAW_DIR" >&2

# Aggregate all JSONL + TXT shards into a normalized JSONL stream.
# Each input doc becomes one line of: {id, text, metadata}

TOTAL_IN=0
TOTAL_OUT=0
DROPPED_LENGTH=0
DROPPED_DEDUP=0
declare -A SEEN_HASHES=()

OUT_SHARD="$CURATED_DIR/shard-0001.jsonl"

while IFS= read -r -d '' file; do
  ext="${file##*.}"
  case "$ext" in
    jsonl)
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        TOTAL_IN=$((TOTAL_IN + 1))
        # Pull text field; fall back to entire line if schema is unknown
        text=$(echo "$line" | jq -r '.text // .content // .document // .body // empty' 2>/dev/null || echo "")
        if [[ -z "$text" ]]; then
          # Try to treat the whole line as text
          text="$line"
        fi
        id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null || echo "")

        # Length filter
        len=${#text}
        if (( len < MIN_LEN || len > MAX_LEN )); then
          DROPPED_LENGTH=$((DROPPED_LENGTH + 1))
          continue
        fi

        # Exact hash dedup
        hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
        if [[ -n "${SEEN_HASHES[$hash]:-}" ]]; then
          DROPPED_DEDUP=$((DROPPED_DEDUP + 1))
          continue
        fi
        SEEN_HASHES[$hash]=1

        [[ -z "$id" ]] && id="doc-$(printf '%06d' $TOTAL_IN)"

        jq -cn \
          --arg id "$id" \
          --arg text "$text" \
          --arg domain "$DOMAIN" \
          --arg source_file "$(basename "$file")" \
          --arg hash "$hash" \
          '{
            id: $id,
            text: $text,
            metadata: {
              domain: $domain,
              source_file: $source_file,
              text_hash_sha256: $hash,
              length: ($text | length)
            }
          }' >> "$OUT_SHARD"
        TOTAL_OUT=$((TOTAL_OUT + 1))
      done < "$file"
      ;;
    txt)
      # One paragraph per line
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        TOTAL_IN=$((TOTAL_IN + 1))
        text="$line"
        len=${#text}
        if (( len < MIN_LEN || len > MAX_LEN )); then
          DROPPED_LENGTH=$((DROPPED_LENGTH + 1))
          continue
        fi
        hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
        if [[ -n "${SEEN_HASHES[$hash]:-}" ]]; then
          DROPPED_DEDUP=$((DROPPED_DEDUP + 1))
          continue
        fi
        SEEN_HASHES[$hash]=1

        id="doc-$(printf '%06d' $TOTAL_IN)"
        jq -cn \
          --arg id "$id" \
          --arg text "$text" \
          --arg domain "$DOMAIN" \
          --arg source_file "$(basename "$file")" \
          --arg hash "$hash" \
          '{
            id: $id,
            text: $text,
            metadata: {
              domain: $domain,
              source_file: $source_file,
              text_hash_sha256: $hash,
              length: ($text | length)
            }
          }' >> "$OUT_SHARD"
        TOTAL_OUT=$((TOTAL_OUT + 1))
      done < "$file"
      ;;
    *)
      echo "[curate] skipping unrecognized file type: $file" >&2
      ;;
  esac
done < <(find "$RAW_DIR" -type f \( -name '*.jsonl' -o -name '*.txt' \) -not -name '_*' -print0)

# Sanity: bail if we lost more than 90% of docs (likely wrong schema)
if (( TOTAL_IN > 0 )); then
  kept_pct=$(awk -v i="$TOTAL_IN" -v o="$TOTAL_OUT" 'BEGIN{printf "%.1f", (o/i)*100}')
else
  kept_pct="0.0"
fi

KEEP_RATIO_OK=$(awk -v i="$TOTAL_IN" -v o="$TOTAL_OUT" 'BEGIN{print (i==0 || o/i >= 0.1) ? "yes" : "no"}')
if [[ "$KEEP_RATIO_OK" != "yes" ]]; then
  echo "forge-curate: output < 10% of input — likely filter misconfiguration (input=$TOTAL_IN, output=$TOTAL_OUT)" >&2
  # Not a hard fail in M2; log but proceed.
fi

if (( TOTAL_OUT == 0 )); then
  echo "forge-curate: zero documents after filtering" >&2
  exit 1
fi

# ---- Stats file + upload ----------------------------------------------

STATS_FILE="$WORK/curation-stats.json"
jq -n \
  --argjson input_count "$TOTAL_IN" \
  --argjson output_count "$TOTAL_OUT" \
  --argjson dropped_length "$DROPPED_LENGTH" \
  --argjson dropped_dedup "$DROPPED_DEDUP" \
  --arg kept_pct "$kept_pct" \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg min_len "$MIN_LEN" --arg max_len "$MAX_LEN" \
  '{
    input_doc_count: $input_count,
    output_doc_count: $output_count,
    kept_percent: $kept_pct,
    dropped: {
      length_filter: $dropped_length,
      dedup:         $dropped_dedup,
      lang_filter:   null,
      quality_filter: null,
      pii_filter:    null
    },
    filters_applied: ["length", "exact_hash_dedup", "domain_tag"],
    filters_deferred: ["lang", "quality", "near_dedup", "pii"],
    thresholds: { min_len: ($min_len|tonumber), max_len: ($max_len|tonumber) },
    completed_at: $completed_at
  }' > "$STATS_FILE"

echo "[curate] input=$TOTAL_IN, output=$TOTAL_OUT, dropped_len=$DROPPED_LENGTH, dropped_dedup=$DROPPED_DEDUP (kept $kept_pct%)" >&2

export FORGE_PHASE="CURATE"
s3_put "$FORGE_ID" "$OUT_SHARD" "data/curated/shard-0001.jsonl"
s3_put "$FORGE_ID" "$STATS_FILE" "metadata/curation-stats.json"

CURATED_URI=$(s3_uri_for "$FORGE_ID" "data/curated/")

manifest_patch "$FORGE_ID" "
  .artifacts.curated_corpus_s3 = \"${CURATED_URI}\"
  | .phase = \"SHAPE\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"SHAPE\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg uri "$CURATED_URI" \
  --argjson in_count "$TOTAL_IN" \
  --argjson out_count "$TOTAL_OUT" \
  '{
    status: "completed",
    next_phase: "SHAPE",
    skill: "forge-curate",
    forge_id: $fid,
    curated_corpus_s3: $uri,
    input_doc_count: $in_count,
    output_doc_count: $out_count
  }'
