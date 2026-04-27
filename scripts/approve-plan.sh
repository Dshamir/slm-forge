#!/bin/bash
# approve-plan: marks a run's plan as approved, kicks off dispatch-v2 in the
# background (setsid-detached so it survives the operator's shell). The
# single human gate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

RUN_ID="${1:-}"
[[ -z "$RUN_ID" ]] && { echo "usage: $0 <run-id>" >&2; exit 64; }

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
[[ -f "$RUN_DIR/plan.json" ]] || { echo "no plan.json at $RUN_DIR" >&2; exit 1; }

date -u +%FT%TZ > "$RUN_DIR/approved"
echo "✓ plan approved at $(cat $RUN_DIR/approved)"
echo "launching dispatch-v2 in background..."

setsid nohup bash "${SCRIPT_DIR}/dispatch-v2.sh" "$RUN_ID" \
  </dev/null >> "$RUN_DIR/dispatch.log" 2>&1 &
disown
sleep 1
echo "dispatch PID: $!"
echo
echo "Tail the log: tail -F $RUN_DIR/dispatch.log"
echo "Status:       cat $RUN_DIR/state.json"
echo "Cancel:       bash $SCRIPT_DIR/teardown-run.sh $RUN_ID"
