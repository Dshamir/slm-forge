#!/bin/bash
# forge-audit: P-1 contamination gate (v2-native).
# Hard-fails the forge before any GPU spend if the prepped corpus contains
# LLM slop, near-duplicates, off-domain content, or insufficient clean tokens.
#
# Inputs:  $RUN_DIR/prepped.jsonl  (from forge-prep)
# Outputs: $RUN_DIR/audited/cleaned.jsonl  (consumed by forge-synth)
#          $RUN_DIR/audit-report.json
# Phase:   PREP → [AUDIT] → SYNTH

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."

RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
  echo "usage: $0 <run-id>" >&2; exit 64
fi
RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
PLAN="$RUN_DIR/plan.json"
INPUT="$RUN_DIR/prepped.jsonl"
AUDITED_DIR="$RUN_DIR/audited"
OUT_CLEAN="$AUDITED_DIR/cleaned.jsonl"
OUT_REPORT="$RUN_DIR/audit-report.json"

if [[ ! -f "$PLAN" ]]; then
  echo "forge-audit: missing plan.json at $PLAN" >&2; exit 1
fi
if [[ ! -s "$INPUT" ]]; then
  echo "forge-audit: no input at $INPUT (forge-prep did not produce prepped.jsonl)" >&2
  exit 1
fi

# Idempotent skip if already audited
if [[ -s "$OUT_CLEAN" && -s "$OUT_REPORT" ]]; then
  N=$(wc -l < "$OUT_CLEAN")
  echo "[forge-audit] audited/cleaned.jsonl exists ($N docs) — skipping" >&2
  jq -n --arg out "$OUT_CLEAN" --arg rep "$OUT_REPORT" --argjson n "$N" '{
    status:"skipped", reason:"already-audited",
    path:$out, report:$rep, doc_count:$n
  }'
  exit 0
fi

mkdir -p "$AUDITED_DIR"

DOMAIN=$(jq -r '.domain // "general"' "$PLAN")
MIN_TOKENS="${FORGE_AUDIT_MIN_TOKENS:-500000}"
MIN_DENSITY="${FORGE_AUDIT_MIN_DENSITY:-0.008}"
MIN_CATEGORIES="${FORGE_AUDIT_MIN_CATEGORIES:-2}"
MIN_ABSOLUTE="${FORGE_AUDIT_MIN_ABSOLUTE:-5}"

N_INPUT=$(wc -l < "$INPUT")
echo "[forge-audit] $N_INPUT input docs from $INPUT (domain=$DOMAIN)" >&2

# Venv for datasketch (MinHash LSH deduplication)
VENV="${FORGE_AUDIT_VENV:-/tmp/forge-audit-venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[forge-audit] creating venv at $VENV (one-time)..." >&2
  python3 -m venv "$VENV" >&2
  "$VENV/bin/pip" install --quiet datasketch >&2
fi

AUDIT_SCRIPT="${SCRIPT_DIR}/audit.py"

FORGE_AUDIT_INPUT="$INPUT" \
FORGE_AUDIT_OUT_CLEAN="$OUT_CLEAN" \
FORGE_AUDIT_OUT_REPORT="$OUT_REPORT" \
FORGE_AUDIT_DOMAIN="$DOMAIN" \
FORGE_AUDIT_MIN_TOKENS="$MIN_TOKENS" \
FORGE_AUDIT_MIN_DENSITY="$MIN_DENSITY" \
FORGE_AUDIT_MIN_CATEGORIES="$MIN_CATEGORIES" \
FORGE_AUDIT_MIN_ABSOLUTE="$MIN_ABSOLUTE" \
  "$VENV/bin/python" "$AUDIT_SCRIPT" >&2 || {
  echo "[forge-audit] audit script failed — see $OUT_REPORT" >&2
  [[ -f "$OUT_REPORT" ]] && cat "$OUT_REPORT" >&2 || true
  exit 1
}

KEPT_TOKENS=$(jq -r '.output.approx_tokens' "$OUT_REPORT")
KEPT_PCT=$(jq -r '.output.kept_pct' "$OUT_REPORT")
PASSES=$(jq -r '.kill_condition.passes' "$OUT_REPORT")
N_CLEAN=$(wc -l < "$OUT_CLEAN")

echo "[forge-audit] ✓ kept=${KEPT_PCT}% tokens=${KEPT_TOKENS} kill_passes=${PASSES} docs=${N_CLEAN}" >&2

jq -n \
  --arg out "$OUT_CLEAN" --arg rep "$OUT_REPORT" \
  --argjson n "$N_CLEAN" --argjson tokens "$KEPT_TOKENS" \
  --argjson kept_pct "$KEPT_PCT" --argjson passes "$PASSES" \
  '{
    status: "completed",
    next_phase: "synth",
    path: $out,
    report: $rep,
    doc_count: $n,
    clean_tokens: $tokens,
    kept_pct: $kept_pct,
    kill_passes: $passes
  }'
