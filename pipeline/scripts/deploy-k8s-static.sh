#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Deploy static Next.js app to K8s as nginx pod (helper-pod approach)
#
# Usage: ./deploy-k8s-static.sh --repo <github-repo> --name <app-name> [options]
#
# Clones repo, builds Next.js static export, transfers via helper pod to
# hostPath on worker node, deploys nginx:alpine serving the static files.
# Automatically adds Cloudflare tunnel route + DNS record.
#
# Options:
#   --repo         GitHub repo name (required)
#   --name         App display name (defaults to repo name)
#   --namespace    K8s namespace (default: paperclip)
#   --node         Worker node (default: mgplcb05)
#   --skip-tunnel  Skip Cloudflare tunnel/DNS setup
#   --domain       Domain for public URL (default: istayintek.com)
#   --app-id       App ID for CRD labeling
# ============================================================================

REPO=""
APP_NAME=""
APP_ID=""
NAMESPACE="paperclip"
NODE="mgplcb05"
SKIP_TUNNEL=false
DOMAIN="istayintek.com"
STATIC_BASE="/opt/k8s-pers/vol1/static-sites"

# Cloudflare tunnel config (API-managed)
CF_ACCOUNT_ID="9709bd1f498109e65ff5d1898fec15ee"
CF_TUNNEL_ID="b2c521bb-d042-4e59-89ce-f94cef67175b"
CF_ZONE_ID="0e34ae940d6ef78c3812c5d1244f63f2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --name)        APP_NAME="$2"; shift 2 ;;
    --app-id)      APP_ID="$2"; shift 2 ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --node)        NODE="$2"; shift 2 ;;
    --skip-tunnel) SKIP_TUNNEL=true; shift ;;
    --domain)      DOMAIN="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$REPO" ]] && { echo "Error: --repo required"; exit 1; }
[[ -z "$APP_NAME" ]] && APP_NAME="$REPO"

# Sanitize for K8s resource names
K8S_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/-$//' | head -c 63)
BUILD_DIR="/tmp/build-${REPO}"
HELPER_POD="static-helper-$$"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
cleanup() {
  kubectl delete pod "$HELPER_POD" -n "$NAMESPACE" --ignore-not-found --wait=false &>/dev/null || true
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

export GH_TOKEN="${GH_TOKEN:-$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)}"

# Resolve CF token
if [[ "$SKIP_TUNNEL" != "true" ]]; then
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    CF_TOKEN_FILE=$(ls -t ~/cf-token--* 2>/dev/null | head -1)
    if [[ -n "$CF_TOKEN_FILE" ]]; then
      CF_API_TOKEN=$(cat "$CF_TOKEN_FILE")
    else
      CF_API_TOKEN=$(kubectl get secret cloudflare-credentials -n paperclip -o jsonpath='{.data.CF_API_TOKEN}' 2>/dev/null | base64 -d || true)
    fi
  fi
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    log "WARNING: No CF token found — skipping tunnel/DNS setup"
    SKIP_TUNNEL=true
  fi
fi

# --- 1. Clone and build ---
log "Cloning devopseng99/$REPO..."
rm -rf "$BUILD_DIR"
git clone --depth 1 "https://${GH_TOKEN}@github.com/devopseng99/${REPO}.git" "$BUILD_DIR" 2>&1

log "Installing dependencies..."
cd "$BUILD_DIR"
npm install --legacy-peer-deps 2>&1 | tail -3

log "Building static export..."
npx next build 2>&1 | tail -5

# Verify output
if [[ ! -d "$BUILD_DIR/out" ]]; then
  log "ERROR: No out/ directory after build"
  exit 1
fi
FILE_COUNT=$(find "$BUILD_DIR/out" -type f | wc -l)
log "Build output: $FILE_COUNT files"

# --- 2. Ensure shared nginx configmap exists ---
kubectl apply -f - <<'CFGEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: static-nginx-conf
  namespace: paperclip
data:
  default.conf: |
    server {
        listen 80;
        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri.html $uri/ /index.html;
        }

        location /_next/static/ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        gzip on;
        gzip_types text/plain text/css application/json application/javascript text/xml;
    }
CFGEOF

# --- 3. Transfer static files via helper pod ---
SITE_PATH="${STATIC_BASE}/${K8S_NAME}"
log "Transferring files to ${NODE}:${SITE_PATH} via helper pod..."

# Launch helper pod with hostPath mount to the parent directory
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: ${NAMESPACE}
  labels:
    app: static-helper
spec:
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  containers:
  - name: helper
    image: nginx:alpine
    command: ["sleep", "300"]
    volumeMounts:
    - name: static-root
      mountPath: /static-sites
  volumes:
  - name: static-root
    hostPath:
      path: ${STATIC_BASE}
      type: DirectoryOrCreate
  restartPolicy: Never
EOF

# Wait for helper pod to be ready
log "Waiting for helper pod..."
kubectl wait --for=condition=Ready pod/"$HELPER_POD" -n "$NAMESPACE" --timeout=60s 2>&1

# Create app directory and clear any old content
kubectl exec "$HELPER_POD" -n "$NAMESPACE" -- sh -c "rm -rf /static-sites/${K8S_NAME} && mkdir -p /static-sites/${K8S_NAME}"

# Tar the build output and pipe through kubectl cp
log "Copying $FILE_COUNT files..."
cd "$BUILD_DIR"
tar cf - -C out . | kubectl exec -i "$HELPER_POD" -n "$NAMESPACE" -- tar xf - -C "/static-sites/${K8S_NAME}"

# Verify files landed
REMOTE_COUNT=$(kubectl exec "$HELPER_POD" -n "$NAMESPACE" -- find "/static-sites/${K8S_NAME}" -type f | wc -l)
log "Verified: $REMOTE_COUNT files on ${NODE}"

# Clean up helper pod
kubectl delete pod "$HELPER_POD" -n "$NAMESPACE" --wait=false 2>/dev/null
# Prevent trap from double-deleting
HELPER_POD="already-deleted"

# --- 4. Deploy to K8s ---
log "Deploying to K8s namespace=$NAMESPACE..."
APP_ID_LABEL=""
if [[ -n "$APP_ID" ]]; then
  APP_ID_LABEL="    app-id: \"${APP_ID}\""
fi

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${K8S_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${K8S_NAME}
${APP_ID_LABEL}
    managed-by: pc-ng
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${K8S_NAME}
  template:
    metadata:
      labels:
        app: ${K8S_NAME}
        managed-by: pc-ng
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${NODE}
      containers:
      - name: nginx
        image: nginx:alpine
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 30
        volumeMounts:
        - name: static-content
          mountPath: /usr/share/nginx/html
          readOnly: true
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
          readOnly: true
      volumes:
      - name: static-content
        hostPath:
          path: ${SITE_PATH}
          type: Directory
      - name: nginx-conf
        configMap:
          name: static-nginx-conf
---
apiVersion: v1
kind: Service
metadata:
  name: ${K8S_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${K8S_NAME}
    managed-by: pc-ng
spec:
  type: ClusterIP
  selector:
    app: ${K8S_NAME}
  ports:
  - port: 80
    targetPort: 80
EOF

# Wait for rollout
kubectl rollout status "deployment/${K8S_NAME}" -n "$NAMESPACE" --timeout=120s 2>&1

# --- 5. Add Cloudflare tunnel route + DNS ---
local_url="http://${K8S_NAME}.${NAMESPACE}.svc.cluster.local"
public_url=""

if [[ "$SKIP_TUNNEL" != "true" ]]; then
  HOSTNAME="${K8S_NAME}.${DOMAIN}"
  SERVICE_URL="${local_url}:80"

  # Fetch current tunnel config
  CURRENT_CONFIG=$(curl -sf \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
    | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['result']['config']))")

  # Check if tunnel route already exists for this hostname+service
  ROUTE_EXISTS=$(echo "$CURRENT_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
hostname = '${HOSTNAME}'
service = '${SERVICE_URL}'
for r in config.get('ingress', []):
    if r.get('hostname') == hostname and r.get('service') == service:
        print('yes'); break
else:
    print('no')
")

  if [[ "$ROUTE_EXISTS" == "yes" ]]; then
    log "Tunnel route already exists: $HOSTNAME -> $SERVICE_URL (skipping)"
  else
    log "Adding Cloudflare tunnel route: $HOSTNAME -> $SERVICE_URL"
    UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
hostname = '${HOSTNAME}'
service = '${SERVICE_URL}'
ingress = config.get('ingress', [])
# Remove existing rule for this hostname if present (stale service URL)
ingress = [r for r in ingress if r.get('hostname') != hostname]
# Remove catch-all (last rule), add new rule, re-add catch-all
catch_all = {'service': 'http_status:404'}
if ingress and 'hostname' not in ingress[-1]:
    catch_all = ingress.pop()
ingress.append({'hostname': hostname, 'service': service})
ingress.append(catch_all)
config['ingress'] = ingress
print(json.dumps({'config': config}))
")

    TUNNEL_RESP=$(curl -sf -X PUT \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$UPDATED_CONFIG" \
      "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations")

    if echo "$TUNNEL_RESP" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
      log "  Tunnel route added"
    else
      log "  WARNING: Tunnel route update failed"
      log "  Response: $TUNNEL_RESP"
    fi
  fi

  # Check if DNS CNAME already exists
  DNS_EXISTS=$(curl -sf \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('result_info',{}).get('count',0)>0 else 'no')" 2>/dev/null || echo "no")

  if [[ "$DNS_EXISTS" == "yes" ]]; then
    log "DNS CNAME already exists: $HOSTNAME (skipping)"
  else
    log "Creating DNS CNAME: $HOSTNAME -> ${CF_TUNNEL_ID}.cfargotunnel.com"
    DNS_RESP=$(curl -sf -X POST \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records")

    if echo "$DNS_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['success']" 2>/dev/null; then
      log "  DNS record created"
    else
      log "  WARNING: DNS record creation failed"
      log "  Response: $DNS_RESP"
    fi
  fi

  public_url="https://${HOSTNAME}"
fi

# --- 6. Cleanup ---
rm -rf "$BUILD_DIR"
log "Cleaned up build dir"

# --- 7. Report ---
log "=== Deployed ==="
log "  App:       $APP_NAME"
log "  K8s Name:  $K8S_NAME"
log "  Namespace: $NAMESPACE"
log "  Service:   $local_url"
if [[ -n "$public_url" ]]; then
  log "  Public:    $public_url"
fi

echo "${public_url:-$local_url}"
