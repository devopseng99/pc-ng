#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# new-pipeline.sh — End-to-end pipeline creation with plan/auto-apply
#
# Takes a definition file (.def) or manifest JSON and runs the full pipeline
# creation flow: manifest → CRD enum → CRDs → worker registration → build.
#
# Modes:
#   --action plan        Show what would happen, don't execute anything
#   --action auto-apply  Execute everything including starting workers
#
# Usage:
#   # Plan from definition file (show what would happen)
#   ./new-pipeline.sh --from-def defs/fintech.def --pipeline fintech --action plan
#
#   # Auto-apply from definition file (create everything + start workers)
#   ./new-pipeline.sh --from-def defs/fintech.def --pipeline fintech --action auto-apply
#
#   # Plan from existing manifest JSON
#   ./new-pipeline.sh --manifest manifests/fintech.json --pipeline fintech --action plan
#
#   # Auto-apply with custom options
#   ./new-pipeline.sh --from-def defs/fintech.def --pipeline fintech \
#       --target-instance pc-v4 --concurrency 1 --action auto-apply
#
#   # Scaffold + plan (generates placeholder manifest, shows plan)
#   ./new-pipeline.sh --scaffold 20 --pipeline fintech --category "FinTech" --action plan
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pipeline-registry.sh"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST_DIR="$REPO_DIR/pipeline/manifests"
DEF_DIR="$REPO_DIR/pipeline/defs"
WORKSPACE="/tmp/pc-autopilot"
CRD_YAML="$REPO_DIR/manifests/crd-paperclipbuild.yaml"
WORKERS_SCRIPT="$SCRIPT_DIR/workers-start.sh"

# --- Params ---
ACTION=""
FROM_DEF=""
MANIFEST=""
SCAFFOLD=0
PIPELINE=""
CATEGORY="Misc"
START_ID=0
TARGET_INSTANCE=""
TARGET_NAMESPACE=""
CONCURRENCY=1
SKIP_DEPLOY=true

# --- Colors ---
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m'
BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'

log()     { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }
ok()      { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()     { echo -e "${RED}  ✗${NC} $*"; }
plan()    { echo -e "${DIM}  [plan]${NC} $*"; }
action()  { echo -e "${GREEN}  [exec]${NC} $*"; }
skip()    { echo -e "${YELLOW}  [skip]${NC} $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)           ACTION="$2"; shift 2 ;;
    --from-def)         FROM_DEF="$2"; shift 2 ;;
    --manifest)         MANIFEST="$2"; shift 2 ;;
    --scaffold)         SCAFFOLD="$2"; shift 2 ;;
    --pipeline)         PIPELINE="$2"; shift 2 ;;
    --category)         CATEGORY="$2"; shift 2 ;;
    --start-id)         START_ID="$2"; shift 2 ;;
    --target-instance)  TARGET_INSTANCE="$2"; shift 2 ;;
    --target-namespace) TARGET_NAMESPACE="$2"; shift 2 ;;
    --concurrency)      CONCURRENCY="$2"; shift 2 ;;
    --no-skip-deploy)   SKIP_DEPLOY=false; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# --- Validate ---
[[ -z "$ACTION" ]] && { err "--action required (plan or auto-apply)"; exit 1; }
[[ "$ACTION" != "plan" && "$ACTION" != "auto-apply" ]] && { err "--action must be 'plan' or 'auto-apply'"; exit 1; }
[[ -z "$PIPELINE" ]] && { err "--pipeline required"; exit 1; }

# Need at least one source
if [[ -z "$FROM_DEF" ]] && [[ -z "$MANIFEST" ]] && [[ "$SCAFFOLD" -eq 0 ]]; then
  err "Provide --from-def <file>, --manifest <file>, or --scaffold <N>"
  exit 1
fi

IS_PLAN=$([[ "$ACTION" == "plan" ]] && echo true || echo false)

# --- Auto-resolve target instance from registry ---
if [[ -z "$TARGET_INSTANCE" ]] || [[ -z "$TARGET_NAMESPACE" ]]; then
  if resolve_pipeline "$PIPELINE"; then
    TARGET_INSTANCE="$PC_INSTANCE"
    TARGET_NAMESPACE="$PC_NAMESPACE"
  else
    # New pipeline — default to pc-v4
    TARGET_INSTANCE="pc-v4"
    TARGET_NAMESPACE="paperclip-v4"
  fi
fi

# =====================================================================
header "Pipeline Creation — ${ACTION^^}"
echo -e "  Pipeline:  ${BOLD}$PIPELINE${NC}"
echo -e "  Target:    $TARGET_INSTANCE ($TARGET_NAMESPACE)"
echo -e "  Action:    $ACTION"
echo ""

# =====================================================================
# STEP 1: Determine next available ID range
# =====================================================================
header "Step 1: ID Range"

if [[ "$START_ID" -eq 0 ]]; then
  START_ID=$(kubectl get pb -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json,sys
items = json.load(sys.stdin)['items']
if not items:
    print(10001)
else:
    max_id = max(i['spec']['appId'] for i in items)
    print(((max_id // 100) + 1) * 100 + 1)
" 2>/dev/null)
fi
ok "Start ID: $START_ID (auto-calculated from existing CRDs)"

# =====================================================================
# STEP 2: Generate or locate manifest
# =====================================================================
header "Step 2: Manifest"

MANIFEST_PATH=""

if [[ -n "$MANIFEST" ]]; then
  # User provided existing manifest
  MANIFEST_PATH="$MANIFEST"
  if [[ ! -f "$MANIFEST_PATH" ]]; then
    err "Manifest not found: $MANIFEST_PATH"
    exit 1
  fi
  APP_COUNT=$(python3 -c "
import json
with open('$MANIFEST_PATH') as f: data = json.load(f)
apps = data.get('apps', data.get('use_cases', []))
print(len(apps))
")
  ok "Using existing manifest: $MANIFEST_PATH ($APP_COUNT apps)"

elif [[ -n "$FROM_DEF" ]]; then
  # Generate from definition file
  if [[ ! -f "$FROM_DEF" ]]; then
    err "Definition file not found: $FROM_DEF"
    exit 1
  fi
  MANIFEST_PATH="$MANIFEST_DIR/${PIPELINE}.json"

  APP_COUNT=$(grep -c "^name:" "$FROM_DEF" 2>/dev/null || echo 0)
  ok "Definition file: $FROM_DEF ($APP_COUNT apps)"
  ok "Will generate manifest: $MANIFEST_PATH"
  ok "ID range: $START_ID — $((START_ID + APP_COUNT - 1))"

  if [[ "$IS_PLAN" == "false" ]]; then
    action "Generating manifest..."
    bash "$SCRIPT_DIR/generate-manifest.sh" \
      --from-def "$FROM_DEF" \
      --pipeline "$PIPELINE" \
      --start-id "$START_ID" \
      --category "$CATEGORY" \
      --output "$MANIFEST_PATH" 2>&1 | sed 's/^/    /'
  else
    plan "Would generate manifest from $FROM_DEF → $MANIFEST_PATH"
  fi

elif [[ "$SCAFFOLD" -gt 0 ]]; then
  # Scaffold mode
  MANIFEST_PATH="$MANIFEST_DIR/${PIPELINE}.json"
  APP_COUNT="$SCAFFOLD"
  ok "Scaffold: $SCAFFOLD apps for pipeline '$PIPELINE'"
  ok "ID range: $START_ID — $((START_ID + SCAFFOLD - 1))"

  if [[ "$IS_PLAN" == "false" ]]; then
    action "Generating scaffold manifest..."
    bash "$SCRIPT_DIR/generate-manifest.sh" \
      --scaffold "$SCAFFOLD" \
      --pipeline "$PIPELINE" \
      --start-id "$START_ID" \
      --category "$CATEGORY" \
      --output "$MANIFEST_PATH" 2>&1 | sed 's/^/    /'
    warn "Scaffold has placeholder names — edit $MANIFEST_PATH before starting workers"
  else
    plan "Would scaffold $SCAFFOLD entries → $MANIFEST_PATH"
  fi
fi

# =====================================================================
# STEP 3: Register pipeline in ConfigMap registry
# =====================================================================
header "Step 3: Pipeline Registry"

if pipeline_exists "$PIPELINE"; then
  ok "Pipeline '$PIPELINE' already registered in ConfigMap"
else
  MANIFEST_BASENAME=$(basename "${MANIFEST_PATH:-${PIPELINE}.json}")
  if [[ "$IS_PLAN" == "false" ]]; then
    action "Registering '$PIPELINE' in pipeline-registry ConfigMap..."
    register_pipeline "$PIPELINE" "$TARGET_INSTANCE" "$TARGET_NAMESPACE" "$MANIFEST_BASENAME"
    ok "Registered: $PIPELINE → $TARGET_INSTANCE ($TARGET_NAMESPACE)"

    # Also update the YAML manifest for version control
    REGISTRY_YAML="$REPO_DIR/manifests/pipeline-registry.yaml"
    if [[ -f "$REGISTRY_YAML" ]]; then
      action "Updating pipeline-registry.yaml..."
      # Export current ConfigMap state to keep YAML in sync
      kubectl get configmap pipeline-registry -n paperclip-v3 \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null > /tmp/_reg_export.json
      python3 -c "
import json, yaml
with open('/tmp/_reg_export.json') as f: reg = json.load(f)
with open('$REGISTRY_YAML') as f: doc = yaml.safe_load(f)
doc['data']['registry.json'] = json.dumps(reg, indent=2)
with open('$REGISTRY_YAML', 'w') as f: yaml.dump(doc, f, default_flow_style=False, sort_keys=False)
" 2>/dev/null && ok "Updated $REGISTRY_YAML" || warn "Could not update YAML (update manually)"
      rm -f /tmp/_reg_export.json
    fi
  else
    plan "Would register '$PIPELINE' → $TARGET_INSTANCE ($TARGET_NAMESPACE) in pipeline-registry ConfigMap"
    plan "All scripts auto-resolve from registry — no case statements to update"
  fi
fi

# Verify CRD schema accepts the pipeline name (pattern-based, not enum)
if echo "$PIPELINE" | grep -qP '^[a-z][a-z0-9-]{0,29}$'; then
  ok "Pipeline name '$PIPELINE' matches CRD pattern ^[a-z][a-z0-9-]{0,29}$"
else
  err "Pipeline name '$PIPELINE' does NOT match CRD pattern — must be lowercase alphanumeric + hyphens, 1-30 chars"
  exit 1
fi

# =====================================================================
# STEP 4: Verify Registry Resolution
# =====================================================================
header "Step 4: Verify Registry"

# All scripts (workers-start.sh, generate-crds.sh, phase-a-codegen.sh, bulk-onboard.sh)
# auto-resolve from the pipeline-registry ConfigMap — no per-script registration needed.
if resolve_pipeline "$PIPELINE" 2>/dev/null; then
  ok "Registry resolves: $PIPELINE → $PC_INSTANCE ($PC_NAMESPACE)"
  ok "Secret: $PC_SECRET | Manifest: $PC_MANIFEST"
else
  if [[ "$IS_PLAN" == "false" ]]; then
    err "Pipeline '$PIPELINE' not resolvable after registration — check ConfigMap"
    exit 1
  else
    plan "After registration, all scripts will auto-resolve $PIPELINE from ConfigMap"
  fi
fi

# =====================================================================
# STEP 5: Create symlink in workspace
# =====================================================================
header "Step 5: Workspace Symlink"

WORKSPACE_MANIFEST="$WORKSPACE/manifests/$(basename "${MANIFEST_PATH:-${PIPELINE}.json}")"
if [[ -f "$WORKSPACE_MANIFEST" ]] || [[ -L "$WORKSPACE_MANIFEST" ]]; then
  ok "Symlink exists: $WORKSPACE_MANIFEST"
else
  if [[ "$IS_PLAN" == "false" ]] && [[ -n "$MANIFEST_PATH" ]]; then
    mkdir -p "$WORKSPACE/manifests"
    action "Creating symlink..."
    ln -sf "$MANIFEST_PATH" "$WORKSPACE_MANIFEST"
    ok "Linked: $MANIFEST_PATH → $WORKSPACE_MANIFEST"
  else
    plan "Would symlink $MANIFEST_PATH → $WORKSPACE_MANIFEST"
  fi
fi

# =====================================================================
# STEP 6: Generate CRDs
# =====================================================================
header "Step 6: CRDs"

if [[ "$IS_PLAN" == "false" ]] && [[ -f "${MANIFEST_PATH:-/nonexistent}" ]]; then
  action "Generating CRDs..."
  bash "$SCRIPT_DIR/generate-crds.sh" \
    --manifest "$MANIFEST_PATH" \
    --pipeline "$PIPELINE" \
    --target-instance "$TARGET_INSTANCE" \
    --target-namespace "$TARGET_NAMESPACE" 2>&1 | sed 's/^/    /'
else
  plan "Would create $APP_COUNT CRDs (pb-{id}-{prefix}) in paperclip-v3"
  plan "  targetInstance=$TARGET_INSTANCE, targetNamespace=$TARGET_NAMESPACE"
  plan "  Command: generate-crds.sh --manifest ... --pipeline $PIPELINE"
fi

# =====================================================================
# STEP 7: Start workers (auto-apply only)
# =====================================================================
header "Step 7: Workers"

if [[ "$IS_PLAN" == "false" ]]; then
  action "Starting $PIPELINE worker (concurrency=$CONCURRENCY)..."
  bash "$WORKERS_SCRIPT" --pipeline "$PIPELINE" --concurrency "$CONCURRENCY" 2>&1 | sed 's/^/    /'
else
  plan "Would start worker: ./workers-start.sh --pipeline $PIPELINE --concurrency $CONCURRENCY"
  plan "Worker auto-generates CRDs (idempotent), onboards companies (dedup by name), builds code"
fi

# =====================================================================
# STEP 8: Verify (auto-apply only)
# =====================================================================
if [[ "$IS_PLAN" == "false" ]]; then
  header "Step 8: Verification"
  # Count CRDs for this pipeline
  CRD_COUNT=$(kubectl get pb -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json,sys
items = json.load(sys.stdin)['items']
count = sum(1 for i in items if i['spec'].get('pipeline') == '$PIPELINE')
print(count)
" 2>/dev/null)
  ok "CRDs for $PIPELINE: $CRD_COUNT"

  # Check worker is running
  PID_FILE="$WORKSPACE/.workers/${PIPELINE}.pid"
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ok "Worker running: PID $(cat "$PID_FILE")"
  else
    warn "Worker not running (may have finished or not started)"
  fi
fi

# =====================================================================
header "Summary"
echo ""
echo -e "  Pipeline:      ${BOLD}$PIPELINE${NC}"
echo -e "  Target:        $TARGET_INSTANCE ($TARGET_NAMESPACE)"
echo -e "  Apps:          $APP_COUNT (IDs $START_ID — $((START_ID + APP_COUNT - 1)))"
echo -e "  Manifest:      ${MANIFEST_PATH:-not yet created}"
echo -e "  Concurrency:   $CONCURRENCY"
echo -e "  Phase B:       ${SKIP_DEPLOY:+SKIPPED (codegen only)}"
echo ""

if [[ "$IS_PLAN" == "true" ]]; then
  echo -e "  ${YELLOW}This was a dry run. To execute:${NC}"
  echo ""

  if [[ -n "$FROM_DEF" ]]; then
    echo -e "    ${BOLD}bash $SCRIPT_DIR/new-pipeline.sh \\"
    echo -e "      --from-def $FROM_DEF \\"
    echo -e "      --pipeline $PIPELINE \\"
    echo -e "      --start-id $START_ID \\"
    echo -e "      --category \"$CATEGORY\" \\"
    echo -e "      --concurrency $CONCURRENCY \\"
    echo -e "      --action auto-apply${NC}"
  elif [[ -n "$MANIFEST" ]]; then
    echo -e "    ${BOLD}bash $SCRIPT_DIR/new-pipeline.sh \\"
    echo -e "      --manifest $MANIFEST \\"
    echo -e "      --pipeline $PIPELINE \\"
    echo -e "      --concurrency $CONCURRENCY \\"
    echo -e "      --action auto-apply${NC}"
  fi
  echo ""
else
  echo -e "  ${GREEN}Pipeline created and workers started.${NC}"
  echo ""
  echo -e "  Monitor:  tail -f $WORKSPACE/.workers/${PIPELINE}.log"
  echo -e "  Status:   /pc-status"
  echo -e "  Stop:     ./workers-start.sh --stop"
  echo ""
fi
