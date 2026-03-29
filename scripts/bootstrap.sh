#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PC-NG Bootstrap — Provisions /tmp/pc-autopilot workspace from the repo
#
# This script ensures the runtime workspace exists and is linked to the
# version-controlled scripts in the pc-ng repo. Run this after any reboot
# or /tmp wipe to restore the pipeline workspace.
#
# Usage: ./bootstrap.sh [--rebuild-registry]
# ============================================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="/tmp/pc-autopilot"
REBUILD_REGISTRY=false

for arg in "$@"; do
  [[ "$arg" == "--rebuild-registry" ]] && REBUILD_REGISTRY=true
done

log() { echo "[bootstrap] $*"; }

# --- 1. Create directory structure ---
log "Creating workspace at $WORKSPACE..."
mkdir -p "$WORKSPACE"/{scripts,registry,logs,manifests,.control}

# --- 2. Symlink version-controlled scripts into workspace ---
log "Linking pipeline scripts from repo..."
for script in "$REPO_DIR"/pipeline/scripts/*.sh; do
  local_name="$WORKSPACE/scripts/$(basename "$script")"
  if [[ -L "$local_name" ]]; then
    rm "$local_name"
  fi
  ln -sf "$script" "$local_name"
  log "  $(basename "$script") → repo"
done

# Symlink manifests
log "Linking manifests from repo..."
for manifest in "$REPO_DIR"/pipeline/manifests/*.json; do
  local_name="$WORKSPACE/manifests/$(basename "$manifest")"
  ln -sf "$manifest" "$local_name"
  log "  $(basename "$manifest") → repo"
done

# Also link the SSE bridge
if [[ -f "$REPO_DIR/scripts/sse-bridge.sh" ]]; then
  ln -sf "$REPO_DIR/scripts/sse-bridge.sh" "$WORKSPACE/scripts/sse-bridge.sh"
  log "  sse-bridge.sh → repo"
fi

# --- 3. Check for companion scripts (deploy-cf.sh, generate-prompt.sh, etc.) ---
COMPANION_SCRIPTS=("deploy-cf.sh" "generate-prompt.sh" "ingest-website.sh" "monitor.sh")
for cs in "${COMPANION_SCRIPTS[@]}"; do
  if [[ ! -f "$WORKSPACE/scripts/$cs" ]] && [[ ! -L "$WORKSPACE/scripts/$cs" ]]; then
    log "  WARNING: $cs not found — this script is needed by autopilot-build.sh"
    log "           Restore it from your backup or recreate it"
  fi
done

# --- 4. Cache Redis password ---
REDIS_PASS_FILE="$WORKSPACE/.redis-pass"
if [[ ! -f "$REDIS_PASS_FILE" ]]; then
  log "Caching Redis password..."
  if kubectl get secret redis-credentials -n paperclip-v3 &>/dev/null; then
    kubectl get secret redis-credentials -n paperclip-v3 -o jsonpath='{.data.password}' | base64 -d > "$REDIS_PASS_FILE"
    chmod 600 "$REDIS_PASS_FILE"
    log "  Cached at $REDIS_PASS_FILE"
  else
    log "  WARNING: redis-credentials secret not found in paperclip-v3"
  fi
else
  log "Redis password already cached"
fi

# --- 5. Initialize registry if missing ---
if [[ ! -f "$WORKSPACE/registry/deployed.json" ]]; then
  if [[ "$REBUILD_REGISTRY" == "true" ]]; then
    log "Rebuilding registry from CRDs..."
    "$REPO_DIR/scripts/rebuild-registry.sh"
  else
    log "Initializing empty registry..."
    echo '{"apps":[]}' > "$WORKSPACE/registry/deployed.json"
    log "  TIP: Run './scripts/bootstrap.sh --rebuild-registry' to populate from CRDs"
  fi
else
  log "Registry exists ($(python3 -c "import json; print(len(json.load(open('$WORKSPACE/registry/deployed.json')).get('apps',[])))" 2>/dev/null || echo '?') apps)"
fi

# --- 6. Initialize control files ---
for pipeline in v1 tech; do
  ctl_file="$WORKSPACE/.control/${pipeline}.concurrency"
  if [[ ! -f "$ctl_file" ]]; then
    echo "2" > "$ctl_file"
    log "  Initialized $pipeline concurrency = 2"
  fi
  streak_file="$WORKSPACE/.control/${pipeline}.fail_streak"
  if [[ ! -f "$streak_file" ]]; then
    echo "0" > "$streak_file"
  fi
done

# --- 7. Verify ---
log ""
log "=== Bootstrap Complete ==="
log "  Workspace:  $WORKSPACE"
log "  Scripts:    $WORKSPACE/scripts/"
log "  Registry:   $WORKSPACE/registry/deployed.json"
log "  Logs:       $WORKSPACE/logs/"
log "  Control:    $WORKSPACE/.control/"
log "  Redis pass: $REDIS_PASS_FILE"
log ""
log "To launch pipelines:"
log "  $WORKSPACE/scripts/launch-autopilot.sh       # v1 pipeline"
log "  $WORKSPACE/scripts/launch-tech-pipeline.sh    # tech pipeline"
log ""
log "To use queue mode:"
log "  $WORKSPACE/scripts/autopilot-build.sh --queue-mode --enqueue --manifest <file> --pipeline-id v1"
log "  $WORKSPACE/scripts/autopilot-build.sh --queue-mode --worker --concurrency 2 --pipeline-id v1"
