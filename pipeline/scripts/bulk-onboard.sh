#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# bulk-onboard.sh — Bulk onboard CRD apps into their target PC instances
#
# Maps pipeline → PC instance, checks which apps already have companies,
# then runs onboard-full.sh for missing ones.
#
# Usage:
#   ./bulk-onboard.sh [--pipeline NAME] [--dry-run] [--concurrency N]
#
# Pipelines → PC instances:
#   v1        → paperclip    / pc      / pc-board-api-key
#   tech      → paperclip-v2 / pc-v2   / pc-v2-board-api-key
#   wasm/soa/ai/cf/mcp/ecom/crypto/invest → paperclip-v4 / pc-v4 / pc-v4-board-api-key
# ============================================================================

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pipeline-registry.sh"

PC_DIR="/var/lib/rancher/ansible/db/pc"
ONBOARD_SCRIPT="$PC_DIR/client-onboarding/scripts/onboard-full.sh"

# ---------- Parse args ----------
PIPELINE_FILTER=""
DRY_RUN=false
CONCURRENCY=1
SKIP_EXISTING=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline)     PIPELINE_FILTER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --concurrency)  CONCURRENCY="$2"; shift 2 ;;
    --force)        SKIP_EXISTING=false; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ---------- Pipeline → PC instance mapping (from registry) ----------
resolve_for_bulk() {
  local pipeline="$1"
  if resolve_pipeline "$pipeline"; then
    PC_NS="$PC_NAMESPACE"
    PC_DEPLOY="$PC_INSTANCE"
    return 0
  fi
  err "Pipeline '$pipeline' not in registry"
  return 1
}

# ---------- Get existing company names for a PC instance ----------
get_existing_companies() {
  local ns="$1" deploy="$2" key="$3"
  kubectl exec -n "$ns" "deploy/$deploy" -- curl -s \
    -H "Authorization: Bearer $key" \
    "http://localhost:3100/api/companies" 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    print(c.get('name','').strip())
" 2>/dev/null || true
}

# ---------- Get CRD apps for a pipeline ----------
get_crd_apps() {
  local pipeline="$1"
  kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
items = json.load(sys.stdin)['items']
for i in items:
    spec = i['spec']
    phase = i.get('status',{}).get('phase','Unknown')
    if spec.get('pipeline') == '$pipeline' and phase in ('Deployed','Deploying','Pending','Building'):
        repo = spec.get('repoName', spec.get('appName','').lower().replace(' ','-'))
        print(f'{spec[\"prefix\"]}|{spec[\"appName\"]}|{spec.get(\"appId\",\"?\")}|{spec.get(\"businessType\",\"\")}|{repo}|{spec.get(\"email\",\"admin@istayintek.com\")}|{spec.get(\"budget\",500)}')
" 2>/dev/null
}

# ---------- Main ----------
PIPELINES="${PIPELINE_FILTER:-$(list_pipelines)}"
TOTAL_ONBOARDED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

for pipeline in $PIPELINES; do
  # Resolve pipeline from registry
  resolve_for_bulk "$pipeline" || continue

  # Get API key
  API_KEY=$(kubectl get secret "$PC_SECRET" -n "$PC_NS" -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null)
  if [[ -z "$API_KEY" ]]; then
    API_KEY=$(kubectl get secret "$PC_SECRET" -n paperclip-v3 -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null)
  fi
  [[ -z "$API_KEY" ]] && { err "No API key for $pipeline ($PC_SECRET)"; continue; }

  log "Pipeline: $pipeline → $PC_NS/$PC_DEPLOY"

  # Get existing company names
  EXISTING=$(get_existing_companies "$PC_NS" "$PC_DEPLOY" "$API_KEY")
  EXISTING_COUNT=$(echo "$EXISTING" | grep -c . 2>/dev/null || echo 0)
  ok "Existing companies: $EXISTING_COUNT"

  # Get CRD apps
  APPS=$(get_crd_apps "$pipeline")
  APP_COUNT=$(echo "$APPS" | grep -c . 2>/dev/null || echo 0)
  ok "CRD apps (Deployed/Deploying): $APP_COUNT"

  # Filter to apps needing onboarding
  NEED_ONBOARD=0
  while IFS='|' read -r prefix name app_id biz_type repo email budget; do
    [[ -z "$prefix" ]] && continue

    if [[ "$SKIP_EXISTING" == "true" ]] && echo "$EXISTING" | grep -qxF "$name"; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
      continue
    fi

    NEED_ONBOARD=$((NEED_ONBOARD + 1))

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [DRY-RUN] Would onboard: $prefix ($name) → $PC_NS"
      continue
    fi

    log "Onboarding #$app_id $prefix ($name) → $PC_NS"

    # Run onboard-full.sh without --repo (repos may not exist yet; skip project repo step)
    NAMESPACE="$PC_NS" DEPLOY="$PC_DEPLOY" BOARD_API_KEY="$API_KEY" \
      "$ONBOARD_SCRIPT" \
        --name "$name" \
        --prefix "$prefix" \
        --email "${email:-admin@istayintek.com}" \
        --budget "${budget:-500}" \
        --business-type "${biz_type:-Web Application}" \
        > /tmp/pc-autopilot/onboard-${prefix}.log 2>&1 || true

    COMPANY_ID=$(grep "export COMPANY_ID=" /tmp/pc-autopilot/onboard-${prefix}.log | sed 's/.*export COMPANY_ID=//' | head -1)
    if [[ -n "$COMPANY_ID" ]]; then
      ok "#$app_id $prefix → company $COMPANY_ID"
      TOTAL_ONBOARDED=$((TOTAL_ONBOARDED + 1))
    else
      err "#$app_id $prefix — no company created (see /tmp/pc-autopilot/onboard-${prefix}.log)"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi

    # Rate limit: small delay between onboardings
    sleep 2

  done <<< "$APPS"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  $pipeline: $NEED_ONBOARD would be onboarded, $((APP_COUNT - NEED_ONBOARD)) already exist"
  fi
  echo ""
done

echo ""
log "=========================================="
log "  Bulk Onboarding Summary"
log "=========================================="
echo "  Onboarded: $TOTAL_ONBOARDED"
echo "  Skipped:   $TOTAL_SKIPPED (already have companies)"
echo "  Failed:    $TOTAL_FAILED"
echo ""
