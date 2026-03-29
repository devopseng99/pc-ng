#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Deploy a built Next.js static export to Cloudflare Pages
# Usage: ./deploy-cf.sh --repo <repo-name> --name <cf-project-name>
# ============================================================================

REPO="" CF_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --name) CF_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$REPO" ]] && { echo "Error: --repo required"; exit 1; }
CF_NAME="${CF_NAME:-$REPO}"

export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(kubectl get secret cloudflare-api-keys -n paperclip -o jsonpath='{.data.CLOUDFLARE_API_TOKEN}' | base64 -d)}"
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$(kubectl get secret cloudflare-api-keys -n paperclip -o jsonpath='{.data.CLOUDFLARE_ACCOUNT_ID}' | base64 -d)}"

BUILD_DIR="/tmp/$REPO"

# If not already cloned/built locally, clone and build
if [[ ! -d "$BUILD_DIR/out" ]]; then
  export GH_TOKEN="${GH_TOKEN:-$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)}"
  echo "Cloning and building $REPO..."
  rm -rf "$BUILD_DIR" 2>/dev/null
  git clone "https://${GH_TOKEN}@github.com/devopseng99/${REPO}.git" "$BUILD_DIR" 2>/dev/null
  cd "$BUILD_DIR"
  npm install --silent 2>/dev/null
  npm run build 2>/dev/null
fi

cd "$BUILD_DIR"

# Create CF Pages project via REST API (idempotent)
curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$CF_NAME\",\"production_branch\":\"main\"}" \
  --max-time 30 > /dev/null 2>&1 || true

sleep 3

# Deploy
wrangler pages deploy out --project-name "$CF_NAME" --branch main 2>&1

echo "Deployed: https://${CF_NAME}.pages.dev"
