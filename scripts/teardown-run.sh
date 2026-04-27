#!/bin/bash
# teardown-run: aborts a forge run cleanly. Kills dispatch + poll loops,
# tears down any live EC2, marks state as cancelled.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

RUN_ID="${1:-}"
[[ -z "$RUN_ID" ]] && { echo "usage: $0 <run-id>" >&2; exit 64; }
RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
[[ -d "$RUN_DIR" ]] || { echo "no run dir at $RUN_DIR" >&2; exit 1; }

# Kill local dispatcher
pkill -f "dispatch-v2.sh ${RUN_ID}" 2>/dev/null && echo "killed local dispatch" || echo "no local dispatch"
pkill -f "forge-poll-loop.*${RUN_ID}" 2>/dev/null && echo "killed poll loop" || true

# Terminate EC2 if any
STATE="$RUN_DIR/state.json"
if [[ -f "$STATE" ]]; then
  IID=$(jq -r '.instance_id // ""' "$STATE")
  if [[ -n "$IID" && "$IID" != "null" && -x "${REPO_ROOT}/slm-forge/skills/forge-teardown/run.sh" ]]; then
    echo "terminating $IID..."
    bash "${REPO_ROOT}/slm-forge/skills/forge-teardown/run.sh" "$RUN_ID" --terminate 2>&1 | tail -5
  fi

  jq --arg st "$(date -u +%FT%TZ)" '.cancelled_at = $st | .current_phase = "CANCELLED"' "$STATE" > "$STATE.new"
  mv "$STATE.new" "$STATE"
fi

echo "✓ run ${RUN_ID} cancelled"
