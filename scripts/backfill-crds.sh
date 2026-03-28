#!/usr/bin/env bash
#
# backfill-crds.sh — Read deployed.json and create PaperclipBuild CRs
# for all existing apps. Idempotent (uses kubectl apply).
#
set -euo pipefail

DEPLOYED_JSON="/tmp/pc-autopilot/registry/deployed.json"
NAMESPACE="paperclip-v3"

if [[ ! -f "$DEPLOYED_JSON" ]]; then
  echo "ERROR: $DEPLOYED_JSON not found" >&2
  exit 1
fi

# Parse deployed.json and emit tab-separated records:
#   id  name  prefix  repo  status  category  deployed_at
read_apps() {
  python3 -c "
import json, sys

with open('${DEPLOYED_JSON}') as f:
    data = json.load(f)

for app in data.get('apps', []):
    app_id = app['id']
    name = app['name']
    prefix = app['prefix']
    repo = app.get('repo', '')
    status = app.get('status', 'deployed')
    category = app.get('category', 'Misc')
    deployed_at = app.get('deployed_at', '')
    print(f'{app_id}\t{name}\t{prefix}\t{repo}\t{status}\t{category}\t{deployed_at}')
"
}

# Convert a string to kebab-case (lowercase, spaces/underscores to hyphens)
to_kebab() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[_ ]/-/g' | sed 's/[^a-z0-9-]//g'
}

# Map deployed.json status to CRD phase
map_phase() {
  local status="$1"
  case "$status" in
    deployed)    echo "Deployed" ;;
    *_failed)    echo "Failed" ;;
    disk_full)   echo "Failed" ;;
    *)           echo "Pending" ;;
  esac
}

total=0
deployed_count=0
failed_count=0

# Count total apps first for progress display
total_apps=$(read_apps | wc -l)

while IFS=$'\t' read -r app_id name prefix repo status category deployed_at; do
  total=$((total + 1))

  # Determine pipeline
  if [[ "$app_id" -le 400 ]]; then
    pipeline="v1"
  else
    pipeline="tech"
  fi

  # Build CR name: pb-<id>-<prefix>, lowercase, max 63 chars
  cr_name="pb-${app_id}-$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
  cr_name="${cr_name:0:63}"

  phase=$(map_phase "$status")
  category_label=$(to_kebab "$category")

  # Build status fields
  deploy_url=""
  error_msg=""
  completed_at=""

  if [[ "$phase" == "Deployed" ]]; then
    deploy_url="https://${repo}.pages.dev"
    deployed_count=$((deployed_count + 1))
  elif [[ "$phase" == "Failed" ]]; then
    error_msg="$status"
    failed_count=$((failed_count + 1))
  fi

  if [[ -n "$deployed_at" ]]; then
    if [[ "$deployed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      completed_at="${deployed_at}T00:00:00Z"
    else
      completed_at="$deployed_at"
    fi
  fi

  echo "[${total}/${total_apps}] Creating ${cr_name} (${name}) -> ${phase}"

  kubectl apply -f - <<EOF
apiVersion: paperclip.istayintek.com/v1alpha1
kind: PaperclipBuild
metadata:
  name: ${cr_name}
  namespace: ${NAMESPACE}
  labels:
    pipeline: "${pipeline}"
    app-id: "${app_id}"
    category: "${category_label}"
spec:
  appId: ${app_id}
  appName: "${name}"
  prefix: "${prefix}"
  category: "${category}"
  pipeline: "${pipeline}"
  repo: "${repo}"
  priority: 5
EOF

  # Patch status subresource separately (status is not part of spec)
  kubectl patch paperclipbuild "${cr_name}" \
    -n "${NAMESPACE}" \
    --type merge \
    --subresource status \
    -p "{\"status\":{\"phase\":\"${phase}\"${deploy_url:+,\"deployUrl\":\"${deploy_url}\"}${error_msg:+,\"errorMessage\":\"${error_msg}\"}${completed_at:+,\"completedAt\":\"${completed_at}\"}}}" \
    2>/dev/null || true

done < <(read_apps)

echo ""
echo "Backfilled ${total} builds (${deployed_count} deployed, ${failed_count} failed)"
