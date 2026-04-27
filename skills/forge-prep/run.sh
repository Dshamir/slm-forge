#!/bin/bash
# forge-prep: walks raw doc dir → unified pretrain JSONL via prep-orchestrator.
# Uses plugin architecture — installs only the tiers the corpus needs per
# analysis.json.extraction_profile.plugins_needed.
# Idempotent — skips if prepped.jsonl already exists.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
  echo "usage: $0 <run-id>" >&2; exit 64
fi

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
ANALYSIS="$RUN_DIR/analysis.json"
PLAN="$RUN_DIR/plan.json"

if [[ ! -f "$ANALYSIS" || ! -f "$PLAN" ]]; then
  echo "forge-prep: missing analysis.json or plan.json in $RUN_DIR" >&2
  exit 1
fi

TARGET=$(jq -r '.target_dir' "$ANALYSIS")
OUT="$RUN_DIR/prepped.jsonl"
STATS="$RUN_DIR/prepped-stats.json"

if [[ -s "$OUT" ]]; then
  N=$(wc -l < "$OUT")
  echo "[forge-prep] $OUT exists ($N docs) — skipping" >&2
  jq -n --arg out "$OUT" --argjson n "$N" '{
    status:"skipped", reason:"already-prepped", path:$out, doc_count:$n
  }'
  exit 0
fi

PREP_SCRIPT="${REPO_ROOT}/slm-forge/scripts/prep-orchestrator.py"

# Ensure venv exists
VENV="${FORGE_VENV:-/tmp/forge-venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[forge-prep] creating venv at $VENV (one-time)..." >&2
  python3 -m venv "$VENV" >&2
fi

# --- Tiered install: read extraction_profile.plugins_needed from analysis ---
# Tiers:
#   tier-lite   (always):    pdfplumber python-docx python-pptx beautifulsoup4
#                             lxml odfpy ebooklib nbformat openpyxl pyarrow
#                             striprtf py7zr rarfile
#   tier-ocr    (conditional): pytesseract Pillow pillow-heif + apt tesseract-ocr
#   tier-av     (conditional): faster-whisper + apt ffmpeg

PLUGINS_NEEDED=$(jq -r '.extraction_profile.plugins_needed // []' "$ANALYSIS")
NEED_OCR=$(echo "$PLUGINS_NEEDED" | jq -r 'contains(["tier-ocr"])')
NEED_AV=$(echo "$PLUGINS_NEEDED" | jq -r 'contains(["tier-av"])')

echo "[forge-prep] installing tier-lite (always)..." >&2
"$VENV/bin/pip" install --quiet \
  pdfplumber python-docx python-pptx \
  beautifulsoup4 lxml odfpy ebooklib nbformat \
  openpyxl pyarrow striprtf py7zr 2>&1 | tail -2 >&2 || true

# rarfile is optional (needs unrar system binary); install but don't fail
"$VENV/bin/pip" install --quiet rarfile 2>&1 | tail -1 >&2 || true

if [[ "$NEED_OCR" == "true" ]]; then
  echo "[forge-prep] installing tier-ocr (images detected)..." >&2
  "$VENV/bin/pip" install --quiet pytesseract Pillow pillow-heif 2>&1 | tail -2 >&2 || true
  # apt-install tesseract (requires sudo) — best-effort
  if ! command -v tesseract >/dev/null 2>&1; then
    echo "[forge-prep] NOTE: tesseract-ocr binary not found on PATH." >&2
    echo "[forge-prep]       Install with: sudo apt install -y tesseract-ocr tesseract-ocr-eng" >&2
    echo "[forge-prep]       OR set FORGE_DISABLE_OCR=1 to skip image extraction." >&2
  fi
fi

if [[ "$NEED_AV" == "true" ]]; then
  echo "[forge-prep] installing tier-av (audio/video detected)..." >&2
  "$VENV/bin/pip" install --quiet faster-whisper 2>&1 | tail -2 >&2 || true
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "[forge-prep] NOTE: ffmpeg not found on PATH." >&2
    echo "[forge-prep]       Install with: sudo apt install -y ffmpeg" >&2
    echo "[forge-prep]       OR set FORGE_DISABLE_TRANSCRIBE=1 to skip audio/video extraction." >&2
  fi
fi

SUBTOPIC_MAP="$RUN_DIR/subtopic-map.json"
SUBTOPIC_ARG=()
if [[ -f "$SUBTOPIC_MAP" ]]; then
  SUBTOPIC_ARG=(--subtopic-map "$SUBTOPIC_MAP")
  echo "[forge-prep] using subtopic map: $SUBTOPIC_MAP" >&2
else
  echo "[forge-prep] no subtopic-map.json; rows will get subtopic='unmapped'" >&2
fi

echo "[forge-prep] extracting text from $TARGET..." >&2
# Pass through FORGE_DISABLE_* env vars so plugins respect opt-outs
"$VENV/bin/python" "$PREP_SCRIPT" --input "$TARGET" --output "$OUT" --stats "$STATS" "${SUBTOPIC_ARG[@]}" 2>&1 | tail -30 >&2

if [[ ! -s "$OUT" ]]; then
  echo "[forge-prep] no docs produced — check input path + extraction errors above" >&2
  exit 1
fi

N=$(wc -l < "$OUT")
TOK=$(jq -r '.approx_total_tokens // 0' "$STATS")
echo "[forge-prep] ✓ $N docs, ~$(printf "%'d" $TOK) tokens" >&2

jq -n --arg out "$OUT" --argjson n "$N" --argjson tok "$TOK" --slurpfile s "$STATS" '{
  status:"completed", path:$out, doc_count:$n, approx_tokens:$tok, stats:$s[0]
}'
