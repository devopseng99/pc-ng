#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Rebuild deployed.json registry from PaperclipBuild CRDs in paperclip-v3
#
# This is a recovery tool — use when /tmp/pc-autopilot/registry/deployed.json
# is lost (e.g., after /tmp wipe or reboot).
#
# Usage: ./rebuild-registry.sh [--output /path/to/deployed.json]
# ============================================================================

OUTPUT="${1:-/tmp/pc-autopilot/registry/deployed.json}"

# Accept --output flag
if [[ "${1:-}" == "--output" ]]; then
  OUTPUT="${2:-/tmp/pc-autopilot/registry/deployed.json}"
fi

log() { echo "[rebuild-registry] $*"; }

log "Fetching PaperclipBuild CRDs from paperclip-v3..."

# Get all CRDs as JSON
CRD_JSON=$(kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null)

if [[ -z "$CRD_JSON" ]] || [[ "$CRD_JSON" == "null" ]]; then
  log "ERROR: No PaperclipBuild CRDs found in paperclip-v3"
  exit 1
fi

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

# Convert CRDs to deployed.json format — pipe via stdin to avoid arg length limits
echo "$CRD_JSON" | python3 -c "
import json, sys

data = json.load(sys.stdin)
items = data.get('items', [])

apps = []
for item in items:
    spec = item.get('spec', {})
    status = item.get('status', {})

    # Map CRD phase to registry status
    phase = status.get('phase', 'Pending')
    status_map = {
        'Deployed': 'deployed',
        'Failed': 'build_failed',
        'DeployUnverified': 'deploy_unverified',
        'Building': 'building',
        'Deploying': 'deploying',
        'Onboarding': 'onboarding',
        'Queued': 'queued',
        'Pending': 'pending',
    }
    reg_status = status_map.get(phase, 'unknown')

    # Check if it has a deploy URL — if so, it's either deployed or unverified
    deploy_url = status.get('deployUrl', '')
    if deploy_url and reg_status in ('build_failed', 'unknown'):
        reg_status = 'deployed'

    # Check error message for deploy failures
    error = status.get('errorMessage', '')
    if 'Deploy failed' in error:
        reg_status = 'deploy_failed'

    output_file = sys.argv[1]
    app = {
        'id': spec.get('appId', 0),
        'name': spec.get('appName', ''),
        'prefix': spec.get('prefix', ''),
        'repo': spec.get('repo', ''),
        'url': deploy_url,
        'company_id': 'unknown',
        'status': reg_status,
        'category': spec.get('category', 'Misc'),
        'pipeline': spec.get('pipeline', 'v1'),
        'deployed_at': (status.get('completedAt', '') or '')[:10] or item.get('metadata', {}).get('creationTimestamp', '')[:10]
    }
    apps.append(app)

apps.sort(key=lambda x: x['id'])

output_file = sys.argv[1]
result = {'apps': apps}
with open(output_file, 'w') as f:
    json.dump(result, f, indent=2)

# Stats
total = len(apps)
deployed = sum(1 for a in apps if a['status'] == 'deployed')
failed = sum(1 for a in apps if 'failed' in a['status'])
other = total - deployed - failed
print(f'Rebuilt registry: {total} apps ({deployed} deployed, {failed} failed, {other} other)')
" "$OUTPUT"

log "Registry written to $OUTPUT"
log "$(wc -l < "$OUTPUT") lines, $(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT" 2>/dev/null) bytes"
