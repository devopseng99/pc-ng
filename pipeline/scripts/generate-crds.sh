#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# generate-crds.sh — Single entry point for CRD creation
#
# Reads a manifest JSON and creates PaperclipBuild CRDs with deterministic
# naming (pb-{appId}-{prefix-lowercase}). Idempotent — skips existing CRDs.
#
# This is the ONLY way apps should enter the pipeline. Workers consume CRDs,
# they never create them.
#
# Usage:
#   ./generate-crds.sh --manifest <file.json> --pipeline <name> \
#       --target-instance <pc-v4> --target-namespace <paperclip-v4>
#   ./generate-crds.sh --manifest <file.json> --pipeline ecom  # auto-resolve instance
#   ./generate-crds.sh --manifest <file.json> --pipeline ecom --dry-run
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pipeline-registry.sh"

CRD_NAMESPACE="paperclip-v3"
PIPELINE=""
TARGET_INSTANCE=""
TARGET_NAMESPACE=""
MANIFEST=""
DRY_RUN=false
INITIAL_PHASE="Pending"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)           MANIFEST="$2"; shift 2 ;;
    --pipeline)           PIPELINE="$2"; shift 2 ;;
    --target-instance)    TARGET_INSTANCE="$2"; shift 2 ;;
    --target-namespace)   TARGET_NAMESPACE="$2"; shift 2 ;;
    --dry-run)            DRY_RUN=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$MANIFEST" ]] && { err "--manifest required"; exit 1; }
[[ -z "$PIPELINE" ]] && { err "--pipeline required"; exit 1; }
[[ ! -f "$MANIFEST" ]] && { err "Manifest not found: $MANIFEST"; exit 1; }

# --- Auto-resolve instance from pipeline registry if not explicitly provided ---
if [[ -z "$TARGET_INSTANCE" ]] || [[ -z "$TARGET_NAMESPACE" ]]; then
  if resolve_pipeline "$PIPELINE"; then
    TARGET_INSTANCE="$PC_INSTANCE"
    TARGET_NAMESPACE="$PC_NAMESPACE"
  else
    err "Pipeline '$PIPELINE' not in registry — provide --target-instance and --target-namespace, or register it: kubectl edit configmap pipeline-registry -n paperclip-v3"
    exit 1
  fi
  log "Auto-resolved: $PIPELINE → $TARGET_INSTANCE ($TARGET_NAMESPACE)"
fi

# --- Read manifest entries ---
get_entries() {
  python3 -c "
import json
with open('$1') as f: data = json.load(f)
apps = data.get('apps', data.get('use_cases', []))
for a in apps: print(json.dumps(a))
"
}

# --- Get existing CRD names for fast lookup ---
log "Loading existing CRDs from $CRD_NAMESPACE..."
EXISTING_CRDS=$(kubectl get pb -n "$CRD_NAMESPACE" -o custom-columns='NAME:.metadata.name' --no-headers 2>/dev/null || true)

created=0
skipped=0
total=0

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  total=$((total + 1))

  eval "$(echo "$entry" | python3 -c "
import json, sys, shlex
e = json.load(sys.stdin)
print(f'app_id={e[\"id\"]}')
print(f'app_name={shlex.quote(e[\"name\"])}')
print(f'prefix={shlex.quote(e[\"prefix\"])}')
print(f'repo={shlex.quote(e[\"repo\"])}')
print(f'category={shlex.quote(e.get(\"category\", \"Misc\"))}')
")"

  # Deterministic CRD name: pb-{appId}-{prefix-lowercase}
  crd_name="pb-${app_id}-$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"

  # Skip if already exists
  if echo "$EXISTING_CRDS" | grep -qxF "$crd_name"; then
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY-RUN] Would create: $crd_name  ($app_name)  → $TARGET_INSTANCE"
    created=$((created + 1))
    continue
  fi

  # Create CRD
  kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: paperclip.istayintek.com/v1alpha1
kind: PaperclipBuild
metadata:
  name: ${crd_name}
  namespace: ${CRD_NAMESPACE}
spec:
  appId: ${app_id}
  appName: "${app_name}"
  prefix: "${prefix}"
  repo: "${repo}"
  category: "${category}"
  pipeline: "${PIPELINE}"
  targetInstance: "${TARGET_INSTANCE}"
  targetNamespace: "${TARGET_NAMESPACE}"
EOF

  # Set initial phase via status subresource
  kubectl patch pb "$crd_name" -n "$CRD_NAMESPACE" --type merge \
    -p "{\"status\":{\"phase\":\"${INITIAL_PHASE}\"}}" --subresource=status >/dev/null 2>&1 || true

  ok "$crd_name ($app_name) → $TARGET_INSTANCE"
  created=$((created + 1))

done < <(get_entries "$MANIFEST")

echo ""
log "=== CRD Generation Summary ==="
echo "  Pipeline:  $PIPELINE → $TARGET_INSTANCE ($TARGET_NAMESPACE)"
echo "  Total:     $total"
echo "  Created:   $created"
echo "  Skipped:   $skipped (already exist)"
echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run — no CRDs were created"
else
  log "CRDs ready. Start worker with:"
  log "  ./workers-start.sh --pipeline $PIPELINE --concurrency 1"
fi
