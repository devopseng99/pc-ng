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
RESOURCE_THRESHOLD=70
NODE="mgplcb05"
LOG_DIR="/tmp/pc-autopilot/logs/batch-$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --app-id)     SINGLE_APP="$2"; shift 2 ;;
    --threshold)  RESOURCE_THRESHOLD="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

check_resources() {
  local result
  result=$(kubectl top node "$NODE" --no-headers 2>/dev/null) || return 0
  local cpu_pct mem_pct
  cpu_pct=$(echo "$result" | awk '{gsub(/%/,"",$3); print $3}')
  mem_pct=$(echo "$result" | awk '{gsub(/%/,"",$5); print $5}')
  if (( cpu_pct >= RESOURCE_THRESHOLD )) || (( mem_pct >= RESOURCE_THRESHOLD )); then
    log "RESOURCE GATE: ${NODE} at CPU=${cpu_pct}% MEM=${mem_pct}% — halting deploys"
    return 1
  fi
  return 0
}

# Check repo has code (skip empty repos)
repo_has_code() {
  local repo="$1"
  local size
  size=$(curl -sH "Authorization: token ${GH_TOKEN:-}" "https://api.github.com/repos/devopseng99/$repo" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('size',0))" 2>/dev/null || echo 0)
  [[ "$size" -gt 0 ]] 2>/dev/null
}

export GH_TOKEN="${GH_TOKEN:-$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d 2>/dev/null || echo '')}"

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

SKIPPED=0
while IFS='|' read -r APP_ID REPO APP_NAME CRD_NAME PHASE; do
  log "[$((SUCCESS + FAILED + SKIPPED + 1))/$TOTAL] #${APP_ID} ${APP_NAME} (was: ${PHASE})"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  DRY RUN: would deploy repo=$REPO name=$APP_NAME"
    continue
  fi

  # Resource gate — stop deploying if cluster is at capacity
  if ! check_resources; then
    log "  Halting: cluster at ${RESOURCE_THRESHOLD}% threshold. Deployed $SUCCESS so far."
    log "  Re-run this script later to continue."
    break
  fi

  # Skip empty repos
  if ! repo_has_code "$REPO"; then
    log "  SKIP: repo is empty (needs codegen first)"
    SKIPPED=$((SKIPPED + 1))
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
log "=== Phase B — Batch Deploy Complete ==="
log "  Success: $SUCCESS"
log "  Skipped: $SKIPPED (empty repos)"
log "  Failed:  $FAILED"
log "  Logs:    $LOG_DIR"
if [[ -n "$FAILED_LIST" ]]; then
  log "  Failed apps:"
  echo -e "$FAILED_LIST"
fi
