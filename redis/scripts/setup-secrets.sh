#!/usr/bin/env bash
set -euo pipefail

# Create redis-credentials secret in paperclip-v3 namespace
# Idempotent: dry-run + apply pattern

NS="paperclip-v3"
SECRET_NAME="redis-credentials"

# Generate password if not provided
REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -base64 24)}"

echo "=== Redis Secret Setup ==="
echo "Namespace: $NS"
echo "Secret:    $SECRET_NAME"
echo ""

# Dry run first
echo "--- Dry Run ---"
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NS" \
  --from-literal=password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml

echo ""
read -p "Apply? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy] ]]; then
  kubectl create secret generic "$SECRET_NAME" \
    --namespace "$NS" \
    --from-literal=password="$REDIS_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret applied."
  echo ""
  echo "Redis password: $REDIS_PASSWORD"
  echo "Save this password — it won't be shown again."
else
  echo "Skipped."
fi
