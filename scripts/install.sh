#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PC-NG Install Script
# Applies all infrastructure: namespace, CRDs, RBAC, Redis, CLI symlink
#
# Usage:
#   ./install.sh              # Full install (interactive)
#   ./install.sh --skip-redis # Skip Redis deploy (CRDs + CLI only)
#   ./install.sh --dry-run    # Show what would be applied
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
SKIP_REDIS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-redis) SKIP_REDIS=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

log() { echo "[pc-ng] $*"; }

apply() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  DRY-RUN: kubectl apply -f $1"
  else
    kubectl apply -f "$1"
  fi
}

# --- Step 1: Namespace ---
log "Step 1: Creating paperclip-v3 namespace..."
apply "$BASE_DIR/manifests/namespace.yaml"

# --- Step 2: CRD ---
log "Step 2: Applying PaperclipBuild CRD..."
apply "$BASE_DIR/manifests/crd-paperclipbuild.yaml"

# --- Step 3: RBAC ---
log "Step 3: Applying RBAC (ServiceAccount + ClusterRole)..."
apply "$BASE_DIR/manifests/rbac-pipeline.yaml"

# --- Step 4: Redis ---
if [[ "$SKIP_REDIS" == "true" ]]; then
  log "Step 4: SKIPPED Redis deploy (--skip-redis)"
else
  log "Step 4: Deploying Redis..."

  # 4a: Provision node directory
  log "  4a: Provisioning node directory on mgplcb05..."
  if [[ "$DRY_RUN" != "true" ]]; then
    bash "$BASE_DIR/redis/scripts/provision-node-dirs.sh"
  else
    echo "  DRY-RUN: provision-node-dirs.sh"
  fi

  # 4b: Apply PV/PVC
  log "  4b: Applying Redis PV/PVC..."
  apply "$BASE_DIR/redis/pv.yaml"

  # 4c: Create secret
  log "  4c: Creating Redis secret..."
  if [[ "$DRY_RUN" != "true" ]]; then
    bash "$BASE_DIR/redis/scripts/setup-secrets.sh"
  else
    echo "  DRY-RUN: setup-secrets.sh"
  fi

  # 4d: Helm install
  log "  4d: Installing Redis via Helm..."
  if [[ "$DRY_RUN" != "true" ]]; then
    bash "$BASE_DIR/redis/.run0apply"
  else
    echo "  DRY-RUN: helm install redis"
  fi
fi

# --- Step 5: CLI ---
log "Step 5: Installing pc CLI..."
CLI_SRC="$BASE_DIR/cli/pc"
CLI_DST="/usr/local/bin/pc"

if [[ "$DRY_RUN" != "true" ]]; then
  if [[ -L "$CLI_DST" ]] || [[ -f "$CLI_DST" ]]; then
    log "  Removing existing $CLI_DST"
    rm -f "$CLI_DST"
  fi
  ln -s "$CLI_SRC" "$CLI_DST"
  chmod +x "$CLI_SRC"
  log "  Symlinked: $CLI_DST → $CLI_SRC"
else
  echo "  DRY-RUN: ln -s $CLI_SRC $CLI_DST"
fi

# --- Step 6: Context setup ---
log "Step 6: Setting up CLI contexts..."
CONTEXT_DIR="$HOME/.pc/contexts"
if [[ "$DRY_RUN" != "true" ]]; then
  mkdir -p "$CONTEXT_DIR"
  cp "$BASE_DIR/contexts/v1.env" "$CONTEXT_DIR/v1.env"
  cp "$BASE_DIR/contexts/tech.env" "$CONTEXT_DIR/tech.env"
  # Default to 'all' context
  echo "all" > "$HOME/.pc/context"
  log "  Contexts installed: v1, tech (default: all)"
else
  echo "  DRY-RUN: copy context configs to ~/.pc/"
fi

# --- Done ---
echo ""
log "============================================"
log "  PC-NG installed successfully!"
log "============================================"
log ""
log "  Verify:"
log "    pc doctor"
log "    pc context list"
log "    pc status"
log ""
log "  Backfill existing builds:"
log "    $BASE_DIR/scripts/backfill-crds.sh"
log ""
