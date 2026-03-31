#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# provision-pc.sh — Provision a new Paperclip instance end-to-end
#
# Usage:
#   ./provision-pc.sh --release pc-v5 --namespace paperclip-v5 \
#     --slug pc-v5 --context tenant-name [--node mgplcb05] [--port 3100]
#
#   ./provision-pc.sh --release pc-v5 --teardown   # remove everything
#
# Steps: namespace → dirs → secrets → helm → tunnel route → DNS → validate → context
# ============================================================================

# ---------- Constants ----------
CF_ACCOUNT_ID="9709bd1f498109e65ff5d1898fec15ee"
CF_TUNNEL_ID="b2c521bb-d042-4e59-89ce-f94cef67175b"
CF_ZONE_ID="0e34ae940d6ef78c3812c5d1244f63f2"
CF_TUNNEL_CNAME="${CF_TUNNEL_ID}.cfargotunnel.com"
DOMAIN="istayintek.com"
HELM_CHART="/var/lib/rancher/ansible/db/pc/pc-helm-charts/charts/pc/"
PC_REPO="/var/lib/rancher/ansible/db/pc"
PCNG_REPO="/var/lib/rancher/ansible/db/pc-ng"

# ---------- Defaults ----------
TARGET_NODE="mgplcb05"
SERVICE_PORT="3100"
TEARDOWN=false

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*" >&2; }
die()  { err "$@"; exit 1; }

# ---------- Parse Args ----------
RELEASE="" NAMESPACE="" SLUG="" CONTEXT_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)    RELEASE="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --slug)       SLUG="$2"; shift 2 ;;
    --context)    CONTEXT_NAME="$2"; shift 2 ;;
    --node)       TARGET_NODE="$2"; shift 2 ;;
    --port)       SERVICE_PORT="$2"; shift 2 ;;
    --teardown)   TEARDOWN=true; shift ;;
    -h|--help)
      echo "Usage: $0 --release NAME --namespace NS --slug SUBDOMAIN --context CTX_NAME [--node NODE] [--port PORT]"
      echo "       $0 --release NAME --namespace NS --teardown"
      exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -z "$RELEASE" ]] && die "--release is required"
[[ -z "$NAMESPACE" && "$TEARDOWN" == "false" ]] && die "--namespace is required"

# ---------- CF Token ----------
get_cf_token() {
  if [[ -f ~/cf-token--expires-apr-1 ]]; then
    cat ~/cf-token--expires-apr-1
  else
    kubectl get secret cloudflare-credentials -n paperclip -o jsonpath='{.data.CF_API_TOKEN}' | base64 -d
  fi
}

# ============================================================================
# TEARDOWN
# ============================================================================
if [[ "$TEARDOWN" == "true" ]]; then
  log "Tearing down $RELEASE..."

  # Remove tunnel route
  CF_TOKEN=$(get_cf_token)
  if [[ -n "$CF_TOKEN" ]]; then
    SLUG="${SLUG:-$RELEASE}"
    HOSTNAME="${SLUG}.${DOMAIN}"
    log "Removing tunnel route for $HOSTNAME..."

    CURRENT=$(curl -sf -H "Authorization: Bearer $CF_TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations")

    UPDATED=$(echo "$CURRENT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
config = d['result']['config']
config['ingress'] = [r for r in config['ingress'] if r.get('hostname') != '$HOSTNAME']
print(json.dumps({'config': config}))
" 2>/dev/null)

    if [[ -n "$UPDATED" ]]; then
      curl -sf -X PUT -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
        -d "$UPDATED" \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
        > /dev/null && ok "Tunnel route removed" || warn "Failed to remove tunnel route"
    fi

    # Remove DNS
    RECORD_ID=$(curl -sf -H "Authorization: Bearer $CF_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}" \
      | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2>/dev/null)

    if [[ -n "$RECORD_ID" ]]; then
      curl -sf -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${RECORD_ID}" \
        > /dev/null && ok "DNS record removed" || warn "Failed to remove DNS"
    fi
  fi

  # Helm uninstall
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null && ok "Helm release removed" || warn "Helm release not found"

  # Delete namespace
  kubectl delete ns "$NAMESPACE" 2>/dev/null && ok "Namespace deleted" || warn "Namespace not found"

  # Delete PVs
  kubectl delete pv "${RELEASE}-data-pv" "psql-${RELEASE}-pv" 2>/dev/null && ok "PVs deleted" || warn "PVs not found"

  # Remove context
  rm -f "${PCNG_REPO}/contexts/${CONTEXT_NAME:-$RELEASE}.env" ~/.pc/contexts/"${CONTEXT_NAME:-$RELEASE}.env"
  ok "Context removed"

  log "Teardown complete. Note: data dirs on $TARGET_NODE are preserved."
  exit 0
fi

# ============================================================================
# PROVISION
# ============================================================================
[[ -z "$SLUG" ]] && die "--slug is required"
[[ -z "$CONTEXT_NAME" ]] && die "--context is required"

HOSTNAME="${SLUG}.${DOMAIN}"
VALUES_FILE="${PC_REPO}/overrides-${RELEASE}.yaml"

log "Provisioning Paperclip instance: $RELEASE"
log "  Namespace:  $NAMESPACE"
log "  URL:        https://${HOSTNAME}"
log "  Context:    $CONTEXT_NAME"
log "  Node:       $TARGET_NODE"
echo ""

# ---------- Step 1: Namespace ----------
log "Step 1/12: Creating namespace..."
kubectl create ns "$NAMESPACE" 2>/dev/null && ok "Namespace created" || ok "Namespace already exists"

# ---------- Step 2: Persistent dirs ----------
log "Step 2/12: Creating persistent storage dirs on $TARGET_NODE..."
kubectl debug "node/${TARGET_NODE}" --image=busybox -- sh -c \
  "mkdir -p /host/opt/k8s-pers/vol1/${RELEASE}-data /host/opt/k8s-pers/vol1/psql-${RELEASE} && \
   chmod 777 /host/opt/k8s-pers/vol1/${RELEASE}-data /host/opt/k8s-pers/vol1/psql-${RELEASE}" 2>/dev/null
# Clean up debug pod
sleep 2
kubectl delete pod -l run=node-debugger --field-selector=status.phase=Succeeded 2>/dev/null
ok "Dirs created"

# ---------- Step 3: Secrets ----------
log "Step 3/12: Creating secrets..."
PG_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
AUTH_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

kubectl create secret generic "${RELEASE}-postgres-secret" \
  -n "$NAMESPACE" --from-literal=postgres-password="$PG_PASS" 2>/dev/null || true

kubectl create secret generic "${RELEASE}-auth-secret" \
  -n "$NAMESPACE" --from-literal=secret="$AUTH_SECRET" 2>/dev/null || true

kubectl create secret generic "${RELEASE}-database-url-secret" \
  -n "$NAMESPACE" --from-literal=url="postgresql://postgres:${PG_PASS}@${RELEASE}-postgresql:5432/paperclip" 2>/dev/null || true

for secret in pc-claude-auth cloudflare-api-keys github-credentials; do
  kubectl get secret "$secret" -n paperclip -o yaml 2>/dev/null | \
    sed "s/namespace: paperclip/namespace: $NAMESPACE/" | \
    kubectl apply -f - 2>/dev/null || warn "Could not copy $secret"
done
ok "Secrets created"

# ---------- Step 4: Helm values ----------
log "Step 4/12: Generating Helm values..."
cat > "$VALUES_FILE" << YAML
paperclip:
  image:
    repository: localhost/paperclip
    tag: latest
    pullPolicy: Never
  replicas: 1
  databaseUrlSecretName: ${RELEASE}-database-url-secret
  authSecretName: ${RELEASE}-auth-secret
  claudeAuthSecretName: pc-claude-auth
  cloudflareSecretName: cloudflare-api-keys
  githubSecretName: github-credentials
  env:
    PORT: "${SERVICE_PORT}"
    SERVE_UI: "true"
    PAPERCLIP_DEPLOYMENT_MODE: "authenticated"
    PAPERCLIP_DEPLOYMENT_EXPOSURE: "private"
    PAPERCLIP_PUBLIC_URL: "https://${HOSTNAME}"
    LOG_LEVEL: "warn"
    NODE_ENV: "production"
  resources:
    limits:
      memory: "1Gi"
      cpu: "500m"
    requests:
      memory: "512Mi"
      cpu: "100m"
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
  persistence:
    enabled: true
    storageClass: my-local-storage
    accessMode: ReadWriteOnce
    size: 10Gi
    existingClaim: ${RELEASE}-data-pvc
  localPV:
    enabled: true
    pvName: ${RELEASE}-data-pv
    claimName: ${RELEASE}-data-pvc
    size: 10Gi
    accessMode: ReadWriteOnce
    reclaimPolicy: Retain
    storageClass: my-local-storage
    localPath: /opt/k8s-pers/vol1/${RELEASE}-data
    nodeHostname: ${TARGET_NODE}

postgresql:
  enabled: true
  auth:
    postgresUser: postgres
    database: paperclip
    existingSecret: ${RELEASE}-postgres-secret
    secretKeys:
      adminPasswordKey: postgres-password
  persistence:
    enabled: true
    storageClass: my-local-storage
    accessMode: ReadWriteOnce
    size: 15Gi
    existingClaim: psql-${RELEASE}-claim0
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
  resources:
    limits:
      memory: "512Mi"
      cpu: "500m"
    requests:
      memory: "256Mi"
      cpu: "100m"
  localPV:
    enabled: true
    pvName: psql-${RELEASE}-pv
    claimName: psql-${RELEASE}-claim0
    size: 15Gi
    accessMode: ReadWriteOnce
    reclaimPolicy: Retain
    storageClass: my-local-storage
    localPath: /opt/k8s-pers/vol1/psql-${RELEASE}
    nodeHostname: ${TARGET_NODE}

ingress:
  enabled: false
YAML
ok "Values written to $VALUES_FILE"

# ---------- Step 5: Helm install ----------
log "Step 5/12: Installing Helm release..."
helm install "$RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f "$VALUES_FILE" 2>&1 | tail -3
ok "Helm release installed"

# ---------- Step 6: Wait for pods ----------
log "Step 6/12: Waiting for pods to be ready..."
for i in $(seq 1 30); do
  READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '$3=="Running" && $2~/^1\/1/' | wc -l)
  TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
  if [[ "$READY" -ge 2 && "$TOTAL" -ge 2 ]]; then
    ok "All pods ready ($READY/$TOTAL)"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    warn "Timeout waiting for pods. Current state:"
    kubectl get pods -n "$NAMESPACE"
  fi
  sleep 5
done

# ---------- Step 7: Onboard instance ----------
log "Step 7/12: Running Paperclip onboard..."
POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')

# Get DB password for onboard config
DB_PASS=$(kubectl get secret "${RELEASE}-postgres-secret" -n "$NAMESPACE" -o jsonpath='{.data.postgres-password}' | base64 -d)

# Create onboard config
cat > /tmp/${RELEASE}-onboard-config.json << CFGEOF
{
  "database": {
    "mode": "postgres",
    "connectionString": "postgres://postgres:${DB_PASS}@${RELEASE}-postgresql.${NAMESPACE}.svc.cluster.local:5432/paperclip?sslmode=disable",
    "backup": {
      "enabled": true,
      "intervalMinutes": 60,
      "retentionDays": 30,
      "dir": "/paperclip/instances/default/data/backups"
    }
  },
  "logging": {
    "mode": "file",
    "logDir": "/paperclip/instances/default/logs"
  },
  "server": {
    "deploymentMode": "authenticated",
    "exposure": "private",
    "host": "0.0.0.0",
    "port": ${SERVICE_PORT},
    "allowedHostnames": ["${HOSTNAME}"]
  }
}
CFGEOF

# Copy config to PERSISTENT path inside pod (survives restarts)
PERSISTENT_CONFIG="/paperclip/instances/default/config.json"
kubectl cp "/tmp/${RELEASE}-onboard-config.json" "${NAMESPACE}/${POD_NAME}:${PERSISTENT_CONFIG}"

# Verify config persisted
kubectl exec "$POD_NAME" -n "$NAMESPACE" -- test -f "$PERSISTENT_CONFIG" \
  && ok "Config written to ${PERSISTENT_CONFIG} (persistent volume)" \
  || die "Config NOT persisted — onboard will fail after restart"

# Run onboard pointing to the persistent path
ONBOARD_OUTPUT=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
  pnpm paperclipai onboard --config "$PERSISTENT_CONFIG" --yes 2>&1 || true)

# Extract invite URL
INVITE_URL=$(echo "$ONBOARD_OUTPUT" | grep -oP 'https://[^\s]+/invite/[^\s]+' | head -1)

if [[ -n "$INVITE_URL" ]]; then
  ok "Onboard complete. Admin invite URL:"
  echo ""
  echo "    $INVITE_URL"
  echo ""
else
  # Instance may already be onboarded — try bootstrap-ceo directly
  BOOTSTRAP_OUTPUT=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
    pnpm paperclipai auth bootstrap-ceo 2>&1 || true)
  INVITE_URL=$(echo "$BOOTSTRAP_OUTPUT" | grep -oP 'https://[^\s]+/invite/[^\s]+' | head -1)
  if [[ -n "$INVITE_URL" ]]; then
    ok "Bootstrap CEO invite URL:"
    echo ""
    echo "    $INVITE_URL"
    echo ""
  else
    warn "Could not extract invite URL. Check logs:"
    echo "$BOOTSTRAP_OUTPUT" | tail -5
  fi
fi

# Save invite URL to file for retrieval later
if [[ -n "${INVITE_URL:-}" ]]; then
  echo "$INVITE_URL" > "/tmp/${RELEASE}-invite-url.txt"
  ok "Invite URL also saved to /tmp/${RELEASE}-invite-url.txt"
fi

# Clean up temp config (persistent copy is inside pod)
rm -f "/tmp/${RELEASE}-onboard-config.json"

# ---------- Step 8: Tunnel route ----------
log "Step 8/12: Adding Cloudflare tunnel route..."
CF_TOKEN=$(get_cf_token)

CURRENT_CONFIG=$(curl -sf -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
  | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['result']['config']))" 2>/dev/null)

UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
ingress = config['ingress']
hostname = '${HOSTNAME}'
service = 'http://${RELEASE}.${NAMESPACE}.svc.cluster.local:${SERVICE_PORT}'
if not any(r.get('hostname') == hostname for r in ingress):
    ingress.insert(-1, {'hostname': hostname, 'service': service})
config['ingress'] = ingress
print(json.dumps({'config': config}))
" 2>/dev/null)

RESULT=$(curl -sf -X PUT -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d "$UPDATED_CONFIG" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)

[[ "$RESULT" == "True" ]] && ok "Tunnel route added" || warn "Failed to add tunnel route (may need dashboard)"

# ---------- Step 9: DNS CNAME ----------
log "Step 9/12: Creating DNS CNAME record..."
EXISTS=$(curl -sf -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}" \
  | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null)

if [[ "$EXISTS" == "0" ]]; then
  DNS_RESULT=$(curl -sf -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"${SLUG}\",\"content\":\"${CF_TUNNEL_CNAME}\",\"proxied\":true}" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)
  [[ "$DNS_RESULT" == "True" ]] && ok "DNS CNAME created" || warn "Failed to create DNS (may need dashboard)"
else
  ok "DNS record already exists"
fi

# ---------- Step 10: Validate ----------
log "Step 10/12: Validating deployment..."
sleep 5

# External check
for i in $(seq 1 6); do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "https://${HOSTNAME}/" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "External health check: ${HOSTNAME} → HTTP $HTTP_CODE"
    break
  fi
  if [[ "$i" -eq 6 ]]; then
    warn "External not ready yet (HTTP $HTTP_CODE). DNS may need time to propagate."
  fi
  sleep 10
done

# ---------- Step 11: CLI Context ----------
log "Step 11/12: Creating pc CLI context..."
cat > "${PCNG_REPO}/contexts/${CONTEXT_NAME}.env" << ENV
PC_NS=${NAMESPACE}
PC_PIPELINE=${CONTEXT_NAME}
PC_SVC=${RELEASE}
PC_QUEUE=${CONTEXT_NAME}:builds
PC_CONTROL_DIR=/tmp/pc-autopilot/.control
PC_REGISTRY=/tmp/pc-autopilot/registry/deployed.json
PC_LOG_DIR=/tmp/pc-autopilot/logs
PC_STATUS_FILE=/tmp/pc-autopilot/.pipeline-status
PC_TMUX_SESSION=${CONTEXT_NAME}-autopilot
ENV

mkdir -p ~/.pc/contexts
cp "${PCNG_REPO}/contexts/${CONTEXT_NAME}.env" ~/.pc/contexts/
ok "Context '${CONTEXT_NAME}' created"

# ---------- Step 12: Restart pod and validate onboard persisted ----------
log "Step 12/13: Restarting Paperclip to apply onboard config..."
kubectl rollout restart deploy "$RELEASE" -n "$NAMESPACE" 2>/dev/null
sleep 15
kubectl wait --for=condition=ready pod -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=server" -n "$NAMESPACE" --timeout=60s 2>/dev/null && ok "Pod restarted and ready" || warn "Pod restart may still be in progress"

# ---------- Step 13: Post-restart validation ----------
log "Step 13/13: Validating instance is onboarded and functional..."
NEW_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# Check config survived restart
if kubectl exec "$NEW_POD" -n "$NAMESPACE" -- test -f /paperclip/instances/default/config.json 2>/dev/null; then
  ok "Config persisted across restart"
else
  err "Config LOST after restart — onboard must be re-run manually"
  warn "  kubectl exec $NEW_POD -n $NAMESPACE -- pnpm paperclipai onboard --yes"
fi

# Check the app is NOT showing onboarding page (API returns 401 for auth, not 403 for uninitialized)
sleep 5
API_STATUS=$(kubectl exec "$NEW_POD" -n "$NAMESPACE" -- curl -sf -o /dev/null -w "%{http_code}" "http://localhost:${SERVICE_PORT}/api/companies" 2>/dev/null || echo "000")
if [[ "$API_STATUS" == "401" ]]; then
  ok "Instance onboarded — API returns 401 (auth required, not setup-required)"
elif [[ "$API_STATUS" == "403" ]]; then
  warn "Instance may still be in setup mode (API returns 403)"
  warn "  Regenerate invite: kubectl exec $NEW_POD -n $NAMESPACE -- pnpm paperclipai auth bootstrap-ceo"
else
  warn "Unexpected API status: $API_STATUS"
fi

# Regenerate invite URL after restart (old one may be invalidated)
FRESH_INVITE=$(kubectl exec "$NEW_POD" -n "$NAMESPACE" -- \
  pnpm paperclipai auth bootstrap-ceo 2>&1 | grep -oP 'https://[^\s]+/invite/[^\s]+' | head -1 || true)
if [[ -n "$FRESH_INVITE" ]]; then
  INVITE_URL="$FRESH_INVITE"
  echo "$INVITE_URL" > "/tmp/${RELEASE}-invite-url.txt"
  ok "Fresh invite URL generated (valid post-restart)"
fi

# ---------- Done ----------
echo ""
log "=========================================="
log "  Paperclip instance provisioned!"
log "=========================================="
echo ""
echo "  Release:    $RELEASE"
echo "  Namespace:  $NAMESPACE"
echo "  URL:        https://${HOSTNAME}"
echo "  CLI:        pc context use $CONTEXT_NAME"
echo "  Values:     $VALUES_FILE"
echo ""
echo "  Pods:"
kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | sed 's/^/    /'
echo ""
if [[ -n "${INVITE_URL:-}" ]]; then
echo -e "${RED}  ┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${RED}  │  ${YELLOW}ACTION REQUIRED: Claim the admin invite NOW${RED}                  │${NC}"
echo -e "${RED}  │                                                              │${NC}"
echo -e "${RED}  │${NC}  The instance is running but has NO admin user.              ${RED}│${NC}"
echo -e "${RED}  │${NC}  Open this URL in your browser to register:                 ${RED}│${NC}"
echo -e "${RED}  │${NC}                                                              ${RED}│${NC}"
echo -e "${RED}  │${NC}  ${GREEN}${INVITE_URL}${NC}"
echo -e "${RED}  │${NC}                                                              ${RED}│${NC}"
echo -e "${RED}  │${NC}  ${YELLOW}The instance will show 'setup required' until you do this.${NC}  ${RED}│${NC}"
echo -e "${RED}  │${NC}  Invite saved to: /tmp/${RELEASE}-invite-url.txt             ${RED}│${NC}"
echo -e "${RED}  └──────────────────────────────────────────────────────────────┘${NC}"
echo ""
fi
echo "  After claiming the invite:"
echo "    1. Add '$CONTEXT_NAME' to pc CLI validation regex in /usr/local/bin/pc"
echo "    2. Commit: git add overrides-${RELEASE}.yaml && git push"
echo ""
