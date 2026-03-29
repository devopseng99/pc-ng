#!/usr/bin/env bash
set -euo pipefail

# Launch Phase A (codegen only) for v1 pipeline in tmux
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="codegen-v1"
MANIFEST="/tmp/pc-autopilot/manifests/use-cases-201-400.json"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists. Attach with: tmux attach -t $SESSION"
  exit 1
fi

[[ ! -f "$MANIFEST" ]] && { echo "ERROR: Manifest not found: $MANIFEST — run bootstrap.sh first"; exit 1; }

tmux new-session -d -s "$SESSION" \
  "$SCRIPT_DIR/phase-a-codegen.sh --manifest $MANIFEST --pipeline-id v1 --concurrency 4 --timeout 300; echo 'Phase A complete. Run batch-deploy-k8s.sh for Phase B. Press Enter to close.'; read"

echo "Phase A (codegen) v1 launched in tmux: $SESSION"
echo "  Concurrency: 4  |  Timeout: 300s  |  Stall: 90s"
echo "  Attach: tmux attach -t $SESSION"
echo "  When done, deploy with: $SCRIPT_DIR/batch-deploy-k8s.sh"
