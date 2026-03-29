#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Deploy static Next.js app to K8s as nginx pod
#
# Usage: ./deploy-k8s-static.sh --repo <github-repo> --name <app-name> [--namespace paperclip]
#
# Clones repo, builds Next.js static export, wraps in nginx container,
# deploys to K8s with a ClusterIP service.
# ============================================================================

REPO=""
APP_NAME=""
NAMESPACE="paperclip"
NODE="mgplcb05"
SKIP_TUNNEL=false
DOMAIN="istayintek.com"

# Cloudflare tunnel config (API-managed)
CF_ACCOUNT_ID="9709bd1f498109e65ff5d1898fec15ee"
CF_TUNNEL_ID="b2c521bb-d042-4e59-89ce-f94cef67175b"
CF_ZONE_ID="0e34ae940d6ef78c3812c5d1244f63f2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --name)      APP_NAME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --node)      NODE="$2"; shift 2 ;;
    --skip-tunnel) SKIP_TUNNEL=true; shift ;;
    --domain)    DOMAIN="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$REPO" ]] && { echo "Error: --repo required"; exit 1; }
[[ -z "$APP_NAME" ]] && APP_NAME="$REPO"

# Sanitize for K8s resource names
K8S_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | head -c 63)
IMAGE="localhost/${K8S_NAME}:latest"
BUILD_DIR="/tmp/${REPO}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

export GH_TOKEN="${GH_TOKEN:-$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)}"

# Resolve CF token: env var > ~/cf-token--* file > K8s secret
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
    log "  Set CF_API_TOKEN env var or create ~/cf-token--<expiry> file"
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
log "Build output: $(find "$BUILD_DIR/out" -type f | wc -l) files"

# --- 2. Create nginx container ---
log "Building container image: $IMAGE"
cat > "$BUILD_DIR/Dockerfile.nginx" <<'DOCKERFILE'
FROM nginx:alpine
COPY out/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
DOCKERFILE

cat > "$BUILD_DIR/nginx.conf" <<'NGINX'
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
NGINX

# Build with podman
podman build -t "$IMAGE" -f "$BUILD_DIR/Dockerfile.nginx" "$BUILD_DIR" 2>&1 | tail -3

# --- 3. Import to containerd on worker node ---
log "Saving and importing image to $NODE..."
TARFILE="/tmp/${K8S_NAME}.tar"
podman save "$IMAGE" -o "$TARFILE" 2>&1

# Import locally if on the same node, or scp to worker
if [[ "$(hostname)" == "$NODE" ]]; then
  sudo /var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock -n k8s.io images import "$TARFILE" 2>&1
else
  # Try importing via the node where kubelet runs
  sudo /var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock -n k8s.io images import "$TARFILE" 2>&1 || {
    log "Local import failed, trying scp to $NODE..."
    scp "$TARFILE" "${NODE}:/tmp/" 2>&1
    ssh "$NODE" "sudo /var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock -n k8s.io images import /tmp/${K8S_NAME}.tar" 2>&1
  }
fi
rm -f "$TARFILE"

# --- 4. Deploy to K8s ---
log "Deploying to K8s namespace=$NAMESPACE..."
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${K8S_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${K8S_NAME}
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
        image: ${IMAGE}
        imagePullPolicy: Never
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

# --- 5. Cleanup ---
rm -rf "$BUILD_DIR"
log "Cleaned up $BUILD_DIR"

# --- 6. Add Cloudflare tunnel route + DNS ---
local_url="http://${K8S_NAME}.${NAMESPACE}.svc.cluster.local"
public_url=""

if [[ "$SKIP_TUNNEL" != "true" ]]; then
  HOSTNAME="${K8S_NAME}.${DOMAIN}"
  SERVICE_URL="${local_url}:80"
  log "Adding Cloudflare tunnel route: $HOSTNAME -> $SERVICE_URL"

  # Fetch current tunnel config
  CURRENT_CONFIG=$(curl -sf \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
    | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['result']['config']))")

  # Add new ingress rule (before the catch-all 404)
  UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
hostname = '${HOSTNAME}'
service = '${SERVICE_URL}'
ingress = config.get('ingress', [])
# Remove existing rule for this hostname if present
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

  # Push updated config
  TUNNEL_RESP=$(curl -sf -X PUT \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$UPDATED_CONFIG" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations")

  if echo "$TUNNEL_RESP" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
    log "  Tunnel route added ✓"
  else
    log "  WARNING: Tunnel route update failed — check CF token permissions"
    log "  Response: $TUNNEL_RESP"
  fi

  # Create DNS CNAME record (idempotent — CF deduplicates)
  log "Creating DNS CNAME: $HOSTNAME -> ${CF_TUNNEL_ID}.cfargotunnel.com"
  DNS_RESP=$(curl -sf -X POST \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records")

  if echo "$DNS_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['success'] or any('already' in str(e) for e in d.get('errors',[]))" 2>/dev/null; then
    log "  DNS record created ✓"
  else
    log "  WARNING: DNS record creation may have failed (could already exist)"
  fi

  public_url="https://${HOSTNAME}"
fi

# --- 7. Report ---
log "=== Deployed ==="
log "  App:       $APP_NAME"
log "  K8s Name:  $K8S_NAME"
log "  Namespace: $NAMESPACE"
log "  Service:   $local_url"
log "  Image:     $IMAGE"
if [[ -n "$public_url" ]]; then
  log "  Public:    $public_url"
fi

echo "${public_url:-$local_url}"
