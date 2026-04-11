#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# generate-manifest.sh — Generate a pipeline manifest JSON from a definition file
#
# Creates the structured manifest JSON that generate-crds.sh and workers consume.
# Two modes:
#   1. From definition file (YAML/text with app ideas) — fills in structure
#   2. From inline args — quick single-pipeline scaffold
#
# Usage:
#   # From a definition file (apps listed one per line or as YAML)
#   ./generate-manifest.sh --from-def apps.def --pipeline fintech \
#       --start-id 60001 --output pipeline/manifests/fintech-payments.json
#
#   # Scaffold N empty app slots for manual editing
#   ./generate-manifest.sh --scaffold 20 --pipeline fintech \
#       --start-id 60001 --category "FinTech Payments" \
#       --output pipeline/manifests/fintech-payments.json
#
#   # Show next available ID range
#   ./generate-manifest.sh --next-id
#
# Definition file format (.def):
#   Each app is defined by a block separated by blank lines:
#     name: ThreadVault Streetwear
#     prefix: TVS
#     type: Streetwear E-Commerce
#     category: E-Commerce Apparel
#     description: Limited-drop streetwear marketplace...
#     features: product drops, raffle system, resale tracking
#     design_bg: #0A0A0A
#     design_primary: #FF4500
#     design_vibe: Dark hype-beast streetwear
#     budget: 700
#
# If prefix is omitted, auto-generated from name initials.
# If repo is omitted, derived from name (lowercase, hyphenated).
# If email is omitted, derived from repo.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_MANIFESTS="$SCRIPT_DIR/../manifests"

FROM_DEF=""
SCAFFOLD=0
PIPELINE=""
START_ID=0
CATEGORY="Misc"
OUTPUT=""
SHOW_NEXT_ID=false

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-def)   FROM_DEF="$2"; shift 2 ;;
    --scaffold)   SCAFFOLD="$2"; shift 2 ;;
    --pipeline)   PIPELINE="$2"; shift 2 ;;
    --start-id)   START_ID="$2"; shift 2 ;;
    --category)   CATEGORY="$2"; shift 2 ;;
    --output|-o)  OUTPUT="$2"; shift 2 ;;
    --next-id)    SHOW_NEXT_ID=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# --- Show next available ID range ---
if [[ "$SHOW_NEXT_ID" == "true" ]]; then
  echo "Current ID ranges:"
  kubectl get pb -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json,sys
from collections import defaultdict
items = json.load(sys.stdin)['items']
ranges = defaultdict(list)
for i in items:
    ranges[i['spec']['pipeline']].append(i['spec']['appId'])
max_id = 0
for p, ids in sorted(ranges.items()):
    mx = max(ids)
    if mx > max_id: max_id = mx
    print(f'  {p:8s}: {min(ids):6d} - {mx:6d}  ({len(ids)} apps)')
# Suggest next range (round up to next 100)
next_start = ((max_id // 100) + 1) * 100 + 1
print(f'')
print(f'  Highest ID: {max_id}')
print(f'  Next available range: --start-id {next_start}')
" 2>/dev/null
  exit 0
fi

[[ -z "$PIPELINE" ]] && { err "--pipeline required"; exit 1; }
[[ -z "$OUTPUT" ]] && OUTPUT="$WORKSPACE_MANIFESTS/${PIPELINE}.json"

# --- Scaffold mode: generate N placeholder entries ---
if [[ "$SCAFFOLD" -gt 0 ]]; then
  [[ "$START_ID" -eq 0 ]] && { err "--start-id required for scaffold mode"; exit 1; }

  log "Scaffolding $SCAFFOLD app entries for pipeline '$PIPELINE'..."

  python3 -c "
import json

apps = []
for i in range($SCAFFOLD):
    app_id = $START_ID + i
    apps.append({
        'id': app_id,
        'name': f'App{app_id} Name',
        'prefix': f'A{app_id}',
        'repo': f'app{app_id}-name',
        'category': '$CATEGORY',
        'description': 'TODO: Add description',
        'features': ['feature1', 'feature2', 'feature3'],
        'design': {'bg': '#FFFFFF', 'primary': '#3B82F6', 'vibe': 'Professional and modern'},
        'type': '$CATEGORY',
        'budget': 500,
        'email': f'ops@app{app_id}.com'
    })

with open('$OUTPUT', 'w') as f:
    json.dump({'apps': apps}, f, indent=2)
print(f'Wrote {len(apps)} scaffold entries to $OUTPUT')
print(f'Edit the file to fill in real app names, descriptions, and features.')
"
  ok "Scaffold written to $OUTPUT"
  exit 0
fi

# --- Definition file mode ---
if [[ -n "$FROM_DEF" ]]; then
  [[ ! -f "$FROM_DEF" ]] && { err "Definition file not found: $FROM_DEF"; exit 1; }
  [[ "$START_ID" -eq 0 ]] && { err "--start-id required"; exit 1; }

  log "Generating manifest from $FROM_DEF for pipeline '$PIPELINE'..."

  python3 -c "
import json, re, sys

def parse_def_file(path):
    apps = []
    current = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip()
            if not line.strip():
                if current:
                    apps.append(current)
                    current = {}
                continue
            if line.strip().startswith('#'):
                continue
            m = re.match(r'^\s*(\w+)\s*:\s*(.+)$', line)
            if m:
                current[m.group(1).strip()] = m.group(2).strip()
        if current:
            apps.append(current)
    return apps

def name_to_prefix(name):
    words = re.sub(r'[^a-zA-Z\s]', '', name).split()
    if len(words) >= 3:
        return ''.join(w[0] for w in words[:3]).upper()
    elif len(words) == 2:
        return (words[0][0] + words[1][:2]).upper()
    else:
        return name[:3].upper()

def name_to_repo(name):
    return re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')

raw_apps = parse_def_file('$FROM_DEF')
apps = []
for i, raw in enumerate(raw_apps):
    app_id = $START_ID + i
    name = raw.get('name', f'App{app_id}')
    prefix = raw.get('prefix', name_to_prefix(name))
    repo = raw.get('repo', name_to_repo(name))
    features = [f.strip() for f in raw.get('features', '').split(',') if f.strip()]
    if not features:
        features = ['dashboard', 'analytics', 'user management']
    apps.append({
        'id': app_id,
        'name': name,
        'prefix': prefix,
        'repo': repo,
        'category': raw.get('category', '$CATEGORY'),
        'description': raw.get('description', f'{name} — a $CATEGORY application'),
        'features': features,
        'design': {
            'bg': raw.get('design_bg', '#FFFFFF'),
            'primary': raw.get('design_primary', '#3B82F6'),
            'vibe': raw.get('design_vibe', 'Professional and modern')
        },
        'type': raw.get('type', '$CATEGORY'),
        'budget': int(raw.get('budget', 500)),
        'email': raw.get('email', f'ops@{repo}.com')
    })
with open('$OUTPUT', 'w') as f:
    json.dump({'apps': apps}, f, indent=2)
print(f'Generated {len(apps)} apps (IDs {$START_ID}-{$START_ID + len(apps) - 1})')
for a in apps:
    print(f'  [{a[\"id\"]}] {a[\"prefix\"]} — {a[\"name\"]} ({a[\"category\"]})')
"
  ok "Manifest written to $OUTPUT"
  log ""
  log "Next steps:"
  log "  1. Review: cat $OUTPUT | python3 -m json.tool | head -30"
  log "  2. Generate CRDs: ./generate-crds.sh --manifest $OUTPUT --pipeline $PIPELINE"
  log "  3. Start worker:  ./workers-start.sh --pipeline $PIPELINE --concurrency 1"
  exit 0
fi

err "Specify --from-def <file>, --scaffold <N>, or --next-id"
exit 1
