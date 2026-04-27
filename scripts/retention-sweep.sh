#!/usr/bin/env bash
# slm-forge/scripts/retention-sweep.sh
#
# Scans s3://<YOUR_S3_BUCKET>/forge/ for forges whose
#   phase != DONE  AND  updated_at > <RETENTION_DAYS ago>
# These are "abandoned" — either a failed forge that wasn't torn down,
# or a session the user forgot about. Dry-run by default; --apply to
# actually delete.
#
# Also flags any currently-running EC2 instances tagged with a
# forge-id whose manifest is in one of the abandoned states — these
# represent active spend that the user likely forgot about.
#
# Usage:
#   bash scripts/retention-sweep.sh [--days N] [--apply] [--include-done]
#
# Defaults:
#   --days 30       (per S3_LAYOUT.md "delete failed forges after 30 days")
#   (dry-run)
#   exclude DONE    (DONE forges are kept; their artifacts are the product)
#
# --include-done bumps an orthogonal retention for successful forges
# (default per S3_LAYOUT.md: transition to IA after 90 days). Not
# implemented yet; that's an S3 lifecycle policy concern, not this
# script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../lib"
REPO="${SCRIPT_DIR}/../../"

# shellcheck source=../lib/manifest.sh
source "${LIB}/manifest.sh"

DAYS=30
APPLY="no"
INCLUDE_DONE="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)          DAYS="$2"; shift 2 ;;
    --apply)         APPLY="yes"; shift ;;
    --include-done)  INCLUDE_DONE="yes"; shift ;;
    --help|-h)
      sed -n '3,22p' "$0"; exit 0 ;;
    *)
      echo "retention-sweep: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

# Resolve creds (same chain as smoke-test.sh)
if [[ -z "${FORGE_AWS_ACCESS_KEY_ID:-}" ]]; then
  ENV_FILE="${REPO}/.env"
  if [[ -f "$ENV_FILE" ]]; then
    FORGE_AWS_ACCESS_KEY_ID=$(grep '^FORGE_AWS_ACCESS_KEY_ID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    FORGE_AWS_SECRET_ACCESS_KEY=$(grep '^FORGE_AWS_SECRET_ACCESS_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    export FORGE_AWS_ACCESS_KEY_ID FORGE_AWS_SECRET_ACCESS_KEY
  fi
fi
if [[ -z "${FORGE_AWS_ACCESS_KEY_ID:-}" ]]; then
  MONGO_USER=$(grep '^MONGO_INITDB_ROOT_USERNAME=' "${REPO}/.env" 2>/dev/null | cut -d= -f2 || true)
  MONGO_PASS=$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "${REPO}/.env" 2>/dev/null | cut -d= -f2 || true)
  if [[ -n "$MONGO_USER" && -n "$MONGO_PASS" ]]; then
    FORGE_AWS_ACCESS_KEY_ID=$(cd "$REPO" && docker compose exec -T mongodb mongosh --quiet \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin mediastore \
      --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_ACCESS_KEY_ID"}); print(c?c.value:"")' \
      2>/dev/null | grep -v ^time | tail -1 || true)
    FORGE_AWS_SECRET_ACCESS_KEY=$(cd "$REPO" && docker compose exec -T mongodb mongosh --quiet \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin mediastore \
      --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_SECRET_ACCESS_KEY"}); print(c?c.value:"")' \
      2>/dev/null | grep -v ^time | tail -1 || true)
    export FORGE_AWS_ACCESS_KEY_ID FORGE_AWS_SECRET_ACCESS_KEY
  fi
fi

if [[ -z "${FORGE_AWS_ACCESS_KEY_ID:-}" ]]; then
  echo "retention-sweep: no AWS creds" >&2
  exit 1
fi

CUTOFF_EPOCH=$(date -u -d "${DAYS} days ago" +%s)
CUTOFF_ISO=$(date -u -d "@${CUTOFF_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)

echo "=== Retention sweep ==="
echo "  bucket:         s3://${FORGE_BUCKET}/${FORGE_PREFIX}/"
echo "  cutoff:         $CUTOFF_ISO  (${DAYS} days ago)"
echo "  mode:           $([ "$APPLY" == "yes" ] && echo 'APPLY (will delete)' || echo 'DRY-RUN (will only report)')"
echo "  include_done:   $INCLUDE_DONE"
echo ""

# ---- 1. List all forge IDs under the prefix ---------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[1] enumerating forges in s3://${FORGE_BUCKET}/${FORGE_PREFIX}/..."
# The `--output text` format tab-separates array results onto one line.
# Normalize to newlines, then filter to EXACT `forge/<id>/manifest.json`
# paths (so we don't misclassify nested files like `_raw-corpus-manifest.json`).
_forge_aws s3api list-objects-v2 \
  --bucket "$FORGE_BUCKET" \
  --prefix "${FORGE_PREFIX}/" \
  --query 'Contents[].Key' \
  --output text 2>/dev/null \
  | tr '\t' '\n' \
  | grep -E "^${FORGE_PREFIX}/[^/]+/manifest\.json$" \
  > "$TMP/manifests.txt" || true

# If forge user lacks full ListBucket (conditional policy), fall back to
# iterating the forge/ prefix's first-level directories.
if [[ ! -s "$TMP/manifests.txt" ]]; then
  _forge_aws s3api list-objects-v2 \
    --bucket "$FORGE_BUCKET" --prefix "${FORGE_PREFIX}/" --delimiter / \
    --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null | tr '\t' '\n' \
    | sed 's#/$#/manifest.json#' > "$TMP/manifests.txt"
fi

TOTAL=$(wc -l < "$TMP/manifests.txt" 2>/dev/null || echo 0)
echo "    found $TOTAL candidate manifest(s)"
echo ""

# ---- 2. Inspect each manifest, bucket into categories ----------------

: > "$TMP/abandoned.txt"
: > "$TMP/kept.txt"
: > "$TMP/active_spend.txt"

ABANDONED=0
KEPT=0

while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  forge_id=$(echo "$key" | sed -E 's#^forge/([^/]+)/manifest\.json$#\1#')
  [[ -z "$forge_id" || "$forge_id" == "$key" ]] && continue

  # Load the manifest via the mount path (reliable inside Docker CLI).
  get_tmp="$TMP/get-$forge_id.json"
  if ! _forge_aws_mount "$TMP" s3api get-object \
         --bucket "$FORGE_BUCKET" --key "$key" \
         "/work/get-$forge_id.json" >/dev/null 2>&1; then
    echo "    [skip] could not fetch $key" >&2
    continue
  fi
  manifest_json=$(cat "$get_tmp" 2>/dev/null || echo "")
  [[ -z "$manifest_json" ]] && continue

  phase=$(echo "$manifest_json" | jq -r '.phase // "?"')
  updated_at=$(echo "$manifest_json" | jq -r '.updated_at // ""')
  updated_epoch=$(date -u -d "$updated_at" +%s 2>/dev/null || echo 0)
  compute_iid=$(echo "$manifest_json" | jq -r '.compute_target.instance_id // ""')

  if [[ "$phase" == "DONE" ]] && [[ "$INCLUDE_DONE" != "yes" ]]; then
    echo "$forge_id  $phase  $updated_at" >> "$TMP/kept.txt"
    KEPT=$((KEPT + 1))
    continue
  fi

  if (( updated_epoch < CUTOFF_EPOCH )); then
    echo "$forge_id  phase=$phase  updated=$updated_at  inst=${compute_iid:-none}" >> "$TMP/abandoned.txt"
    ABANDONED=$((ABANDONED + 1))
    if [[ -n "$compute_iid" && "$compute_iid" != "null" ]]; then
      echo "$forge_id  $compute_iid" >> "$TMP/active_spend.txt"
    fi
  else
    echo "$forge_id  $phase  $updated_at (recent)" >> "$TMP/kept.txt"
    KEPT=$((KEPT + 1))
  fi
done < "$TMP/manifests.txt"

echo "[2] categorization:"
echo "    kept:       $KEPT"
echo "    abandoned:  $ABANDONED"
echo ""

# ---- 3. Report abandoned --------------------------------------------

if [[ -s "$TMP/abandoned.txt" ]]; then
  echo "[3] abandoned forges (phase != DONE AND updated > ${DAYS}d ago):"
  awk '{print "    " $0}' "$TMP/abandoned.txt"
  echo ""
else
  echo "[3] no abandoned forges — nothing to sweep"
  echo ""
fi

# ---- 4. Flag active compute spend on abandoned forges ---------------

if [[ -s "$TMP/active_spend.txt" ]]; then
  echo "⚠  [4] ABANDONED forges with possibly-still-running EC2 instances:"
  while IFS= read -r line; do
    fid=$(echo "$line" | awk '{print $1}')
    iid=$(echo "$line" | awk '{print $2}')
    state=$(_forge_aws ec2 describe-instances --instance-ids "$iid" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")
    echo "    $fid  instance=$iid  state=$state"
  done < "$TMP/active_spend.txt"
  echo ""
  echo "    Running instances = real \$ being spent. Terminate manually or"
  echo "    invoke forge-teardown on each."
  echo ""
fi

# ---- 5. Apply (delete) if --apply ------------------------------------

if [[ "$APPLY" == "yes" && -s "$TMP/abandoned.txt" ]]; then
  echo "[5] --apply: deleting abandoned forge prefixes from S3..."
  while IFS= read -r line; do
    fid=$(echo "$line" | awk '{print $1}')
    echo "    rm s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${fid}/"
    _forge_aws s3 rm "s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${fid}/" --recursive 2>&1 | \
      tail -3 | sed 's/^/      /' || true
  done < "$TMP/abandoned.txt"
  echo ""
  echo "    Swept $ABANDONED forge(s). EC2 instances NOT touched — terminate those"
  echo "    via forge-teardown or ec2 terminate-instances manually."
elif [[ -s "$TMP/abandoned.txt" ]]; then
  echo "[5] dry-run: pass --apply to actually delete the $ABANDONED forge prefix(es)."
fi

echo ""
echo "=== Retention sweep complete ==="
