#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# One-shot status of codegen workers + cluster health
# Use workers-dashboard.sh for auto-refreshing version
# ============================================================================

WORKSPACE="/tmp/pc-autopilot"
WORKER_DIR="$WORKSPACE/.workers"
BOLD="\033[1m" DIM="\033[2m" GREEN="\033[32m" RED="\033[31m" YELLOW="\033[33m" CYAN="\033[36m" RESET="\033[0m"

# --- Worker Status ---
printf "\n${BOLD}${CYAN}=== PC Pipeline Workers ===${RESET}  %s\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"

for pipeline in v1 tech; do
  pid_file="$WORKER_DIR/${pipeline}.pid"
  log_file="$WORKER_DIR/${pipeline}.log"
  started_file="$WORKER_DIR/${pipeline}.started"

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    pid=$(cat "$pid_file")
    elapsed=""
    if [[ -f "$started_file" ]]; then
      started=$(cat "$started_file")
      now=$(date +%s)
      secs=$((now - started))
      elapsed="$(( secs / 3600 ))h$(( (secs % 3600) / 60 ))m"
    fi
    printf "  ${GREEN}●${RESET} ${BOLD}%-6s${RESET} PID %-8s running %s\n" "$pipeline" "$pid" "$elapsed"
  else
    printf "  ${RED}○${RESET} ${BOLD}%-6s${RESET} stopped\n" "$pipeline"
  fi

  # Parse last progress line from log
  if [[ -f "$log_file" ]]; then
    # Extract done/fail/skip counts from last status line
    last_status=$(grep -oP 'done=\d+ fail=\d+ skip=\d+ / \d+' "$log_file" | tail -1)
    if [[ -n "$last_status" ]]; then
      printf "         %s\n" "$last_status"
    fi
    # Last few actions
    last_action=$(grep -E '^\[' "$log_file" | grep -vE 'finished|Launching' | tail -1)
    if [[ -n "$last_action" ]]; then
      printf "         ${DIM}%s${RESET}\n" "${last_action:0:80}"
    fi
  fi
done

# --- CRD Phase Summary ---
printf "\n${BOLD}${CYAN}=== CRD Status ===${RESET}\n"
kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
phases = {}
for i in data['items']:
    p = i.get('status',{}).get('phase','Unknown')
    phases[p] = phases.get(p,0) + 1
total = len(data['items'])
for p in sorted(phases, key=lambda x: -phases[x]):
    bar = '█' * (phases[p] * 30 // total)
    print(f'  {p:20s} {phases[p]:4d}  {bar}')
print(f'  {\"TOTAL\":20s} {total:4d}')
" 2>/dev/null

# --- Ready to Deploy ---
ready=$(ls "$WORKSPACE/.ready-to-deploy/"*.json 2>/dev/null | wc -l)
printf "\n${BOLD}${CYAN}=== Deploy Queue ===${RESET}\n"
printf "  Ready to deploy: ${BOLD}%d${RESET} apps\n" "$ready"
if [[ "$ready" -gt 0 ]]; then
  printf "  Run: ${DIM}pipeline/scripts/batch-deploy-k8s.sh${RESET}\n"
fi

# --- Cluster Resources ---
printf "\n${BOLD}${CYAN}=== Cluster Resources ===${RESET}\n"
kubectl top nodes --no-headers 2>/dev/null | while read name cpu cpu_pct mem mem_pct; do
  cpu_pct_num=${cpu_pct%%%}
  mem_pct_num=${mem_pct%%%}
  cpu_color="$GREEN"; [[ "$cpu_pct_num" -gt 50 ]] && cpu_color="$YELLOW"; [[ "$cpu_pct_num" -gt 70 ]] && cpu_color="$RED"
  mem_color="$GREEN"; [[ "$mem_pct_num" -gt 50 ]] && mem_color="$YELLOW"; [[ "$mem_pct_num" -gt 70 ]] && mem_color="$RED"
  printf "  %-12s CPU: ${cpu_color}%4s %s${RESET}   MEM: ${mem_color}%8s %s${RESET}\n" "$name" "$cpu" "$cpu_pct" "$mem" "$mem_pct"
done

# --- K8s Pods ---
pod_count=$(kubectl get pods -n paperclip -l managed-by=pc-ng --no-headers 2>/dev/null | wc -l)
not_running=$(kubectl get pods -n paperclip -l managed-by=pc-ng --no-headers 2>/dev/null | grep -v Running | wc -l)
printf "\n${BOLD}${CYAN}=== K8s Pods ===${RESET}\n"
printf "  pc-ng managed: ${BOLD}%d${RESET} pods" "$pod_count"
if [[ "$not_running" -gt 0 ]]; then
  printf "  (${RED}%d not running${RESET})" "$not_running"
fi
echo ""

# --- Recent Activity (last 5 completed builds) ---
printf "\n${BOLD}${CYAN}=== Recent Activity ===${RESET}\n"
for pipeline in v1 tech; do
  log_file="$WORKER_DIR/${pipeline}.log"
  [[ -f "$log_file" ]] || continue
  grep "CODE READY\|BUILD FAILED\|SKIP:" "$log_file" | tail -3 | while read line; do
    if [[ "$line" == *"CODE READY"* ]]; then
      printf "  ${GREEN}✓${RESET} %s\n" "${line:0:80}"
    elif [[ "$line" == *"FAILED"* ]]; then
      printf "  ${RED}✗${RESET} %s\n" "${line:0:80}"
    fi
  done
done

echo ""
