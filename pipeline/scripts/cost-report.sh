#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# cost-report.sh — ADLC cost tracking and attribution
#
# Aggregates cost data from multiple sources:
#   1. JSONL history files (token counts per message)
#   2. AgentIntake CRD status (buildCostUsd field)
#   3. Worker logs (cost summaries)
#
# Usage:
#   bash cost-report.sh                    # Default summary
#   bash cost-report.sh --summary          # Quick one-liner
#   bash cost-report.sh --by-pipeline      # Breakdown per pipeline
#   bash cost-report.sh --by-model         # Breakdown per model
#   bash cost-report.sh --by-date          # Daily cost chart
#   bash cost-report.sh --top 10           # Top 10 most expensive apps
#   bash cost-report.sh --pipeline tech    # Filter to one pipeline
#   bash cost-report.sh --date 2026-05-01  # Specific date
#   bash cost-report.sh --range 7d         # Last 7 days
#   bash cost-report.sh --export csv       # Export as CSV
#   bash cost-report.sh --json             # JSON output
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pipeline-registry.sh"

WORKSPACE="/tmp/pc-autopilot"
WORKER_DIR="$WORKSPACE/.workers"
INTAKE_NS="agent-intake"
PB_NS="paperclip-v3"

# SDK working directories where JSONL history files live
SDK_INTAKE_DIR="/var/lib/rancher/ansible/db/sdk-agent-intake"
SDK_BUILDER_DIR="/var/lib/rancher/ansible/db/sdk-agentic-custom-builder-intake"

# --- Defaults ---
MODE="summary"
PIPELINE_FILTER=""
DATE_FILTER=""
RANGE_FILTER="all"
TOP_N=10
EXPORT_FMT=""
JSON_OUT=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary)       MODE="summary"; shift ;;
    --by-pipeline)   MODE="by-pipeline"; shift ;;
    --by-model)      MODE="by-model"; shift ;;
    --by-date)       MODE="by-date"; shift ;;
    --top)           MODE="top"; TOP_N="${2:-10}"; shift 2 ;;
    --pipeline|-p)   PIPELINE_FILTER="$2"; shift 2 ;;
    --date|-d)       DATE_FILTER="$2"; shift 2 ;;
    --range|-r)      RANGE_FILTER="$2"; shift 2 ;;
    --export|-e)     EXPORT_FMT="$2"; shift 2 ;;
    --json|-j)       JSON_OUT=true; shift ;;
    --help|-h)
      echo "Usage: cost-report.sh [--summary|--by-pipeline|--by-model|--by-date|--top N]"
      echo "       [--pipeline NAME] [--date YYYY-MM-DD] [--range 7d|30d|all]"
      echo "       [--export csv] [--json]"
      exit 0 ;;
    *) shift ;;
  esac
done

# --- Colors ---
if [[ "$JSON_OUT" == "true" ]] || [[ -n "$EXPORT_FMT" ]] || [[ ! -t 1 ]]; then
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" MAGENTA="" RESET=""
else
  BOLD="\033[1m" DIM="\033[2m" RED="\033[31m" GREEN="\033[32m"
  YELLOW="\033[33m" CYAN="\033[36m" MAGENTA="\033[35m" RESET="\033[0m"
fi

WIDTH=62

repeat_char() { printf "%0.s$1" $(seq 1 "$2"); }

box_top() { printf "${BOLD}${CYAN}$(repeat_char '=' $WIDTH)${RESET}\n"; }
box_sep() { printf "${DIM}$(repeat_char '-' $WIDTH)${RESET}\n"; }
box_bot() { printf "${BOLD}${CYAN}$(repeat_char '=' $WIDTH)${RESET}\n"; }

# ============================================================================
# Data Collection — single Python3 script that scans all sources
# ============================================================================

collect_all_cost_data() {
  python3 << 'PYEOF'
import json, glob, os, sys, re
from datetime import datetime, timedelta

# Token pricing per million tokens
PRICING = {
    'claude-sonnet-4-5':   {'input': 3.00,  'output': 15.00},
    'claude-4-5-sonnet':   {'input': 3.00,  'output': 15.00},
    'claude-sonnet-4-6':   {'input': 3.00,  'output': 15.00},
    'claude-4-6-sonnet':   {'input': 3.00,  'output': 15.00},
    'claude-opus-4':       {'input': 15.00, 'output': 75.00},
    'claude-4-opus':       {'input': 15.00, 'output': 75.00},
    'claude-opus-4-6':     {'input': 15.00, 'output': 75.00},
    'claude-haiku-3-5':    {'input': 0.80,  'output': 4.00},
    'claude-3-5-haiku':    {'input': 0.80,  'output': 4.00},
    # Fallback for unknown models
    'default':             {'input': 3.00,  'output': 15.00},
}

def get_pricing(model_name):
    """Match model name to pricing, using fuzzy matching."""
    if not model_name:
        return PRICING['default']
    mn = model_name.lower()
    for key, val in PRICING.items():
        if key == 'default':
            continue
        if key in mn or key.replace('-', '') in mn.replace('-', ''):
            return val
    # Heuristic: opus costs more
    if 'opus' in mn:
        return PRICING['claude-opus-4']
    if 'haiku' in mn:
        return PRICING['claude-haiku-3-5']
    return PRICING['default']

def calc_cost(model, input_tokens, output_tokens):
    """Calculate cost in USD."""
    p = get_pricing(model)
    return (input_tokens * p['input'] + output_tokens * p['output']) / 1_000_000

def parse_date_from_path(path):
    """Try to extract date from filename or file mtime."""
    # Try patterns like 2026-05-04 or 20260504
    m = re.search(r'(\d{4})-?(\d{2})-?(\d{2})', os.path.basename(path))
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime('%Y-%m-%d')
        except:
            pass
    # Fall back to file modification time
    try:
        mtime = os.path.getmtime(path)
        return datetime.fromtimestamp(mtime).strftime('%Y-%m-%d')
    except:
        return datetime.now().strftime('%Y-%m-%d')

# Collect all cost records
records = []

# Source 1: JSONL history files
jsonl_dirs = [
    os.environ.get('SDK_INTAKE_DIR', '/var/lib/rancher/ansible/db/sdk-agent-intake'),
    os.environ.get('SDK_BUILDER_DIR', '/var/lib/rancher/ansible/db/sdk-agentic-custom-builder-intake'),
    os.environ.get('WORKSPACE', '/tmp/pc-autopilot'),
]

for base_dir in jsonl_dirs:
    for pattern in ['**/.intake-history-*.jsonl', '**/.builder-history-*.jsonl',
                    '.intake-history-*.jsonl', '.builder-history-*.jsonl',
                    '**/*-history-*.jsonl', '*-history-*.jsonl']:
        for fpath in glob.glob(os.path.join(base_dir, pattern), recursive=True):
            try:
                date = parse_date_from_path(fpath)
                source_type = 'intake' if 'intake' in fpath else 'builder'
                session_model = ''
                session_input = 0
                session_output = 0
                app_name = ''
                pipeline = ''

                with open(fpath) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            entry = json.loads(line)
                        except json.JSONDecodeError:
                            continue

                        # Extract token usage
                        model = entry.get('model', '') or session_model
                        if model:
                            session_model = model

                        # Various JSONL schemas
                        inp = (entry.get('input_tokens', 0) or
                               entry.get('usage', {}).get('input_tokens', 0) or
                               entry.get('tokens', {}).get('input', 0) or 0)
                        out = (entry.get('output_tokens', 0) or
                               entry.get('usage', {}).get('output_tokens', 0) or
                               entry.get('tokens', {}).get('output', 0) or 0)
                        session_input += inp
                        session_output += out

                        # App/pipeline metadata
                        if not app_name:
                            app_name = (entry.get('appName', '') or
                                        entry.get('app_name', '') or
                                        entry.get('app', '') or '')
                        if not pipeline:
                            pipeline = (entry.get('pipeline', '') or
                                        entry.get('pipeline_id', '') or '')

                if session_input > 0 or session_output > 0:
                    cost = calc_cost(session_model, session_input, session_output)
                    records.append({
                        'source': 'jsonl',
                        'source_type': source_type,
                        'file': fpath,
                        'date': date,
                        'app': app_name or os.path.basename(fpath),
                        'pipeline': pipeline,
                        'model': session_model or 'unknown',
                        'input_tokens': session_input,
                        'output_tokens': session_output,
                        'cost': cost,
                    })
            except Exception as e:
                pass

# Source 2: Worker logs — extract cost summaries
worker_dir = os.environ.get('WORKER_DIR', '/tmp/pc-autopilot/.workers')
for logf in glob.glob(os.path.join(worker_dir, '*.log')):
    pipeline = os.path.basename(logf).replace('.log', '')
    try:
        date = parse_date_from_path(logf)
        with open(logf) as f:
            for line in f:
                # Look for cost lines like: [APP] cost=$X.XX
                m = re.search(r'\[(\w+)\].*cost=\$?([\d.]+)', line)
                if m:
                    app_prefix = m.group(1)
                    cost = float(m.group(2))
                    records.append({
                        'source': 'worker_log',
                        'source_type': 'worker',
                        'file': logf,
                        'date': date,
                        'app': app_prefix,
                        'pipeline': pipeline,
                        'model': 'unknown',
                        'input_tokens': 0,
                        'output_tokens': 0,
                        'cost': cost,
                    })
    except:
        pass

# Source 3: AgentIntake CRDs (if available)
try:
    import subprocess
    r = subprocess.run(
        ['kubectl', 'get', 'agentintakes', '-n', 'agent-intake', '-o', 'json'],
        capture_output=True, text=True, timeout=10
    )
    if r.returncode == 0:
        data = json.loads(r.stdout)
        for item in data.get('items', []):
            status = item.get('status', {})
            spec = item.get('spec', {})
            cost = status.get('buildCostUsd', 0)
            if cost:
                app = spec.get('appName', item.get('metadata', {}).get('name', ''))
                pipeline = spec.get('pipeline', '')
                date_str = status.get('completedAt', '') or item.get('metadata', {}).get('creationTimestamp', '')
                if date_str:
                    date_str = date_str[:10]
                else:
                    date_str = datetime.now().strftime('%Y-%m-%d')
                records.append({
                    'source': 'crd',
                    'source_type': 'agentintake',
                    'file': '',
                    'date': date_str,
                    'app': app,
                    'pipeline': pipeline,
                    'model': status.get('model', 'unknown'),
                    'input_tokens': int(status.get('inputTokens', 0)),
                    'output_tokens': int(status.get('outputTokens', 0)),
                    'cost': float(cost),
                })
except:
    pass

# Apply filters
pipeline_filter = os.environ.get('PIPELINE_FILTER', '')
date_filter = os.environ.get('DATE_FILTER', '')
range_filter = os.environ.get('RANGE_FILTER', 'all')

if pipeline_filter:
    records = [r for r in records if r['pipeline'] == pipeline_filter]

if date_filter:
    records = [r for r in records if r['date'] == date_filter]
elif range_filter != 'all':
    days = int(re.search(r'(\d+)', range_filter).group(1)) if re.search(r'(\d+)', range_filter) else 30
    cutoff = (datetime.now() - timedelta(days=days)).strftime('%Y-%m-%d')
    records = [r for r in records if r['date'] >= cutoff]

# Deduplicate: prefer CRD > JSONL > worker_log for same app
seen_apps = {}
deduped = []
for r in sorted(records, key=lambda x: {'crd': 0, 'jsonl': 1, 'worker_log': 2}.get(x['source'], 3)):
    key = (r['app'], r['date'])
    if key not in seen_apps:
        seen_apps[key] = True
        deduped.append(r)

print(json.dumps(deduped))
PYEOF
}

# ============================================================================
# Render functions
# ============================================================================

render_summary() {
  local data="$1"

  if [[ "$JSON_OUT" == "true" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
total_cost = sum(r['cost'] for r in records)
total_apps = len(set(r['app'] for r in records))
total_sessions = len(records)
avg = total_cost / total_apps if total_apps > 0 else 0
from datetime import datetime
today = datetime.now().strftime('%Y-%m-%d')
today_cost = sum(r['cost'] for r in records if r['date'] == today)
print(json.dumps({
    'total_cost': round(total_cost, 2),
    'total_apps': total_apps,
    'total_sessions': total_sessions,
    'avg_per_app': round(avg, 2),
    'today_cost': round(today_cost, 2)
}, indent=2))
"
    return
  fi

  echo "$data" | python3 -c "
import json, sys
from datetime import datetime
records = json.load(sys.stdin)
total_cost = sum(r['cost'] for r in records)
total_apps = len(set(r['app'] for r in records))
total_sessions = len(records)
avg = total_cost / total_apps if total_apps > 0 else 0
today = datetime.now().strftime('%Y-%m-%d')
today_cost = sum(r['cost'] for r in records if r['date'] == today)
print(f'ADLC Cost: \${total_cost:.2f} total | {total_apps} apps | {total_sessions} sessions | \${avg:.2f}/app avg | \${today_cost:.2f} today')
"
}

render_by_pipeline() {
  local data="$1"

  if [[ "$EXPORT_FMT" == "csv" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
pipelines = {}
for r in records:
    p = r['pipeline'] or 'unknown'
    if p not in pipelines:
        pipelines[p] = {'apps': set(), 'sessions': 0, 'cost': 0}
    pipelines[p]['apps'].add(r['app'])
    pipelines[p]['sessions'] += 1
    pipelines[p]['cost'] += r['cost']
print('pipeline,apps,sessions,cost,avg_per_app')
for p in sorted(pipelines, key=lambda x: -pipelines[x]['cost']):
    d = pipelines[p]
    apps = len(d['apps'])
    avg = d['cost'] / apps if apps > 0 else 0
    print(f'{p},{apps},{d[\"sessions\"]},{d[\"cost\"]:.2f},{avg:.2f}')
total_apps = len(set(r['app'] for r in records))
total_sessions = len(records)
total_cost = sum(r['cost'] for r in records)
avg = total_cost / total_apps if total_apps > 0 else 0
print(f'TOTAL,{total_apps},{total_sessions},{total_cost:.2f},{avg:.2f}')
"
    return
  fi

  if [[ "$JSON_OUT" == "true" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
pipelines = {}
for r in records:
    p = r['pipeline'] or 'unknown'
    if p not in pipelines:
        pipelines[p] = {'apps': set(), 'sessions': 0, 'cost': 0}
    pipelines[p]['apps'].add(r['app'])
    pipelines[p]['sessions'] += 1
    pipelines[p]['cost'] += r['cost']
out = {}
for p, d in pipelines.items():
    apps = len(d['apps'])
    out[p] = {'apps': apps, 'sessions': d['sessions'], 'cost': round(d['cost'], 2), 'avg_per_app': round(d['cost']/apps, 2) if apps else 0}
print(json.dumps(out, indent=2))
"
    return
  fi

  local range_label="All time"
  [[ "$RANGE_FILTER" != "all" ]] && range_label="Last $RANGE_FILTER"
  [[ -n "$DATE_FILTER" ]] && range_label="$DATE_FILTER"

  box_top
  printf "${BOLD}${CYAN}  ADLC Cost Report — %s${RESET}\n" "$range_label"
  box_top
  echo ""

  echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
if not records:
    print('  No cost data found.')
    sys.exit(0)

pipelines = {}
for r in records:
    p = r['pipeline'] or 'unknown'
    if p not in pipelines:
        pipelines[p] = {'apps': set(), 'sessions': 0, 'cost': 0}
    pipelines[p]['apps'].add(r['app'])
    pipelines[p]['sessions'] += 1
    pipelines[p]['cost'] += r['cost']

# Header
print(f'  {\"Pipeline\":<14} | {\"Apps\":>5} | {\"Sessions\":>8} | {\"Cost\":>8} | {\"Avg/App\":>8}')
print(f'  {\"-\"*14}-+-{\"-\"*5}-+-{\"-\"*8}-+-{\"-\"*8}-+-{\"-\"*8}')

for p in sorted(pipelines, key=lambda x: -pipelines[x]['cost']):
    d = pipelines[p]
    apps = len(d['apps'])
    avg = d['cost'] / apps if apps > 0 else 0
    print(f'  {p:<14} | {apps:>5} | {d[\"sessions\"]:>8} | \${d[\"cost\"]:>7.2f} | \${avg:>7.2f}')

# Total
total_apps = len(set(r['app'] for r in records))
total_sessions = len(records)
total_cost = sum(r['cost'] for r in records)
avg = total_cost / total_apps if total_apps > 0 else 0
print(f'  {\"-\"*14}-+-{\"-\"*5}-+-{\"-\"*8}-+-{\"-\"*8}-+-{\"-\"*8}')
print(f'  {\"TOTAL\":<14} | {total_apps:>5} | {total_sessions:>8} | \${total_cost:>7.2f} | \${avg:>7.2f}')
"
  echo ""
  box_bot
}

render_by_model() {
  local data="$1"

  if [[ "$EXPORT_FMT" == "csv" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
models = {}
for r in records:
    m = r['model'] or 'unknown'
    if m not in models:
        models[m] = {'sessions': 0, 'cost': 0, 'input_tokens': 0, 'output_tokens': 0}
    models[m]['sessions'] += 1
    models[m]['cost'] += r['cost']
    models[m]['input_tokens'] += r['input_tokens']
    models[m]['output_tokens'] += r['output_tokens']
print('model,sessions,input_tokens,output_tokens,cost')
for m in sorted(models, key=lambda x: -models[x]['cost']):
    d = models[m]
    print(f'{m},{d[\"sessions\"]},{d[\"input_tokens\"]},{d[\"output_tokens\"]},{d[\"cost\"]:.2f}')
"
    return
  fi

  if [[ "$JSON_OUT" == "true" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
models = {}
for r in records:
    m = r['model'] or 'unknown'
    if m not in models:
        models[m] = {'sessions': 0, 'cost': 0, 'input_tokens': 0, 'output_tokens': 0}
    models[m]['sessions'] += 1
    models[m]['cost'] += r['cost']
    models[m]['input_tokens'] += r['input_tokens']
    models[m]['output_tokens'] += r['output_tokens']
out = {}
for m, d in models.items():
    out[m] = {'sessions': d['sessions'], 'cost': round(d['cost'], 2), 'input_tokens': d['input_tokens'], 'output_tokens': d['output_tokens']}
print(json.dumps(out, indent=2))
"
    return
  fi

  local range_label="All time"
  [[ "$RANGE_FILTER" != "all" ]] && range_label="Last $RANGE_FILTER"
  [[ -n "$DATE_FILTER" ]] && range_label="$DATE_FILTER"

  box_top
  printf "${BOLD}${CYAN}  ADLC Cost by Model — %s${RESET}\n" "$range_label"
  box_top
  echo ""

  echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
if not records:
    print('  No cost data found.')
    sys.exit(0)

models = {}
for r in records:
    m = r['model'] or 'unknown'
    if m not in models:
        models[m] = {'sessions': 0, 'cost': 0, 'input_tokens': 0, 'output_tokens': 0}
    models[m]['sessions'] += 1
    models[m]['cost'] += r['cost']
    models[m]['input_tokens'] += r['input_tokens']
    models[m]['output_tokens'] += r['output_tokens']

def fmt_tokens(n):
    if n >= 1_000_000: return f'{n/1_000_000:.1f}M'
    if n >= 1_000: return f'{n/1_000:.1f}K'
    return str(n)

print(f'  {\"Model\":<22} | {\"Sess\":>5} | {\"In Tok\":>8} | {\"Out Tok\":>8} | {\"Cost\":>8}')
print(f'  {\"-\"*22}-+-{\"-\"*5}-+-{\"-\"*8}-+-{\"-\"*8}-+-{\"-\"*8}')
for m in sorted(models, key=lambda x: -models[x]['cost']):
    d = models[m]
    print(f'  {m:<22} | {d[\"sessions\"]:>5} | {fmt_tokens(d[\"input_tokens\"]):>8} | {fmt_tokens(d[\"output_tokens\"]):>8} | \${d[\"cost\"]:>7.2f}')

total_cost = sum(r['cost'] for r in records)
print(f'  {\"-\"*22}-+-{\"-\"*5}-+-{\"-\"*8}-+-{\"-\"*8}-+-{\"-\"*8}')
print(f'  {\"TOTAL\":<22} | {len(records):>5} | {fmt_tokens(sum(r[\"input_tokens\"] for r in records)):>8} | {fmt_tokens(sum(r[\"output_tokens\"] for r in records)):>8} | \${total_cost:>7.2f}')
"
  echo ""
  box_bot
}

render_by_date() {
  local data="$1"

  if [[ "$EXPORT_FMT" == "csv" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
dates = {}
for r in records:
    d = r['date']
    if d not in dates:
        dates[d] = {'sessions': 0, 'cost': 0, 'apps': set()}
    dates[d]['sessions'] += 1
    dates[d]['cost'] += r['cost']
    dates[d]['apps'].add(r['app'])
print('date,apps,sessions,cost')
for d in sorted(dates):
    dd = dates[d]
    print(f'{d},{len(dd[\"apps\"])},{dd[\"sessions\"]},{dd[\"cost\"]:.2f}')
"
    return
  fi

  if [[ "$JSON_OUT" == "true" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
dates = {}
for r in records:
    d = r['date']
    if d not in dates:
        dates[d] = {'sessions': 0, 'cost': 0, 'apps': set()}
    dates[d]['sessions'] += 1
    dates[d]['cost'] += r['cost']
    dates[d]['apps'].add(r['app'])
out = {}
for d in sorted(dates):
    dd = dates[d]
    out[d] = {'apps': len(dd['apps']), 'sessions': dd['sessions'], 'cost': round(dd['cost'], 2)}
print(json.dumps(out, indent=2))
"
    return
  fi

  box_top
  printf "${BOLD}${CYAN}  ADLC Cost by Date${RESET}\n"
  box_top
  echo ""

  echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
if not records:
    print('  No cost data found.')
    sys.exit(0)

dates = {}
for r in records:
    d = r['date']
    if d not in dates:
        dates[d] = {'sessions': 0, 'cost': 0, 'apps': set()}
    dates[d]['sessions'] += 1
    dates[d]['cost'] += r['cost']
    dates[d]['apps'].add(r['app'])

max_cost = max(d['cost'] for d in dates.values()) if dates else 1
bar_width = 30

print(f'  {\"Date\":<12} | {\"Apps\":>5} | {\"Sess\":>5} | {\"Cost\":>8} | Chart')
print(f'  {\"-\"*12}-+-{\"-\"*5}-+-{\"-\"*5}-+-{\"-\"*8}-+' + '-' * (bar_width + 2))
for d in sorted(dates):
    dd = dates[d]
    bar_len = max(1, int(dd['cost'] / max_cost * bar_width)) if max_cost > 0 else 0
    bar = chr(9608) * bar_len
    print(f'  {d:<12} | {len(dd[\"apps\"]):>5} | {dd[\"sessions\"]:>5} | \${dd[\"cost\"]:>7.2f} | {bar}')

total_cost = sum(r['cost'] for r in records)
total_apps = len(set(r['app'] for r in records))
print(f'  {\"-\"*12}-+-{\"-\"*5}-+-{\"-\"*5}-+-{\"-\"*8}-+' + '-' * (bar_width + 2))
print(f'  {\"TOTAL\":<12} | {total_apps:>5} | {len(records):>5} | \${total_cost:>7.2f} |')
"
  echo ""
  box_bot
}

render_top() {
  local data="$1"
  local n="$TOP_N"

  if [[ "$EXPORT_FMT" == "csv" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
apps = {}
for r in records:
    a = r['app']
    if a not in apps:
        apps[a] = {'pipeline': r['pipeline'], 'cost': 0, 'sessions': 0, 'model': r['model']}
    apps[a]['cost'] += r['cost']
    apps[a]['sessions'] += 1
print('rank,app,pipeline,sessions,cost,model')
for i, (a, d) in enumerate(sorted(apps.items(), key=lambda x: -x[1]['cost'])[:$n], 1):
    print(f'{i},{a},{d[\"pipeline\"]},{d[\"sessions\"]},{d[\"cost\"]:.2f},{d[\"model\"]}')
"
    return
  fi

  if [[ "$JSON_OUT" == "true" ]]; then
    echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
apps = {}
for r in records:
    a = r['app']
    if a not in apps:
        apps[a] = {'pipeline': r['pipeline'], 'cost': 0, 'sessions': 0, 'model': r['model']}
    apps[a]['cost'] += r['cost']
    apps[a]['sessions'] += 1
out = []
for a, d in sorted(apps.items(), key=lambda x: -x[1]['cost'])[:$n]:
    out.append({'app': a, 'pipeline': d['pipeline'], 'sessions': d['sessions'], 'cost': round(d['cost'], 2), 'model': d['model']})
print(json.dumps(out, indent=2))
"
    return
  fi

  box_top
  printf "${BOLD}${CYAN}  ADLC Top %d Most Expensive Apps${RESET}\n" "$n"
  box_top
  echo ""

  echo "$data" | python3 -c "
import json, sys
records = json.load(sys.stdin)
if not records:
    print('  No cost data found.')
    sys.exit(0)

apps = {}
for r in records:
    a = r['app']
    if a not in apps:
        apps[a] = {'pipeline': r['pipeline'], 'cost': 0, 'sessions': 0, 'model': r['model']}
    apps[a]['cost'] += r['cost']
    apps[a]['sessions'] += 1

print(f'  {\"#\":>3} {\"App\":<24} | {\"Pipeline\":<12} | {\"Sess\":>5} | {\"Cost\":>8}')
print(f'  {\"\":<3} {\"-\"*24}-+-{\"-\"*12}-+-{\"-\"*5}-+-{\"-\"*8}')
for i, (a, d) in enumerate(sorted(apps.items(), key=lambda x: -x[1]['cost'])[:$TOP_N], 1):
    name = a[:24]
    print(f'  {i:>3} {name:<24} | {d[\"pipeline\"]:<12} | {d[\"sessions\"]:>5} | \${d[\"cost\"]:>7.2f}')

total_cost = sum(r['cost'] for r in records)
print(f'')
print(f'  Total across all apps: \${total_cost:.2f}')
"
  echo ""
  box_bot
}

# ============================================================================
# Main
# ============================================================================

# Export filter vars for the Python script
export PIPELINE_FILTER DATE_FILTER RANGE_FILTER
export SDK_INTAKE_DIR SDK_BUILDER_DIR WORKSPACE WORKER_DIR TOP_N

# Collect all data once
cost_data=$(collect_all_cost_data)

case "$MODE" in
  summary)     render_summary "$cost_data" ;;
  by-pipeline) render_by_pipeline "$cost_data" ;;
  by-model)    render_by_model "$cost_data" ;;
  by-date)     render_by_date "$cost_data" ;;
  top)         render_top "$cost_data" ;;
  *)
    echo "Unknown mode: $MODE"
    echo "Use --help for usage"
    exit 1 ;;
esac
