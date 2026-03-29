#!/usr/bin/env bash
set -euo pipefail

# Launch v1 pipeline in a tmux session
# Usage: ./launch-autopilot.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="autopilot"
MANIFEST="/tmp/pc-autopilot/manifests/use-cases-201-400.json"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists. Attach with: tmux attach -t $SESSION"
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: Manifest not found: $MANIFEST"
  echo "Run the bootstrap script first: /var/lib/rancher/ansible/db/pc-ng/scripts/bootstrap.sh"
  exit 1
fi

tmux new-session -d -s "$SESSION" \
  "$SCRIPT_DIR/autopilot-build.sh --manifest $MANIFEST --all --concurrency 2 --pipeline-id v1; echo 'Pipeline finished. Press Enter to close.'; read"

echo "v1 pipeline launched in tmux session: $SESSION"
echo "Attach: tmux attach -t $SESSION"
