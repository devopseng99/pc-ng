#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Batch deploy stuck apps to K8s
#
# Usage: ./batch-deploy-k8s.sh [--dry-run] [--app-id <id>]
#
# Reads stuck CRDs (non-Deployed) from paperclip-v3 and deploys each
# via deploy-k8s-static.sh. Updates CRD status on success.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-k8s-static.sh"
DRY_RUN=false
SINGLE_APP=""
LOG_DIR="/tmp/pc-autopilot/logs/batch-$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --app-id)   SINGLE_APP="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Fetch all non-deployed CRDs
APPS=$(kubectl get paperclipbuild -n paperclip-v3 -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
single = '${SINGLE_APP}'
for item in sorted(data['items'], key=lambda x: x['spec'].get('appId', 0)):
    phase = item.get('status', {}).get('phase', 'Unknown')
    if phase == 'Deployed':
        continue
    spec = item['spec']
    aid = spec.get('appId', 0)
    if single and str(aid) != single:
        continue
    repo = spec.get('repo', '')
    name = spec.get('appName', '')
    crd_name = item['metadata']['name']
    print(f'{aid}|{repo}|{name}|{crd_name}|{phase}')
")

if [[ -z "$APPS" ]]; then
  log "No stuck apps found"
  exit 0
fi

TOTAL=$(echo "$APPS" | wc -l)
log "Found $TOTAL apps to deploy"
log "Logs: $LOG_DIR"
echo ""

SUCCESS=0
FAILED=0
FAILED_LIST=""

while IFS='|' read -r APP_ID REPO APP_NAME CRD_NAME PHASE; do
  log "[$((SUCCESS + FAILED + 1))/$TOTAL] #${APP_ID} ${APP_NAME} (was: ${PHASE})"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  DRY RUN: would deploy repo=$REPO name=$APP_NAME"
    continue
  fi

  APP_LOG="$LOG_DIR/${APP_ID}-${REPO}.log"

  if bash "$DEPLOY_SCRIPT" --repo "$REPO" --name "$APP_NAME" --app-id "$APP_ID" > "$APP_LOG" 2>&1; then
    PUBLIC_URL=$(tail -1 "$APP_LOG")
    log "  Deployed -> $PUBLIC_URL"

    # Update CRD status
    kubectl patch paperclipbuild "$CRD_NAME" -n paperclip-v3 --type merge \
      -p "{\"status\":{\"deployUrl\":\"${PUBLIC_URL}\",\"phase\":\"Deployed\",\"errorMessage\":\"\",\"completedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" \
      --subresource=status 2>/dev/null || log "  WARNING: CRD patch failed"

    SUCCESS=$((SUCCESS + 1))
  else
    log "  FAILED — see $APP_LOG"
    tail -3 "$APP_LOG" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
    FAILED_LIST="${FAILED_LIST}  #${APP_ID} ${APP_NAME}\n"
  fi

  echo ""
done <<< "$APPS"

# Summary
log "=== Batch Deploy Complete ==="
log "  Success: $SUCCESS"
log "  Failed:  $FAILED"
log "  Logs:    $LOG_DIR"
if [[ -n "$FAILED_LIST" ]]; then
  log "  Failed apps:"
  echo -e "$FAILED_LIST"
fi
