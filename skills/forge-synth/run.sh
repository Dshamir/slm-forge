#!/bin/bash
# forge-synth: generate Q/A pairs from cleaned pretrain corpus via Claude Haiku.
# Produces chat-format SFT training data. Idempotent (resumes on re-run).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
  echo "usage: $0 <run-id>" >&2; exit 64
fi

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"

# Pick input: prefer audited/cleaned.jsonl, fall back to prepped.jsonl
INPUT=""
for candidate in "$RUN_DIR/audited/cleaned.jsonl" "$RUN_DIR/cleaned.jsonl" "$RUN_DIR/prepped.jsonl"; do
  if [[ -s "$candidate" ]]; then INPUT="$candidate"; break; fi
done

if [[ -z "$INPUT" ]]; then
  echo "forge-synth: no input found in $RUN_DIR (tried audited/cleaned.jsonl, cleaned.jsonl, prepped.jsonl)" >&2
  exit 1
fi

OUT="$RUN_DIR/qa.jsonl"
FILTERED="$RUN_DIR/qa-filtered.jsonl"
STATS="$RUN_DIR/synth-stats.json"

# Load creds
[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "forge-synth: ANTHROPIC_API_KEY not set (check preflight cached /tmp/forge-creds.env)" >&2
  exit 1
fi

# Ensure venv + deps
VENV="${FORGE_VENV:-/tmp/forge-venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV" >&2
fi
"$VENV/bin/pip" install --quiet 'anthropic>=0.40' 2>&1 | tail -1 >&2 || true

SYNTH_PY="${SCRIPT_DIR}/synth.py"

echo "[forge-synth] input=$INPUT output=$OUT" >&2
FORGE_SYNTH_INPUT="$INPUT" \
FORGE_SYNTH_OUTPUT="$OUT" \
FORGE_SYNTH_PROGRESS="$RUN_DIR/synth-progress.json" \
FORGE_SYNTH_ERRORS="$RUN_DIR/synth-errors.jsonl" \
  "$VENV/bin/python" "$SYNTH_PY" 2>&1 | tail -3 >&2 || {
    echo "[forge-synth] synth.py FAILED" >&2
    exit 1
  }

# Rule-based filter for obvious junk Q/As
echo "[forge-synth] filtering junk patterns..." >&2
"$VENV/bin/python" <<PY
import json, re
bad_q = re.compile(r"\b(according to (the |this )?passage|in the passage|the passage)\b", re.I)
generic = re.compile(r"^(How does AI |How is AI |What is AI |Why is AI )", re.I)
n_in = n_out = 0
with open("$OUT") as fi, open("$FILTERED", "w") as fo:
    for line in fi:
        n_in += 1
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        msgs = d.get("messages", [])
        if len(msgs) < 2: continue
        q = msgs[0].get("content","").strip()
        a = msgs[1].get("content","").strip()
        if not q or not a or len(a) < 100: continue
        if bad_q.search(q) or generic.match(q): continue
        fo.write(line)
        n_out += 1
print(f"filter: {n_in} → {n_out} ({round(100*n_out/max(n_in,1),1)}% kept)")
PY

N_QA=$(wc -l < "$FILTERED")
echo "[forge-synth] ✓ $N_QA filtered Q/A pairs" >&2

jq -n --arg out "$FILTERED" --argjson n "$N_QA" --slurpfile p "$RUN_DIR/synth-progress.json" '{
  status:"completed", path:$out, qa_count:$n, synth_stats:$p[0]
}'
