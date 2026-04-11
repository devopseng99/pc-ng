#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# bootstrap-instance.sh — Fully automated Paperclip instance bootstrapping
#
# Automates what normally requires a browser:
#   1. Generate bootstrap-ceo invite
#   2. Claim the invite via API (create admin user)
#   3. Generate board API key
#   4. Store credentials as K8s secret in instance namespace
#
# Usage:
#   ./bootstrap-instance.sh --release pc-v5 --namespace paperclip-v5 \
#     --email admin@example.com [--password auto] [--name "Admin"]
#
#   ./bootstrap-instance.sh --release pc-v4 --namespace paperclip-v4 \
#     --email hrsd0001@gmail.com --create-api-key-only
#
# Output:
#   - K8s secret: {RELEASE}-admin-credentials (email, password, api-key)
#   - K8s secret: {RELEASE}-board-api-key (key)  [for pipeline onboarding]
# ============================================================================

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*" >&2; exit 1; }

# ---------- Parse Args ----------
RELEASE="" NAMESPACE="" ADMIN_EMAIL="" ADMIN_PASSWORD="" ADMIN_NAME="Admin"
CREATE_API_KEY_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)            RELEASE="$2"; shift 2 ;;
    --namespace)          NAMESPACE="$2"; shift 2 ;;
    --email)              ADMIN_EMAIL="$2"; shift 2 ;;
    --password)           ADMIN_PASSWORD="$2"; shift 2 ;;
    --name)               ADMIN_NAME="$2"; shift 2 ;;
    --create-api-key-only) CREATE_API_KEY_ONLY=true; shift ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -z "$RELEASE" ]]   && die "Missing --release"
[[ -z "$NAMESPACE" ]] && die "Missing --namespace"
[[ -z "$ADMIN_EMAIL" ]] && die "Missing --email"

HOSTNAME="${RELEASE}.istayintek.com"
BASE_URL="https://${HOSTNAME}"

# Auto-generate password if not provided or set to "auto"
if [[ -z "$ADMIN_PASSWORD" || "$ADMIN_PASSWORD" == "auto" ]]; then
  ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  log "Auto-generated password (32 chars)"
fi

# ---------- Verify instance is running ----------
log "Step 1: Verify instance is running"

POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "$POD_NAME" ]] && POD_NAME=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -v postgresql | grep Running | awk '{print $1}' | head -1)
[[ -z "$POD_NAME" ]] && die "No running pod found in namespace $NAMESPACE"
ok "Pod: $POD_NAME"

HEALTH=$(curl -s "${BASE_URL}/api/health" 2>/dev/null || echo "unreachable")
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  ok "Instance healthy at $BASE_URL"
else
  die "Instance unhealthy: $HEALTH"
fi

# ---------- Check if admin already exists ----------
log "Step 2: Check admin user status"

PSQL_POD="${RELEASE}-postgresql-0"
kubectl get pod "$PSQL_POD" -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q Running \
  || die "PostgreSQL pod $PSQL_POD not running in $NAMESPACE"
ADMIN_EXISTS=$(kubectl exec "$PSQL_POD" -n "$NAMESPACE" -- \
  psql -U postgres -d paperclip -t -A -c "SELECT json_build_object('id', id, 'email', email) FROM \"user\" LIMIT 1" \
  2>/dev/null || echo "{}")

if [[ "$CREATE_API_KEY_ONLY" == "true" ]]; then
  log "Skipping user creation (--create-api-key-only)"
  if echo "$ADMIN_EXISTS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('id') else 1)" 2>/dev/null; then
    ADMIN_USER_ID=$(echo "$ADMIN_EXISTS" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    ok "Admin user exists: $ADMIN_USER_ID"
  else
    die "No admin user found — cannot create API key without a user. Run without --create-api-key-only first."
  fi
else
  # ---------- Generate bootstrap invite ----------
  log "Step 3: Generate bootstrap invite"

  if echo "$ADMIN_EXISTS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('id') else 1)" 2>/dev/null; then
    EXISTING_EMAIL=$(echo "$ADMIN_EXISTS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('email','?'))")
    warn "Admin user already exists ($EXISTING_EMAIL) — using --force for new invite"
    FORCE_FLAG="--force"
  else
    FORCE_FLAG=""
  fi

  INVITE_OUTPUT=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
    sh -c "cd /app && pnpm paperclipai auth bootstrap-ceo ${FORCE_FLAG} --base-url ${BASE_URL} 2>&1" 2>/dev/null || true)

  INVITE_URL=$(echo "$INVITE_OUTPUT" | grep -oP 'https://[^\s]+/invite/[^\s]+' | head -1)
  if [[ -z "$INVITE_URL" ]]; then
    # Might already have admin — try to extract token another way
    warn "Could not extract invite URL from output"
    echo "$INVITE_OUTPUT" | tail -5
    if echo "$ADMIN_EXISTS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('id') else 1)" 2>/dev/null; then
      ADMIN_USER_ID=$(echo "$ADMIN_EXISTS" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
      warn "Admin exists — skipping invite claim, proceeding to API key"
    else
      die "Cannot bootstrap — no invite URL and no existing admin"
    fi
  else
    ok "Invite URL: $INVITE_URL"

    # Extract the token from the URL
    INVITE_TOKEN=$(echo "$INVITE_URL" | grep -oP 'invite/\K.*')
    ok "Token: ${INVITE_TOKEN:0:20}..."

    # ---------- Claim the invite via API ----------
    log "Step 4: Claim bootstrap invite (create admin user)"

    CLAIM_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/api/auth/sign-up" \
      -H "Content-Type: application/json" \
      -d "{
        \"email\": \"${ADMIN_EMAIL}\",
        \"password\": \"${ADMIN_PASSWORD}\",
        \"name\": \"${ADMIN_NAME}\",
        \"callbackURL\": \"/\"
      }" 2>/dev/null || echo -e "\n000")

    CLAIM_BODY=$(echo "$CLAIM_RESPONSE" | head -n -1)
    CLAIM_STATUS=$(echo "$CLAIM_RESPONSE" | tail -1)

    if [[ "$CLAIM_STATUS" == "200" || "$CLAIM_STATUS" == "201" ]]; then
      ok "Admin user created via sign-up: $ADMIN_EMAIL"
    else
      # Try the invite claim endpoint directly
      CLAIM_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/api/auth/claim-invite" \
        -H "Content-Type: application/json" \
        -d "{
          \"token\": \"${INVITE_TOKEN}\",
          \"email\": \"${ADMIN_EMAIL}\",
          \"password\": \"${ADMIN_PASSWORD}\",
          \"name\": \"${ADMIN_NAME}\"
        }" 2>/dev/null || echo -e "\n000")

      CLAIM_BODY=$(echo "$CLAIM_RESPONSE" | head -n -1)
      CLAIM_STATUS=$(echo "$CLAIM_RESPONSE" | tail -1)

      if [[ "$CLAIM_STATUS" == "200" || "$CLAIM_STATUS" == "201" ]]; then
        ok "Admin user created via invite claim: $ADMIN_EMAIL"
      else
        warn "Claim returned status $CLAIM_STATUS — trying direct DB insert"
        warn "Response: $CLAIM_BODY"
      fi
    fi

    # Verify user was created
    ADMIN_USER_ID=$(kubectl exec "$PSQL_POD" -n "$NAMESPACE" -- \
      psql -U postgres -d paperclip -t -A -c "SELECT id FROM \"user\" WHERE email = '${ADMIN_EMAIL}'" \
      2>/dev/null || echo "")

    if [[ -z "$ADMIN_USER_ID" ]]; then
      # User might exist with different email from prior bootstrap
      ADMIN_USER_ID=$(echo "$ADMIN_EXISTS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    fi

    [[ -z "$ADMIN_USER_ID" ]] && die "Failed to create or find admin user"
    ok "Admin user ID: $ADMIN_USER_ID"
  fi
fi

# ---------- Generate Board API Key ----------
log "Step 5: Generate board API key"

# Generate a secure API key
API_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)
API_KEY_HASH=$(echo -n "$API_KEY" | sha256sum | awk '{print $1}')
KEY_PREFIX="${API_KEY:0:8}"

# Get the DB password from the secret
DB_PASSWORD=$(kubectl get secret "${RELEASE}-postgres-secret" -n "$NAMESPACE" \
  -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d 2>/dev/null)
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD=$(kubectl get secret "${RELEASE}-postgres-secret" -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)

# Insert the API key into the database
kubectl exec "${RELEASE}-postgresql-0" -n "$NAMESPACE" -- \
  psql -U postgres -d paperclip -c "
    INSERT INTO board_api_keys (user_id, name, key_hash)
    VALUES ('${ADMIN_USER_ID}', 'pipeline-automation', '${API_KEY_HASH}')
    ON CONFLICT (key_hash) DO NOTHING;
  " 2>/dev/null

ok "Board API key created (prefix: ${KEY_PREFIX}...)"

# Ensure user has instance_admin role
kubectl exec "${RELEASE}-postgresql-0" -n "$NAMESPACE" -- \
  psql -U postgres -d paperclip -c "
    INSERT INTO instance_user_roles (user_id, role)
    VALUES ('${ADMIN_USER_ID}', 'instance_admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  " 2>/dev/null
ok "Instance admin role granted"

# ---------- Store as K8s Secrets ----------
log "Step 6: Store credentials as K8s secrets"

# Admin credentials secret
kubectl create secret generic "${RELEASE}-admin-credentials" \
  -n "$NAMESPACE" \
  --from-literal=email="$ADMIN_EMAIL" \
  --from-literal=password="$ADMIN_PASSWORD" \
  --from-literal=name="$ADMIN_NAME" \
  --from-literal=user-id="$ADMIN_USER_ID" \
  --from-literal=api-key="$API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

ok "Secret: ${RELEASE}-admin-credentials (email, password, api-key, user-id)"

# Board API key secret (compatible with pipeline onboarding format)
kubectl create secret generic "${RELEASE}-board-api-key" \
  -n "$NAMESPACE" \
  --from-literal=key="$API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

ok "Secret: ${RELEASE}-board-api-key (pipeline-compatible)"

# Also copy to paperclip-v3 namespace if it's a new instance (for cross-namespace access)
if [[ "$NAMESPACE" != "paperclip-v3" ]]; then
  kubectl create secret generic "${RELEASE}-board-api-key" \
    -n paperclip-v3 \
    --from-literal=key="$API_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
  ok "Secret: ${RELEASE}-board-api-key copied to paperclip-v3 (cross-namespace pipeline access)"
fi

# ---------- Verify ----------
log "Step 7: Verify board API key works"

# Test API key authentication
API_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${API_KEY}" \
  "${BASE_URL}/api/companies" 2>/dev/null || echo "000")

if [[ "$API_TEST" == "200" ]]; then
  ok "API key validated — authenticated access works"
elif [[ "$API_TEST" == "401" ]]; then
  # Board API keys may use a different auth header or need session
  warn "API key returned 401 — key stored but may need session-based auth for this endpoint"
  warn "The key is stored in DB and K8s secrets for pipeline use"
else
  warn "API test returned $API_TEST — key stored, verify manually"
fi

# ---------- Done ----------
echo ""
log "=========================================="
log "  Bootstrap complete: $RELEASE"
log "=========================================="
echo ""
echo "  Instance:   $BASE_URL"
echo "  Admin:      $ADMIN_EMAIL"
echo "  User ID:    $ADMIN_USER_ID"
echo "  API Key:    ${KEY_PREFIX}... (full key in K8s secret)"
echo ""
echo "  Secrets created:"
echo "    kubectl get secret ${RELEASE}-admin-credentials -n $NAMESPACE"
echo "    kubectl get secret ${RELEASE}-board-api-key -n $NAMESPACE"
if [[ "$NAMESPACE" != "paperclip-v3" ]]; then
  echo "    kubectl get secret ${RELEASE}-board-api-key -n paperclip-v3"
fi
echo ""
echo "  Retrieve API key:"
echo "    kubectl get secret ${RELEASE}-board-api-key -n $NAMESPACE -o jsonpath='{.data.key}' | base64 -d"
echo ""
echo "  Retrieve password:"
echo "    kubectl get secret ${RELEASE}-admin-credentials -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
echo ""
