#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# intake-hud.sh — Real-time AgentIntake HUD (ADLC Phase 6)
#
# Terminal-based heads-up display showing:
#   1. AgentIntake CRD phase summary
#   2. PaperclipBuild CRD summary
#   3. Active sessions with progress + cost
#   4. Recent phase transitions
#   5. Cost summary
#   6. Host resource usage (CPU, memory, disk)
#   7. Active Claude processes with CPU/mem
#
# Usage:
#   bash intake-hud.sh                          # one-shot
#   bash intake-hud.sh --watch                  # auto-refresh
#   bash intake-hud.sh --watch --interval 10    # custom interval
#   bash intake-hud.sh --pipeline invest-bots   # filter by pipeline
#   bash intake-hud.sh --json                   # JSON output
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pipeline-registry.sh"

WORKSPACE="/tmp/pc-autopilot"
WORKER_DIR="$WORKSPACE/.workers"
INTAKE_NS="agent-intake"
PB_NS="paperclip-v3"

# --- Defaults ---
WATCH=false
INTERVAL=5
PIPELINE_FILTER=""
JSON_OUT=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch|-w)     WATCH=true; shift ;;
    --interval|-i)  INTERVAL="$2"; shift 2 ;;
    --pipeline|-p)  PIPELINE_FILTER="$2"; shift 2 ;;
    --json|-j)      JSON_OUT=true; shift ;;
    --help|-h)
      echo "Usage: intake-hud.sh [--watch] [--interval N] [--pipeline NAME] [--json]"
      exit 0 ;;
    *) shift ;;
  esac
done

# --- Colors (disabled for JSON/pipe) ---
if [[ "$JSON_OUT" == "true" ]] || [[ ! -t 1 ]]; then
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" MAGENTA="" WHITE="" RESET=""
  BOX_TL="+" BOX_TR="+" BOX_BL="+" BOX_BR="+" BOX_H="-" BOX_V="|" BOX_ML="+" BOX_MR="+"
  BOX_TJ="+" BOX_BJ="+" BOX_CROSS="+"
else
  BOLD="\033[1m" DIM="\033[2m" RED="\033[31m" GREEN="\033[32m"
  YELLOW="\033[33m" CYAN="\033[36m" MAGENTA="\033[35m" WHITE="\033[37m" RESET="\033[0m"
  BOX_TL="╔" BOX_TR="╗" BOX_BL="╚" BOX_BR="╝" BOX_H="═" BOX_V="║" BOX_ML="╠" BOX_MR="╣"
  BOX_TJ="╦" BOX_BJ="╩" BOX_CROSS="╬"
fi

WIDTH=70

# --- Helper: repeat char ---
repeat_char() { printf "%0.s$1" $(seq 1 "$2"); }

# --- Helper: box top ---
box_top() {
  printf "${BOLD}${CYAN}${BOX_TL}$(repeat_char "$BOX_H" $((WIDTH-2)))${BOX_TR}${RESET}\n"
}
box_mid() {
  printf "${BOLD}${CYAN}${BOX_ML}$(repeat_char "$BOX_H" $((WIDTH-2)))${BOX_MR}${RESET}\n"
}
box_bot() {
  printf "${BOLD}${CYAN}${BOX_BL}$(repeat_char "$BOX_H" $((WIDTH-2)))${BOX_BR}${RESET}\n"
}
box_line() {
  local text="$1"
  # Strip ANSI for length calculation
  local plain
  plain=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
  local pad=$((WIDTH - 4 - ${#plain}))
  [[ "$pad" -lt 0 ]] && pad=0
  printf "${BOLD}${CYAN}${BOX_V}${RESET}  %b%*s${BOLD}${CYAN}${BOX_V}${RESET}\n" "$text" "$pad" ""
}
box_empty() {
  printf "${BOLD}${CYAN}${BOX_V}${RESET}%*s${BOLD}${CYAN}${BOX_V}${RESET}\n" "$((WIDTH-2))" ""
}

# ============================================================================
# Data Collection
# ============================================================================

collect_agentintake_data() {
  # Check if AgentIntake CRD exists
  if ! kubectl get crd agentintakes.paperclip.istayintek.com >/dev/null 2>&1; then
    echo '{"exists":false,"items":[]}'
    return
  fi

  local filter_args=""
  if [[ -n "$PIPELINE_FILTER" ]]; then
    filter_args="-l pipeline=$PIPELINE_FILTER"
  fi

  kubectl get agentintakes -n "$INTAKE_NS" $filter_args -o json 2>/dev/null || echo '{"items":[]}'
}

collect_paperclipbuild_data() {
  local raw
  raw=$(kubectl get paperclipbuild -n "$PB_NS" -o json 2>/dev/null || echo '{"items":[]}')

  # Filter client-side by spec.pipeline if filter is set
  if [[ -n "$PIPELINE_FILTER" ]]; then
    echo "$raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['items'] = [i for i in data.get('items', []) if i.get('spec', {}).get('pipeline', '') == '$PIPELINE_FILTER']
print(json.dumps(data))
" 2>/dev/null
  else
    echo "$raw"
  fi
}

collect_host_stats() {
  python3 -c "
import subprocess, json, re

stats = {}

# CPU from /proc/stat (instant snapshot)
try:
    with open('/proc/loadavg') as f:
        load = f.read().split()
    stats['load_1m'] = float(load[0])
    stats['load_5m'] = float(load[1])
    import multiprocessing
    cores = multiprocessing.cpu_count()
    stats['cpu_pct'] = min(100, round(stats['load_1m'] / cores * 100))
    stats['cores'] = cores
except:
    stats['cpu_pct'] = -1

# Memory from /proc/meminfo
try:
    with open('/proc/meminfo') as f:
        meminfo = f.read()
    total = int(re.search(r'MemTotal:\s+(\d+)', meminfo).group(1))
    avail = int(re.search(r'MemAvailable:\s+(\d+)', meminfo).group(1))
    used = total - avail
    stats['mem_total_gb'] = round(total / 1048576, 1)
    stats['mem_used_gb'] = round(used / 1048576, 1)
    stats['mem_pct'] = round(used / total * 100)
except:
    stats['mem_pct'] = -1

# Disk /var/lib/rancher
try:
    r = subprocess.run(['df', '-h', '/var/lib/rancher'], capture_output=True, text=True)
    parts = r.stdout.strip().split('\n')[-1].split()
    stats['disk_used'] = parts[2]
    stats['disk_total'] = parts[1]
    stats['disk_pct'] = int(parts[4].rstrip('%'))
except:
    stats['disk_pct'] = -1

print(json.dumps(stats))
" 2>/dev/null || echo '{}'
}

collect_claude_procs() {
  python3 -c "
import subprocess, json

procs = []
try:
    r = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
    for line in r.stdout.strip().split('\n')[1:]:
        if 'claude' in line.lower() or 'anthropic' in line.lower():
            if 'grep' in line or 'intake-hud' in line:
                continue
            parts = line.split(None, 10)
            if len(parts) >= 11:
                procs.append({
                    'pid': parts[1],
                    'cpu': parts[2],
                    'mem_pct': parts[3],
                    'rss_mb': round(int(parts[5]) / 1024) if parts[5].isdigit() else 0,
                    'cmd': parts[10][:60]
                })
except:
    pass
print(json.dumps(procs))
" 2>/dev/null || echo '[]'
}

collect_worker_sessions() {
  # Parse active sessions from worker logs and intake session files
  python3 -c "
import json, glob, os, time

sessions = []
now = time.time()

# Worker log files
for logf in glob.glob('$WORKER_DIR/*.log'):
    pipeline = os.path.basename(logf).replace('.log', '')
    try:
        with open(logf) as f:
            lines = f.readlines()
        # Find active sessions: lines like [XXX] Launching codegen slot...
        active = {}
        for line in lines[-200:]:  # last 200 lines
            line = line.strip()
            if 'Launching codegen slot' in line:
                # Extract app prefix
                if '[' in line and ']' in line:
                    prefix = line.split('[')[1].split(']')[0]
                    active[prefix] = {'phase': 'Building', 'pipeline': pipeline}
            elif 'CODE+PUSH COMPLETE' in line or 'code+push OK' in line:
                if '[' in line and ']' in line:
                    prefix = line.split('[')[1].split(']')[0]
                    if prefix in active:
                        active[prefix]['phase'] = 'Ready'
            elif 'BUILD FAILED' in line or 'FAILED' in line:
                if '[' in line and ']' in line:
                    prefix = line.split('[')[1].split(']')[0]
                    if prefix in active:
                        active[prefix]['phase'] = 'Failed'

        # Get summary counts
        status_lines = [l for l in lines if 'built=' in l or 'deployed=' in l]
        if status_lines:
            last = status_lines[-1]
            sessions.append({
                'pipeline': pipeline,
                'status_line': last.strip()[-80:],
                'active_count': sum(1 for v in active.values() if v['phase'] == 'Building')
            })
    except:
        pass

# Check for intake session dirs
for sess_dir in glob.glob('/tmp/pc-autopilot/.intake-sessions/*'):
    if os.path.isdir(sess_dir):
        meta_file = os.path.join(sess_dir, 'meta.json')
        if os.path.exists(meta_file):
            try:
                with open(meta_file) as f:
                    meta = json.load(f)
                sessions.append({
                    'app': meta.get('appName', os.path.basename(sess_dir)),
                    'phase': meta.get('phase', 'Unknown'),
                    'progress': meta.get('progress', ''),
                    'cost': meta.get('cost', 0),
                    'model': meta.get('model', ''),
                    'pipeline': meta.get('pipeline', '')
                })
            except:
                pass

print(json.dumps(sessions))
" 2>/dev/null || echo '[]'
}

# ============================================================================
# Render: JSON output
# ============================================================================

render_json() {
  local ai_data="$1" pb_data="$2" host_stats="$3" claude_procs="$4" worker_sessions="$5"

  # Write data to temp files to avoid shell quoting issues with large JSON
  local tmpdir
  tmpdir=$(mktemp -d)
  echo "$ai_data"         > "$tmpdir/ai.json"
  echo "$pb_data"         > "$tmpdir/pb.json"
  echo "$host_stats"      > "$tmpdir/host.json"
  echo "$claude_procs"    > "$tmpdir/procs.json"
  echo "$worker_sessions" > "$tmpdir/workers.json"

  python3 - "$tmpdir" << 'PYEOF'
import json, sys, os
from datetime import datetime

tmpdir = sys.argv[1]

def safe_load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except:
        return {}

ai = safe_load(os.path.join(tmpdir, 'ai.json'))
pb = safe_load(os.path.join(tmpdir, 'pb.json'))
host = safe_load(os.path.join(tmpdir, 'host.json'))
procs = safe_load(os.path.join(tmpdir, 'procs.json'))
workers = safe_load(os.path.join(tmpdir, 'workers.json'))

output = {
    'timestamp': datetime.now().isoformat(),
    'agentIntakes': {},
    'paperclipBuilds': {},
    'host': host,
    'claudeProcesses': procs if isinstance(procs, list) else [],
    'workerSessions': workers if isinstance(workers, list) else []
}

# AgentIntake phases
if ai.get('exists', True):
    phases = {}
    for item in ai.get('items', []):
        p = item.get('status', {}).get('phase', 'Unknown')
        phases[p] = phases.get(p, 0) + 1
    output['agentIntakes'] = {
        'total': len(ai.get('items', [])),
        'phases': phases
    }
else:
    output['agentIntakes'] = {'total': 0, 'phases': {}, 'crdNotInstalled': True}

# PaperclipBuild phases
pb_phases = {}
for item in pb.get('items', []):
    p = item.get('status', {}).get('phase', 'Unknown')
    pb_phases[p] = pb_phases.get(p, 0) + 1
output['paperclipBuilds'] = {
    'total': len(pb.get('items', [])),
    'phases': pb_phases
}

print(json.dumps(output, indent=2))
PYEOF

  rm -rf "$tmpdir"
}

# ============================================================================
# Render: Terminal UI
# ============================================================================

render_terminal() {
  local ai_data="$1" pb_data="$2" host_stats="$3" claude_procs="$4" worker_sessions="$5"

  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')

  box_top
  box_line "${BOLD}ADLC Intake HUD${RESET}                          ${DIM}$now${RESET}"
  box_mid

  # --- AgentIntake CRD Summary ---
  local ai_exists ai_summary
  ai_summary=$(echo "$ai_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data.get('exists', True):
    print('NOT_INSTALLED')
    sys.exit(0)
items = data.get('items', [])
if not items:
    print('EMPTY')
    sys.exit(0)
phases = {}
for item in items:
    p = item.get('status', {}).get('phase', 'Unknown')
    phases[p] = phases.get(p, 0) + 1
total = len(items)

# Cost from CRD status
total_cost = 0
for item in items:
    c = item.get('status', {}).get('buildCostUsd', 0)
    if c: total_cost += float(c)

# Ordered display
order = ['Pending', 'Generating', 'Building', 'Deploying', 'Verifying', 'Ready', 'Failed']
parts = []
for phase in order:
    if phase in phases:
        parts.append(f'{phase}: {phases[phase]}')
# Include any not in standard order
for phase in sorted(phases):
    if phase not in order:
        parts.append(f'{phase}: {phases[phase]}')

print(f'PHASES|{total}|{total_cost:.2f}|{\"  |  \".join(parts)}')
" 2>/dev/null)

  box_empty
  box_line "${BOLD}${CYAN}AgentIntake CRDs:${RESET}"

  if [[ "$ai_summary" == "NOT_INSTALLED" ]]; then
    box_line "${DIM}  CRD not installed yet — no AgentIntake resources${RESET}"
  elif [[ "$ai_summary" == "EMPTY" ]]; then
    box_line "${DIM}  No AgentIntake CRDs found${RESET}"
    if [[ -n "$PIPELINE_FILTER" ]]; then
      box_line "${DIM}  (filtered by pipeline=$PIPELINE_FILTER)${RESET}"
    fi
  else
    local ai_total ai_cost ai_phases
    IFS='|' read -r _ ai_total ai_cost ai_phases <<< "$ai_summary"
    box_line "  Total: ${BOLD}$ai_total${RESET}  |  Cost: ${BOLD}\$$ai_cost${RESET}"
    # Split phases into rows (max ~60 chars per line)
    echo "$ai_phases" | python3 -c "
import sys
line = sys.stdin.read().strip()
# Print directly; caller handles box formatting
print(line)
" 2>/dev/null | while IFS= read -r pline; do
      box_line "  $pline"
    done
  fi

  box_empty

  # --- PaperclipBuild CRD Summary ---
  local pb_summary
  pb_summary=$(echo "$pb_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('items', [])
if not items:
    print('EMPTY|0')
    sys.exit(0)
phases = {}
for item in items:
    p = item.get('status', {}).get('phase', 'Unknown')
    phases[p] = phases.get(p, 0) + 1
total = len(items)
deployed = phases.get('Deployed', 0)
pct = round(deployed / total * 100) if total > 0 else 0
parts = []
for phase in sorted(phases, key=lambda x: -phases[x]):
    parts.append(f'{phases[phase]} {phase}')
print(f'OK|{total}|{deployed}|{pct}|{\", \".join(parts)}')
" 2>/dev/null)

  box_line "${BOLD}${CYAN}PaperclipBuilds:${RESET}"
  if [[ "$pb_summary" == EMPTY* ]]; then
    box_line "${DIM}  No PaperclipBuild CRDs found${RESET}"
  else
    IFS='|' read -r _ pb_total pb_deployed pb_pct pb_detail <<< "$pb_summary"
    local pct_color="$GREEN"
    [[ "$pb_pct" -lt 90 ]] && pct_color="$YELLOW"
    [[ "$pb_pct" -lt 50 ]] && pct_color="$RED"
    box_line "  ${BOLD}$pb_total${RESET} total (${pct_color}${BOLD}$pb_deployed Deployed${RESET}) — ${pct_color}${pb_pct}%${RESET}"
    box_line "  ${DIM}$pb_detail${RESET}"
  fi

  box_mid

  # --- Active Worker Sessions ---
  box_line "${BOLD}${CYAN}Active Sessions:${RESET}"
  box_empty

  local has_workers=false
  local all_pipelines
  all_pipelines=$(list_pipelines)
  for f in "$WORKER_DIR"/*.pid "$WORKER_DIR"/*.log; do
    [[ -f "$f" ]] || continue
    local p
    p=$(basename "$f" | sed 's/\.\(pid\|log\|started\)$//')
    [[ "$p" == "supervisor" || "$p" == supervisor-* ]] && continue
    echo "$all_pipelines" | grep -qw "$p" || all_pipelines="$all_pipelines $p"
  done

  for pipeline in $all_pipelines; do
    [[ -n "$PIPELINE_FILTER" && "$pipeline" != "$PIPELINE_FILTER" ]] && continue
    local pid_file="$WORKER_DIR/${pipeline}.pid"
    local log_file="$WORKER_DIR/${pipeline}.log"
    local started_file="$WORKER_DIR/${pipeline}.started"

    local status_icon status_text elapsed=""
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
      status_icon="${GREEN}●${RESET}"
      status_text="running"
      if [[ -f "$started_file" ]]; then
        local started now_ts secs
        started=$(cat "$started_file")
        now_ts=$(date +%s)
        secs=$((now_ts - started))
        elapsed="$(( secs / 3600 ))h$(( (secs % 3600) / 60 ))m"
      fi
    else
      status_icon="${RED}○${RESET}"
      status_text="stopped"
    fi

    box_line "  $status_icon ${BOLD}$pipeline${RESET}  $status_text  $elapsed"

    # Parse last status line from log
    if [[ -f "$log_file" ]]; then
      local last_status
      last_status=$(grep -oP 'done=\d+ fail=\d+ skip=\d+ / \d+' "$log_file" 2>/dev/null | tail -1)
      if [[ -z "$last_status" ]]; then
        last_status=$(grep -oP 'built=\d+ fail=\d+.*/ \d+' "$log_file" 2>/dev/null | tail -1)
      fi
      if [[ -n "$last_status" ]]; then
        box_line "    ${DIM}$last_status${RESET}"
      fi
      local last_action
      last_action=$(grep -E '^\[' "$log_file" 2>/dev/null | grep -vE 'finished|Launching|Phase' | tail -1)
      if [[ -n "$last_action" ]]; then
        box_line "    ${DIM}${last_action:0:60}${RESET}"
      fi
    fi
    has_workers=true
  done

  if [[ "$has_workers" == "false" ]]; then
    box_line "${DIM}  No active worker sessions${RESET}"
  fi

  box_mid

  # --- Recent Events (from worker logs) ---
  box_line "${BOLD}${CYAN}Recent Events:${RESET}"
  box_empty

  local events_found=false
  {
    for pipeline in $all_pipelines; do
      [[ -n "$PIPELINE_FILTER" && "$pipeline" != "$PIPELINE_FILTER" ]] && continue
      local log_file="$WORKER_DIR/${pipeline}.log"
      [[ -f "$log_file" ]] || continue
      grep -E "CODE READY|CODE\+PUSH COMPLETE|BUILD FAILED|FAILED|SKIP:|Deployed" "$log_file" 2>/dev/null | tail -5 | while IFS= read -r line; do
        local ts
        ts=$(echo "$line" | grep -oP '^\[\d{2}:\d{2}:\d{2}\]' | tr -d '[]')
        [[ -z "$ts" ]] && ts="--:--"
        local prefix=""
        if [[ "$line" == *"["*"]"* ]]; then
          prefix=$(echo "$line" | grep -oP '\[\w+\]' | head -1 | tr -d '[]')
        fi
        if [[ "$line" == *"CODE READY"* ]] || [[ "$line" == *"CODE+PUSH COMPLETE"* ]]; then
          echo "  ${GREEN}+${RESET} ${DIM}$ts${RESET}  ${prefix:-?}  ${GREEN}Code Ready${RESET}  ($pipeline)"
        elif [[ "$line" == *"FAILED"* ]]; then
          echo "  ${RED}x${RESET} ${DIM}$ts${RESET}  ${prefix:-?}  ${RED}Failed${RESET}  ($pipeline)"
        elif [[ "$line" == *"Deployed"* ]]; then
          echo "  ${GREEN}>${RESET} ${DIM}$ts${RESET}  ${prefix:-?}  ${CYAN}Deployed${RESET}  ($pipeline)"
        fi
        events_found=true
      done
    done
  } | tail -10 | while IFS= read -r event_line; do
    box_line "$event_line"
    events_found=true
  done

  # Only show "no events" if nothing printed
  if ! {
    for pipeline in $all_pipelines; do
      [[ -n "$PIPELINE_FILTER" && "$pipeline" != "$PIPELINE_FILTER" ]] && continue
      local log_file="$WORKER_DIR/${pipeline}.log"
      [[ -f "$log_file" ]] || continue
      grep -qE "CODE READY|CODE\+PUSH COMPLETE|BUILD FAILED|FAILED|Deployed" "$log_file" 2>/dev/null && echo "found" && break
    done
  } | grep -q "found"; then
    box_line "${DIM}  No recent events${RESET}"
  fi

  box_mid

  # --- Host Resources ---
  box_line "${BOLD}${CYAN}Host Resources:${RESET}"
  box_empty

  local cpu_pct mem_pct mem_used mem_total disk_pct disk_used disk_total
  cpu_pct=$(echo "$host_stats" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cpu_pct',-1))" 2>/dev/null)
  mem_pct=$(echo "$host_stats" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mem_pct',-1))" 2>/dev/null)
  mem_used=$(echo "$host_stats" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mem_used_gb','?'))" 2>/dev/null)
  mem_total=$(echo "$host_stats" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mem_total_gb','?'))" 2>/dev/null)
  disk_pct=$(echo "$host_stats" | python3 -c "import json,sys; print(json.load(sys.stdin).get('disk_pct',-1))" 2>/dev/null)
  disk_used=$(echo "$host_stats" | python3 -c "import json,sys; print(json.load(sys.stdin).get('disk_used','?'))" 2>/dev/null)
  disk_total=$(echo "$host_stats" | python3 -c "import json,sys; print(json.load(sys.stdin).get('disk_total','?'))" 2>/dev/null)

  local cpu_color="$GREEN" mem_color="$GREEN" disk_color="$GREEN"
  [[ "$cpu_pct" -gt 50 ]] 2>/dev/null && cpu_color="$YELLOW"
  [[ "$cpu_pct" -gt 80 ]] 2>/dev/null && cpu_color="$RED"
  [[ "$mem_pct" -gt 60 ]] 2>/dev/null && mem_color="$YELLOW"
  [[ "$mem_pct" -gt 80 ]] 2>/dev/null && mem_color="$RED"
  [[ "$disk_pct" -gt 80 ]] 2>/dev/null && disk_color="$YELLOW"
  [[ "$disk_pct" -gt 90 ]] 2>/dev/null && disk_color="$RED"

  local disk_warn=""
  [[ "$disk_pct" -gt 90 ]] 2>/dev/null && disk_warn=" ${RED}!!${RESET}"

  box_line "  CPU: ${cpu_color}${BOLD}${cpu_pct}%${RESET}  |  Mem: ${mem_color}${BOLD}${mem_pct}%${RESET} (${mem_used}/${mem_total}G)  |  Disk: ${disk_color}${BOLD}${disk_pct}%${RESET} (${disk_used}/${disk_total})${disk_warn}"

  # --- Claude Processes ---
  box_empty
  local proc_count proc_detail
  proc_count=$(echo "$claude_procs" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)

  if [[ "$proc_count" -gt 0 ]]; then
    box_line "  ${BOLD}Claude procs:${RESET} ${YELLOW}$proc_count active${RESET}"
    echo "$claude_procs" | python3 -c "
import json, sys
procs = json.load(sys.stdin)
for p in procs[:5]:
    pid = p['pid']
    rss = p['rss_mb']
    cpu = p['cpu']
    cmd = p['cmd'][:40]
    print(f'    pid {pid}: {rss}MB, {cpu}% CPU  {cmd}')
" 2>/dev/null | while IFS= read -r proc_line; do
      box_line "${DIM}$proc_line${RESET}"
    done
  else
    box_line "  ${BOLD}Claude procs:${RESET} ${GREEN}none${RESET}"
  fi

  # --- Circuit Breaker ---
  local cb_state
  cb_state=$(cat "$WORKSPACE/.circuit-breaker-state" 2>/dev/null || echo "unknown")
  local cb_color="$GREEN"
  case "$cb_state" in
    open)      cb_color="$RED" ;;
    half-open) cb_color="$YELLOW" ;;
  esac

  # Halt file
  local halt_status="${GREEN}clear${RESET}"
  [[ -f "$WORKSPACE/.emergency-halt" ]] && halt_status="${RED}ACTIVE${RESET}"

  box_empty
  box_line "  Breaker: ${cb_color}${BOLD}$cb_state${RESET}  |  Halt: $halt_status"

  box_bot
}

# ============================================================================
# Main
# ============================================================================

render_once() {
  # Collect data in parallel-ish (subshells)
  local ai_data pb_data host_stats claude_procs worker_sessions

  ai_data=$(collect_agentintake_data)
  pb_data=$(collect_paperclipbuild_data)
  host_stats=$(collect_host_stats)
  claude_procs=$(collect_claude_procs)
  worker_sessions=$(collect_worker_sessions)

  if [[ "$JSON_OUT" == "true" ]]; then
    render_json "$ai_data" "$pb_data" "$host_stats" "$claude_procs" "$worker_sessions"
  else
    render_terminal "$ai_data" "$pb_data" "$host_stats" "$claude_procs" "$worker_sessions"
  fi
}

if [[ "$WATCH" == "true" ]]; then
  while true; do
    clear
    render_once
    printf "${DIM}  Refreshing every %ds — Ctrl-C to exit${RESET}\n" "$INTERVAL"
    sleep "$INTERVAL"
  done
else
  render_once
fi
