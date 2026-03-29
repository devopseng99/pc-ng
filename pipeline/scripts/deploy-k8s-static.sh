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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --name)      APP_NAME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --node)      NODE="$2"; shift 2 ;;
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

# --- 6. Report ---
local_url="http://${K8S_NAME}.${NAMESPACE}.svc.cluster.local"
log "=== Deployed ==="
log "  App:       $APP_NAME"
log "  K8s Name:  $K8S_NAME"
log "  Namespace: $NAMESPACE"
log "  Service:   $local_url"
log "  Image:     $IMAGE"
log ""
log "To expose via Cloudflare tunnel, add to tunnel config:"
log "  hostname: ${K8S_NAME}.istayintek.com"
log "  service:  $local_url:80"

echo "$local_url"
