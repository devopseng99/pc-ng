#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# webhook-handler.sh — Manual webhook trigger (same logic as webhook-server.py)
#
# Resets PaperclipBuild CRDs to trigger rebuilds, matching by repo name,
# app name, or pipeline. Useful for manual triggers without GitHub webhooks.
#
# Usage:
#   bash webhook-handler.sh --repo devopseng99/my-app    # Trigger rebuild for repo
#   bash webhook-handler.sh --app-name my-app             # Trigger by app name
#   bash webhook-handler.sh --crd pb-50301-gfh            # Trigger by CRD name
#   bash webhook-handler.sh --pipeline tech --all         # Rebuild all Failed in pipeline
#   bash webhook-handler.sh --status                      # Show recent triggers
#   bash webhook-handler.sh --dry-run --repo my-app       # Preview without acting
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pipeline-registry.sh"

NAMESPACE="paperclip-v3"
WORKSPACE="/tmp/pc-autopilot"
TRIGGER_LOG="$WORKSPACE/.webhook-triggers.log"

# Args
REPO=""
APP_NAME=""
CRD_NAME=""
PIPELINE_FILTER=""
ALL_IN_PIPELINE=false
SHOW_STATUS=false
DRY_RUN=false

# Colors
BOLD="\033[1m" GREEN="\033[32m" RED="\033[31m" YELLOW="\033[33m"
CYAN="\033[36m" DIM="\033[2m" RESET="\033[0m"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       REPO="$2"; shift 2 ;;
    --app-name)   APP_NAME="$2"; shift 2 ;;
    --crd)        CRD_NAME="$2"; shift 2 ;;
    --pipeline)   PIPELINE_FILTER="$2"; shift 2 ;;
    --all)        ALL_IN_PIPELINE=true; shift ;;
    --status)     SHOW_STATUS=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$WORKSPACE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [TRIGGER] $*" | tee -a "$TRIGGER_LOG"; }

# --- Redis (optional — best-effort) ---
REDIS_PASS_FILE="$WORKSPACE/.redis-pass"
_redis_pass() {
  if [[ -f "$REDIS_PASS_FILE" ]]; then cat "$REDIS_PASS_FILE"
  else
    local pass
    pass=$(kubectl get secret redis-credentials -n paperclip-v3 \
      -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo '')
    [[ -n "$pass" ]] && { echo "$pass" > "$REDIS_PASS_FILE"; chmod 600 "$REDIS_PASS_FILE"; }
    echo "$pass"
  fi
}
rcli() {
  kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- \
    redis-cli -a "$(_redis_pass)" --no-auth-warning "$@" 2>/dev/null
}
redis_publish() {
  local type="$1" payload="$2"
  rcli PUBLISH "pipeline:events" \
    "{\"type\":\"${type}\",\"ts\":\"$(date -Iseconds)\",${payload}}" \
    >/dev/null 2>&1 || true
}

# ============================================================================
# STATUS
# ============================================================================
if [[ "$SHOW_STATUS" == "true" ]]; then
  echo -e "${BOLD}${CYAN}=== Webhook Trigger History ===${RESET}"
  echo ""
  if [[ -f "$TRIGGER_LOG" ]]; then
    tail -20 "$TRIGGER_LOG" | sed 's/^/  /'
  else
    echo "  No triggers recorded yet."
  fi
  echo ""

  # Check webhook server
  echo -e "${BOLD}Webhook server:${RESET}"
  if pgrep -f "webhook-server.py" >/dev/null 2>&1; then
    local_pid=$(pgrep -f "webhook-server.py" | head -1)
    echo -e "  ${GREEN}RUNNING${RESET} (PID $local_pid)"
    # Try health endpoint
    health=$(curl -s --max-time 3 http://localhost:9090/health 2>/dev/null)
    if [[ -n "$health" ]]; then
      echo "  Health: $health"
    fi
  else
    echo -e "  ${DIM}not running locally${RESET}"
  fi

  # Check K8s deployment
  echo ""
  echo -e "${BOLD}K8s deployment:${RESET}"
  kubectl get deploy webhook-server -n paperclip-v3 --no-headers 2>/dev/null && true
  if [[ $? -ne 0 ]]; then
    echo -e "  ${DIM}not deployed to K8s${RESET}"
  fi

  exit 0
fi

# ============================================================================
# FIND MATCHING CRDs
# ============================================================================
find_crds() {
  local all_crds
  all_crds=$(kubectl get pb -n "$NAMESPACE" -o json 2>/dev/null)

  if [[ -n "$CRD_NAME" ]]; then
    # Direct CRD name match
    echo "$all_crds" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    if item['metadata']['name'] == '$CRD_NAME':
        spec = item['spec']
        status = item.get('status', {})
        print(f'{item[\"metadata\"][\"name\"]}|{spec.get(\"appId\",0)}|{spec.get(\"prefix\",\"\")}|{spec.get(\"repo\",\"\")}|{status.get(\"phase\",\"Unknown\")}|{spec.get(\"pipeline\",\"\")}')
" 2>/dev/null
    return
  fi

  echo "$all_crds" | python3 -c "
import json, sys

data = json.load(sys.stdin)
repo_filter = '${REPO}'
app_filter = '${APP_NAME}'
pipe_filter = '${PIPELINE_FILTER}'
all_in_pipe = '${ALL_IN_PIPELINE}' == 'true'

# Extract short repo name
repo_short = repo_filter.split('/')[-1] if '/' in repo_filter else repo_filter

for item in data.get('items', []):
    spec = item.get('spec', {})
    status = item.get('status', {})
    name = item['metadata']['name']
    phase = status.get('phase', 'Unknown')
    pipeline = spec.get('pipeline', '')
    crd_repo = spec.get('repo', '')
    app_name = spec.get('appName', '')

    # Pipeline filter (required if --all)
    if pipe_filter and pipeline != pipe_filter:
        continue

    # If --all in pipeline, only pick Failed CRDs
    if all_in_pipe:
        if phase != 'Failed':
            continue
    else:
        # Match by repo
        if repo_filter and not (
            crd_repo == repo_short or
            crd_repo == repo_filter or
            repo_short in crd_repo
        ):
            # Match by app name
            if app_filter and app_filter.lower() not in app_name.lower():
                continue
            elif not app_filter:
                continue

    print(f'{name}|{spec.get(\"appId\",0)}|{spec.get(\"prefix\",\"\")}|{crd_repo}|{phase}|{pipeline}')
" 2>/dev/null
}

# ============================================================================
# RESET CRD
# ============================================================================
reset_crd() {
  local crd_name="$1" current_phase="$2"

  local target_phase="Pending"
  local step="webhook-manual-reset"

  if [[ "$current_phase" == "Deployed" || "$current_phase" == "Ready" ]]; then
    target_phase="Building"
    step="webhook-rebuild"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "  ${YELLOW}[DRY RUN]${RESET} Would reset $crd_name: $current_phase -> $target_phase"
    return 0
  fi

  kubectl patch paperclipbuild "$crd_name" -n "$NAMESPACE" --type merge \
    -p "{\"status\":{\"phase\":\"$target_phase\",\"currentStep\":\"$step\",\"errorMessage\":\"\"}}" \
    --subresource=status 2>/dev/null

  if [[ $? -eq 0 ]]; then
    echo -e "  ${GREEN}OK${RESET} $crd_name: $current_phase -> $target_phase"
    log "Reset $crd_name: $current_phase -> $target_phase"
    redis_publish "webhook_trigger" \
      "\"crd\":\"$crd_name\",\"from\":\"$current_phase\",\"to\":\"$target_phase\",\"source\":\"manual\""
    return 0
  else
    echo -e "  ${RED}FAIL${RESET} $crd_name: patch failed"
    return 1
  fi
}

# ============================================================================
# MAIN
# ============================================================================
if [[ -z "$REPO" && -z "$APP_NAME" && -z "$CRD_NAME" && -z "$PIPELINE_FILTER" ]]; then
  echo "Usage: webhook-handler.sh --repo <repo> | --app-name <name> | --crd <name> | --pipeline <pipe> --all"
  echo "  --repo devopseng99/my-app    Trigger rebuild for repo"
  echo "  --app-name my-app            Trigger by app name"
  echo "  --crd pb-50301-gfh           Trigger by CRD name directly"
  echo "  --pipeline tech --all        Rebuild all Failed apps in pipeline"
  echo "  --status                     Show recent triggers"
  echo "  --dry-run                    Preview without acting"
  exit 1
fi

# Find matching CRDs
matches=$(find_crds)

if [[ -z "$matches" ]]; then
  echo "No matching CRDs found."
  if [[ -n "$REPO" ]]; then
    echo "  Searched for repo: $REPO"
  fi
  if [[ -n "$APP_NAME" ]]; then
    echo "  Searched for app name: $APP_NAME"
  fi
  if [[ -n "$PIPELINE_FILTER" ]]; then
    echo "  Searched in pipeline: $PIPELINE_FILTER"
  fi
  exit 1
fi

total=$(echo "$matches" | wc -l)
echo -e "${BOLD}Found $total matching CRD(s):${RESET}"
echo ""

triggered=0
while IFS='|' read -r crd_name app_id prefix repo phase pipeline; do
  [[ -z "$crd_name" ]] && continue
  echo -e "  ${CYAN}$crd_name${RESET}  [#$app_id $prefix]  repo=$repo  phase=$phase  pipeline=$pipeline"
  if reset_crd "$crd_name" "$phase"; then
    triggered=$((triggered + 1))
  fi
done <<< "$matches"

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "${YELLOW}Dry run complete — $total CRD(s) would be reset${RESET}"
else
  echo -e "${GREEN}Triggered $triggered/$total CRD(s)${RESET}"
fi
