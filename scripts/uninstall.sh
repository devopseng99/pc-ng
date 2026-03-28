#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PC-NG Uninstall Script
# Removes: CLI symlink, Redis, CRDs, RBAC, namespace
# Does NOT remove: deployed.json, control files, autopilot changes
# ============================================================================

log() { echo "[pc-ng] $*"; }

log "Uninstalling PC-NG..."
echo ""
echo "This will remove:"
echo "  - /usr/local/bin/pc symlink"
echo "  - Redis helm release in paperclip-v3"
echo "  - PaperclipBuild CRDs (all build records!)"
echo "  - RBAC resources"
echo "  - paperclip-v3 namespace"
echo ""
echo "This will NOT remove:"
echo "  - deployed.json registry"
echo "  - Autopilot control files"
echo "  - ~/.pc/ context configs"
echo ""
read -p "Continue? [y/N] " confirm
[[ ! "$confirm" =~ ^[Yy] ]] && { echo "Aborted."; exit 0; }

# CLI
log "Removing CLI symlink..."
rm -f /usr/local/bin/pc

# Redis
log "Uninstalling Redis..."
helm uninstall redis-pc-ng -n paperclip-v3 2>/dev/null || log "  (not installed)"

# CRDs (this deletes all PaperclipBuild resources!)
log "Removing PaperclipBuild CRD..."
kubectl delete crd paperclipbuilds.paperclip.istayintek.com 2>/dev/null || log "  (not found)"

# RBAC
log "Removing RBAC..."
kubectl delete clusterrolebinding pc-ng-pipeline-binding 2>/dev/null || true
kubectl delete clusterrole pc-ng-pipeline-role 2>/dev/null || true

# Namespace
log "Removing paperclip-v3 namespace..."
kubectl delete namespace paperclip-v3 2>/dev/null || log "  (not found)"

log ""
log "PC-NG uninstalled. Autopilot scripts and registry are unchanged."
