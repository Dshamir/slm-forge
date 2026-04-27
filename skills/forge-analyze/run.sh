#!/bin/bash
# forge-analyze: walks target dir, classifies content, detects format,
# suggests domain via Claude. Output drives forge-plan's phase derivation.
set -uo pipefail
# Note: deliberately NOT using `set -e` — find | head pipelines emit SIGPIPE
# which would abort. We handle errors explicitly per-step instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

TARGET="${1:-}"
DOMAIN_OVERRIDE="${2:-}"
RUN_ID="${FORGE_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)}"
RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"

if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <target-dir> [domain-override]" >&2
  exit 64
fi
if [[ ! -e "$TARGET" ]]; then
  echo "forge-analyze: target does not exist: $TARGET" >&2
  exit 1
fi
TARGET=$(realpath "$TARGET")

mkdir -p "$RUN_DIR"
echo "$RUN_ID" > "$RUN_DIR/run-id"
echo "$TARGET" > "$RUN_DIR/target"

# Load creds for Claude
[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

# --- 0. Multi-source config detection (v2.2) -------------------------------
# Single .yaml file with `sources:` key → multi-source-config path.
# Triggers ingest phase first (instead of prep) and skips standard analyze.
if [[ -f "$TARGET" ]] && [[ "$TARGET" =~ \.(ya?ml)$ ]]; then
  # Multi-source-config requires BOTH a top-level `sources:` key AND a
  # `kind:` line (every source has one). This avoids false-positives on
  # Helm Chart.yaml, k8s manifests, GitHub Actions workflows, ArgoCD
  # configs and other yamls that happen to have `version:` or `sources:`
  # at the top.
  if grep -qE '^sources:' "$TARGET" 2>/dev/null && \
     grep -qE '^[[:space:]]+kind:[[:space:]]+(local_dir|archive|http|jsonl|hf_dataset|database|git|s3|gcs|azure)' "$TARGET" 2>/dev/null; then
    DOMAIN_OVERRIDE_FROM_CONFIG=$(grep -oP '(?<=^domain:\s)[^\s]+' "$TARGET" 2>/dev/null | head -1 || true)
    [[ -n "$DOMAIN_OVERRIDE_FROM_CONFIG" && -z "$DOMAIN_OVERRIDE" ]] && DOMAIN_OVERRIDE="$DOMAIN_OVERRIDE_FROM_CONFIG"

    # Cache config alongside run dir so dispatch can find it
    cp "$TARGET" "$RUN_DIR/config.yaml"

    DOMAIN_LABEL="${DOMAIN_OVERRIDE:-multi-source}"
    ANALYSIS=$(jq -n \
      --arg run_id "$RUN_ID" \
      --arg target "$TARGET" \
      --arg dom "$DOMAIN_LABEL" \
      '{
        run_id: $run_id,
        target_dir: $target,
        input_inventory: {by_ext: {"yaml": 1}, total_files: 1, total_size_mb: 0,
                          estimated_raw_tokens: 0},
        detected_format: "multi-source-config",
        format_evidence: {is_config: true, config_path: $target},
        domain_signal: {label: $dom, confidence: 1.0, via: "config-or-cli"},
        needs: ["ingest","audit","synth","shape","plan_fit","provision","bootstrap","train","monitor","eval","quantize","register","card_validator","smoketest","publish","teardown","report"],
        skip_phases: ["prep"],
        extraction_profile: {plugins_needed: [], disabled_by_env: [],
                             counts: {images:0, audio_video:0, mesh:0, binary:0},
                             estimated_extraction_time_min: 0,
                             note: "ingest phase reads config.yaml; per-source extraction time deferred to ingest stats"}
      }')
    echo "$ANALYSIS" > "$RUN_DIR/analysis.json"
    echo "$ANALYSIS"
    exit 0
  fi
fi

# --- 1. Inventory ----------------------------------------------------------
echo "[analyze] inventorying..." >&2

# Count files by extension. -L follows symlinks. Cap at 50k files (sanity).
INV=$(find -L "$TARGET" -maxdepth 8 -type f 2>/dev/null | head -50000 | \
  awk -F. '{ext=tolower($NF); if (length(ext)<=5) print ext}' | sort | uniq -c | \
  awk '{print "\""$2"\":"$1}' | paste -sd, -)
INV="{${INV:-}}"

TOTAL_FILES=$(find -L "$TARGET" -maxdepth 8 -type f 2>/dev/null | head -50000 | wc -l)
TOTAL_BYTES=$(find -L "$TARGET" -maxdepth 8 -type f -exec du -bc {} + 2>/dev/null | tail -1 | awk '{print $1}')
[[ -z "$TOTAL_BYTES" ]] && TOTAL_BYTES=0
TOTAL_MB=$((TOTAL_BYTES / 1024 / 1024))

# Token estimate: chars ÷ 4. For binaries (PDF/DOCX) we use bytes ÷ 16 as a
# very rough approximation (PDFs are ~3-4x bloat over extracted text).
EST_TOKENS=$((TOTAL_BYTES / 16))

# --- 2. Format detection ---------------------------------------------------
echo "[analyze] detecting format..." >&2
DETECTED_FORMAT="raw-documents"
FMT_EVIDENCE="{}"

# If only JSONL files (or it's a single JSONL file), peek inside
JSONL_FILES=$(find -L "$TARGET" -maxdepth 8 -type f -iname "*.jsonl" 2>/dev/null | head -5)

if [[ -n "$JSONL_FILES" ]]; then
  FIRST_JSONL=$(echo "$JSONL_FILES" | head -1)
  FIRST_LINE=$(head -1 "$FIRST_JSONL" 2>/dev/null || echo "{}")
  if echo "$FIRST_LINE" | jq -e 'has("messages") and (.messages | type == "array")' >/dev/null 2>&1; then HAS_MESSAGES=yes; else HAS_MESSAGES=no; fi
  if echo "$FIRST_LINE" | jq -e 'has("text") and (.text | type == "string")' >/dev/null 2>&1; then HAS_TEXT=yes; else HAS_TEXT=no; fi

  # Sniff every JSONL in the corpus (up to 5 files, first line each) to
  # catch mixed chat/pretrain corpora — shape + synth assume a consistent
  # format and silently mis-behave otherwise. Bail hard if mixed.
  MIXED_FORMATS=no
  CHAT_SEEN=no
  PRETRAIN_SEEN=no
  while IFS= read -r jf; do
    [[ -z "$jf" ]] && continue
    jl_first=$(head -1 "$jf" 2>/dev/null || echo "{}")
    if echo "$jl_first" | jq -e 'has("messages") and (.messages | type == "array")' >/dev/null 2>&1; then
      CHAT_SEEN=yes
    elif echo "$jl_first" | jq -e 'has("text") and (.text | type == "string")' >/dev/null 2>&1; then
      PRETRAIN_SEEN=yes
    fi
  done <<< "$JSONL_FILES"
  if [[ "$CHAT_SEEN" == "yes" && "$PRETRAIN_SEEN" == "yes" ]]; then
    MIXED_FORMATS=yes
    echo "[analyze] FATAL: corpus has BOTH chat (messages) and pretrain" >&2
    echo "  (text) JSONL files. Shape + synth cannot handle a mixed format." >&2
    echo "  Split them into separate runs or pre-merge to one schema." >&2
    exit 65
  fi

  # If target IS a single JSONL (not a dir of mixed files), pick format off it
  if [[ -f "$TARGET" && "$TARGET" == *.jsonl ]] || (( TOTAL_FILES == 1 )); then
    if [[ "$HAS_MESSAGES" == "yes" ]]; then
      DETECTED_FORMAT="chat-jsonl"
    elif [[ "$HAS_TEXT" == "yes" ]]; then
      DETECTED_FORMAT="pretrain-jsonl"
    fi
  else
    # Mixed dir
    NON_JSONL=$(find -L "$TARGET" -maxdepth 8 -type f \
      -not -iname "*.jsonl" -not -iname "*.md" -not -iname "*.json" 2>/dev/null | head -5)
    if [[ -z "$NON_JSONL" ]]; then
      # only jsonl/md/json — treat as jsonl
      [[ "$HAS_MESSAGES" == "yes" ]] && DETECTED_FORMAT="chat-jsonl" || DETECTED_FORMAT="pretrain-jsonl"
    else
      DETECTED_FORMAT="mixed"
    fi
  fi
  FMT_EVIDENCE=$(jq -nc --arg first "$FIRST_JSONL" --arg has_msg "$HAS_MESSAGES" --arg has_txt "$HAS_TEXT" \
    '{first_jsonl: $first, has_messages: ($has_msg=="yes"), has_text_field: ($has_txt=="yes")}')
fi

# If no JSONLs but we have docs/code/tabular/etc, it's raw-documents. v2.1
# recognizes ~30 formats — full list must match what prep_plugins support.
DOC_EXTENSIONS="pdf|docx|pptx|txt|md|markdown|mdx|rtf|html|htm|xml|tex|rst|org|log|epub|odt|odp|ipynb|csv|tsv|xlsx|ods|parquet|pq|py|pyw|js|mjs|cjs|ts|tsx|jsx|java|kt|kts|scala|cpp|cc|cxx|hpp|hh|hxx|c|h|go|rs|rb|rake|php|cs|swift|sh|bash|zsh|sql|yaml|yml|toml|ini|cfg|r|jl|lua|pl|pm|ex|exs|erl|hrl|hs|clj|cljs|dart|groovy|m|zip|tar|gz|tgz|bz2|tbz2|7z|rar|eml|mbox|mbx|dcm|dicom|geojson|shp|h5|hdf5|nc"
OCR_EXTENSIONS="png|jpg|jpeg|tif|tiff|bmp|gif|webp|heic|heif"
AV_EXTENSIONS="mp3|wav|m4a|flac|ogg|opus|aac|mp4|mkv|mov|avi|webm|wmv|flv"
MESH_EXTENSIONS="stl|vtp|obj|ply"
BINARY_EXTENSIONS="bin|dat|so|dylib|dll|exe|o|a|lib|class|jar|myi|myd|frm|ibd|ibdata|db"

DOC_FILES=$(find -L "$TARGET" -maxdepth 8 -type f -regextype posix-extended \
  -iregex ".*\\.(${DOC_EXTENSIONS})$" 2>/dev/null | head -5)
if [[ -z "$JSONL_FILES" && -n "$DOC_FILES" ]]; then
  DETECTED_FORMAT="raw-documents"
fi

# Also count image/av/mesh/binary to populate extraction_profile
N_IMG=$(find -L "$TARGET" -maxdepth 8 -type f -regextype posix-extended \
  -iregex ".*\\.(${OCR_EXTENSIONS})$" 2>/dev/null | wc -l)
N_AV=$(find -L "$TARGET" -maxdepth 8 -type f -regextype posix-extended \
  -iregex ".*\\.(${AV_EXTENSIONS})$" 2>/dev/null | wc -l)
N_MESH=$(find -L "$TARGET" -maxdepth 8 -type f -regextype posix-extended \
  -iregex ".*\\.(${MESH_EXTENSIONS})$" 2>/dev/null | wc -l)
N_BIN=$(find -L "$TARGET" -maxdepth 8 -type f -regextype posix-extended \
  -iregex ".*\\.(${BINARY_EXTENSIONS})$" 2>/dev/null | wc -l)

# If we have images/av/mesh/binary but zero docs, still treat as raw-documents
# so the pipeline fires prep (metadata-only extraction will still produce chunks)
if [[ -z "$JSONL_FILES" && -z "$DOC_FILES" ]] && (( N_IMG + N_AV + N_MESH + N_BIN > 0 )); then
  DETECTED_FORMAT="raw-documents"
fi

# --- Build extraction_profile — tells forge-prep which tiers to install
PLUGINS_NEEDED='[]'
DISABLED_BY_ENV='[]'

if [[ -n "$DOC_FILES" ]]; then
  PLUGINS_NEEDED=$(echo "$PLUGINS_NEEDED" | jq '. + ["tier-lite"]')
fi
if (( N_IMG > 0 )); then
  if [[ "${FORGE_DISABLE_OCR:-}" == "1" ]]; then
    DISABLED_BY_ENV=$(echo "$DISABLED_BY_ENV" | jq '. + ["ocr"]')
  else
    PLUGINS_NEEDED=$(echo "$PLUGINS_NEEDED" | jq '. + ["tier-ocr"]')
  fi
fi
if (( N_AV > 0 )); then
  if [[ "${FORGE_DISABLE_TRANSCRIBE:-}" == "1" ]]; then
    DISABLED_BY_ENV=$(echo "$DISABLED_BY_ENV" | jq '. + ["transcribe"]')
  else
    PLUGINS_NEEDED=$(echo "$PLUGINS_NEEDED" | jq '. + ["tier-av"]')
  fi
fi

# Extraction time estimate:
#   OCR      ~2 sec per image (CPU, tesseract is fast)
#   Audio    ~0.3x realtime on CPU whisper-base (10min audio → 3min xcribe);
#            for an average dental audio file we assume 5min → 1.5min
#   Mesh     ~0.5 sec (metadata parsing only)
EST_EXT_SEC=$((N_IMG * 2 + N_AV * 90 + N_MESH / 2))
EST_EXT_MIN=$((EST_EXT_SEC / 60))

EXTRACTION_PROFILE=$(jq -n \
  --argjson plugins "$PLUGINS_NEEDED" \
  --argjson disabled "$DISABLED_BY_ENV" \
  --argjson n_img "$N_IMG" --argjson n_av "$N_AV" \
  --argjson n_mesh "$N_MESH" --argjson n_bin "$N_BIN" \
  --argjson ext_min "$EST_EXT_MIN" \
  '{
    plugins_needed: $plugins,
    disabled_by_env: $disabled,
    counts: {images: $n_img, audio_video: $n_av, mesh: $n_mesh, binary: $n_bin},
    estimated_extraction_time_min: $ext_min
  }')

# --- 3. Domain signal (sample-then-classify) -------------------------------
echo "[analyze] detecting domain..." >&2
DOMAIN_LABEL="general"
DOMAIN_CONF=0.0
DOMAIN_VIA="default"

if [[ -n "$DOMAIN_OVERRIDE" ]]; then
  DOMAIN_LABEL="$DOMAIN_OVERRIDE"
  DOMAIN_CONF=1.0
  DOMAIN_VIA="user-override"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  # Pick 3 short text samples
  SAMPLES_FILE=$(mktemp)

  if [[ -n "$JSONL_FILES" ]]; then
    # Sample from JSONL
    head -1 "$FIRST_JSONL" 2>/dev/null | jq -r '.text // (.messages[0].content // "") // ""' 2>/dev/null | head -c 600 > "$SAMPLES_FILE" || true
    echo "" >> "$SAMPLES_FILE"
    sed -n '50p' "$FIRST_JSONL" 2>/dev/null | jq -r '.text // (.messages[0].content // "") // ""' 2>/dev/null | head -c 600 >> "$SAMPLES_FILE" || true
    echo "" >> "$SAMPLES_FILE"
    sed -n '200p' "$FIRST_JSONL" 2>/dev/null | jq -r '.text // (.messages[0].content // "") // ""' 2>/dev/null | head -c 600 >> "$SAMPLES_FILE" || true
  else
    # Sample from txt/md if available, else just use file names as a hint
    TXT_F=$(find -L "$TARGET" -maxdepth 8 -type f \( -iname "*.txt" -o -iname "*.md" \) 2>/dev/null | head -3)
    if [[ -n "$TXT_F" ]]; then
      while IFS= read -r f; do
        head -c 600 "$f" 2>/dev/null >> "$SAMPLES_FILE" || true
        echo "" >> "$SAMPLES_FILE"
      done <<< "$TXT_F"
    else
      # Use document filenames as the domain hint
      find -L "$TARGET" -maxdepth 4 -type f -printf '%f\n' 2>/dev/null | head -30 > "$SAMPLES_FILE"
    fi
  fi

  if [[ -s "$SAMPLES_FILE" ]]; then
    SAMPLE_TEXT=$(cat "$SAMPLES_FILE")
    REQ_BODY=$(jq -n --arg sample "$SAMPLE_TEXT" '{
      model: "claude-haiku-4-5",
      max_tokens: 60,
      system: "You classify training corpora by domain. Output ONE compact dotted label (e.g. dental.ai.research, medical.cardiology, legal.contracts, finance.equities, code.python, general). No commentary, just the label.",
      messages: [{role:"user", content: ("Classify this corpus by domain. Sample text or filenames:\n\n" + $sample + "\n\nDomain label:")}]
    }')
    DOMAIN_RESP=$(curl -sS --max-time 20 https://api.anthropic.com/v1/messages \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "$REQ_BODY" 2>/dev/null || echo "{}")
    DOMAIN_LABEL=$(echo "$DOMAIN_RESP" | jq -r '.content[0].text // "general"' | tr -d ' \n\r' | sed 's/[^a-zA-Z0-9._-]//g')
    [[ -z "$DOMAIN_LABEL" ]] && DOMAIN_LABEL="general"
    DOMAIN_CONF=0.85
    DOMAIN_VIA="claude-haiku-classifier"
  fi
  rm -f "$SAMPLES_FILE"
fi

# --- 4. Derive needs from format ------------------------------------------
case "$DETECTED_FORMAT" in
  raw-documents)
    NEEDS='["prep","audit","synth","shape","plan_fit","provision","bootstrap","train","monitor","eval","quantize","register","card_validator","smoketest","publish","teardown","report"]'
    SKIP='[]'
    ;;
  pretrain-jsonl)
    NEEDS='["audit","synth","shape","plan_fit","provision","bootstrap","train","monitor","eval","quantize","register","card_validator","smoketest","publish","teardown","report"]'
    SKIP='["prep"]'
    ;;
  chat-jsonl)
    # Skip audit too — the audit was designed for raw passages, not pre-formed
    # Q/A pairs. Q/A quality is validated by plan_fit (Claude grader) instead.
    NEEDS='["shape","plan_fit","provision","bootstrap","train","monitor","eval","quantize","register","card_validator","smoketest","publish","teardown","report"]'
    SKIP='["prep","audit","synth"]'
    # For chat-jsonl, replace estimated_raw_tokens (which was byte/16 estimate)
    # with actual line count × ~250 tokens per Q/A pair
    if [[ -n "$JSONL_FILES" ]]; then
      ACT_LINES=$(wc -l < "$FIRST_JSONL")
      EST_TOKENS=$((ACT_LINES * 250))
    fi
    ;;
  mixed)
    NEEDS='["prep","audit","synth","shape","plan_fit","provision","bootstrap","train","monitor","eval","quantize","register","card_validator","smoketest","publish","teardown","report"]'
    SKIP='[]'
    ;;
esac

# --- 5. Emit analysis.json -------------------------------------------------
ANALYSIS=$(jq -n \
  --arg run_id "$RUN_ID" \
  --arg target "$TARGET" \
  --argjson inv "$INV" \
  --argjson tot_files "$TOTAL_FILES" \
  --argjson tot_mb "$TOTAL_MB" \
  --argjson est_tokens "$EST_TOKENS" \
  --arg fmt "$DETECTED_FORMAT" \
  --argjson fmt_ev "$FMT_EVIDENCE" \
  --arg dom_label "$DOMAIN_LABEL" \
  --argjson dom_conf "$DOMAIN_CONF" \
  --arg dom_via "$DOMAIN_VIA" \
  --argjson needs "$NEEDS" \
  --argjson skip "$SKIP" \
  --argjson ext_profile "$EXTRACTION_PROFILE" \
  '{
    run_id: $run_id,
    target_dir: $target,
    input_inventory: {
      by_ext: $inv,
      total_files: $tot_files,
      total_size_mb: $tot_mb,
      estimated_raw_tokens: $est_tokens
    },
    detected_format: $fmt,
    format_evidence: $fmt_ev,
    domain_signal: {
      label: $dom_label,
      confidence: $dom_conf,
      via: $dom_via
    },
    needs: $needs,
    skip_phases: $skip,
    extraction_profile: $ext_profile
  }')

echo "$ANALYSIS" > "$RUN_DIR/analysis.json"
echo "$ANALYSIS"
