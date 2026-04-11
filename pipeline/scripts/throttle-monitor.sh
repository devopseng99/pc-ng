#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# Throttle Monitor — early detection of API rate limiting / usage caps
#
# Monitors multiple signal sources faster than the circuit breaker:
#   1. Claude debug logs — API 429/529/overloaded errors
#   2. Build logs — "out of usage" messages in Claude output
#   3. Worker logs — supervisor usage-cap detections
#   4. Circuit breaker state file
#   5. Build velocity — detects slowdowns indicating throttling
#
# Usage: ./throttle-monitor.sh              # one-shot check
#        ./throttle-monitor.sh --watch       # continuous (for /loop)
#        ./throttle-monitor.sh --json        # machine-readable output
# ============================================================================

WORKSPACE="/tmp/pc-autopilot"
CLAUDE_DEBUG="$HOME/.claude/debug"
BUILD_LOGS="$WORKSPACE/logs"
WORKER_LOGS="$WORKSPACE/.workers"
CB_STATE="$WORKSPACE/.circuit-breaker-state"
CB_RESULTS="$WORKSPACE/.circuit-breaker-results"
STATE_FILE="$WORKSPACE/.throttle-monitor-state"

WATCH=false
JSON_OUT=false
ALERT_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)      WATCH=true; shift ;;
    --json)       JSON_OUT=true; shift ;;
    --alert-only) ALERT_ONLY=true; shift ;;
    *) shift ;;
  esac
done

# --- Colors ---
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

now_ts() { date +%s; }
now_fmt() { date '+%H:%M:%S'; }

# Track last-checked positions to avoid re-alerting
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
  fi
  : "${LAST_DEBUG_BYTES:=0}"
  : "${LAST_BUILD_CHECK:=0}"
  : "${LAST_WORKER_BYTES:=0}"
  : "${THROTTLE_EVENTS:=0}"
  : "${FIRST_THROTTLE_TS:=0}"
}

save_state() {
  cat > "$STATE_FILE" << EOF
LAST_DEBUG_BYTES=$LAST_DEBUG_BYTES
LAST_BUILD_CHECK=$LAST_BUILD_CHECK
LAST_WORKER_BYTES=$LAST_WORKER_BYTES
THROTTLE_EVENTS=$THROTTLE_EVENTS
FIRST_THROTTLE_TS=$FIRST_THROTTLE_TS
EOF
}

alerts=()
warnings=()
info=()

add_alert()   { alerts+=("$1"); }
add_warning() { warnings+=("$1"); }
add_info()    { info+=("$1"); }

# ─── Signal 1: Claude debug logs — API-level throttling ───
check_debug_logs() {
  # Only check debug files modified in last 10 minutes (active sessions)
  local active_files
  active_files=$(find "$CLAUDE_DEBUG" -name "*.txt" -mmin -10 2>/dev/null || true)
  [[ -z "$active_files" ]] && { add_info "No active Claude debug sessions (last 10m)"; return; }

  local hits=0
  while IFS= read -r dbg; do
    [[ -f "$dbg" ]] || continue
    local count=0
    count=$(grep -c -i -E \
      '429|529|overloaded|rate_limit|rate.limit_error|retry.after|too.many.requests|server.overloaded|capacity|throttl' \
      "$dbg" 2>/dev/null) || true
    if (( count > 0 )); then
      local session_id
      session_id=$(basename "$dbg" .txt)
      # Get the most recent match for context
      local last_hit
      last_hit=$(grep -i -E '429|529|overloaded|rate_limit|retry.after|too.many.requests|throttl' "$dbg" 2>/dev/null | tail -1)
      local ts
      ts=$(echo "$last_hit" | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' | tail -1 || echo "unknown")
      hits=$((hits + count))
      add_alert "API throttle in debug/${session_id:0:8}...: ${count} events (last: $ts)"
    fi
  done <<< "$active_files"

  if (( hits > 0 )); then
    THROTTLE_EVENTS=$((THROTTLE_EVENTS + hits))
    [[ "$FIRST_THROTTLE_TS" == "0" ]] && FIRST_THROTTLE_TS=$(now_ts)
  fi
}

# ─── Signal 2: Build logs — usage cap in Claude output ───
check_build_logs() {
  [[ -d "$BUILD_LOGS" ]] || return
  local now
  now=$(now_ts)

  # Only check logs modified since last check
  local recent_logs
  recent_logs=$(find "$BUILD_LOGS" -name "*.log" -newer "$STATE_FILE" 2>/dev/null || \
                find "$BUILD_LOGS" -name "*.log" -mmin -5 2>/dev/null)
  [[ -z "$recent_logs" ]] && return

  while IFS= read -r logf; do
    [[ -f "$logf" ]] || continue
    if grep -qi -E 'out of extra usage|usage.*resets|You.re out of|rate limit|too many requests|usage cap|billing limit' "$logf" 2>/dev/null; then
      local app
      app=$(basename "$logf" .log | cut -d'-' -f1)
      add_alert "USAGE CAP detected in build log: $app"
      THROTTLE_EVENTS=$((THROTTLE_EVENTS + 1))
      [[ "$FIRST_THROTTLE_TS" == "0" ]] && FIRST_THROTTLE_TS=$(now_ts)
    fi
  done <<< "$recent_logs"

  LAST_BUILD_CHECK=$now
}

# ─── Signal 3: Worker logs — supervisor detections ───
check_worker_logs() {
  # Only check logs modified in last 10 minutes
  local recent_logs
  recent_logs=$(find "$WORKER_LOGS" -name "*.log" -mmin -10 2>/dev/null || true)
  [[ -z "$recent_logs" ]] && return

  while IFS= read -r logf; do
    [[ -f "$logf" ]] || continue
    local name
    name=$(basename "$logf" .log)

    # Check last 50 lines for usage-cap (not full history)
    local cap_count=0
    cap_count=$(tail -50 "$logf" 2>/dev/null | grep -c "usage-cap") || true
    if (( cap_count > 0 )); then
      local last_cap
      last_cap=$(tail -50 "$logf" | grep "usage-cap" | tail -1)
      add_alert "Worker '$name': ${cap_count} recent usage-cap events | $last_cap"
    fi

    # Check for rapid consecutive failures (throttle precursor)
    local recent_fails=0
    recent_fails=$(tail -20 "$logf" 2>/dev/null | grep -c "FAILED") || true
    if (( recent_fails >= 5 )); then
      add_warning "Worker '$name': ${recent_fails} failures in last 20 lines — possible throttling"
    fi
  done <<< "$recent_logs"
}

# ─── Signal 4: Circuit breaker state ───
check_circuit_breaker() {
  if [[ -f "$CB_STATE" ]]; then
    local state
    state=$(cat "$CB_STATE")
    case "$state" in
      open)
        add_alert "Circuit breaker is OPEN (tripped)"
        ;;
      half-open)
        add_warning "Circuit breaker is HALF-OPEN (testing recovery)"
        ;;
      closed)
        add_info "Circuit breaker: closed (normal)"
        ;;
    esac
  fi

  # Check recent failure rate from results file
  if [[ -f "$CB_RESULTS" ]]; then
    local total fails
    total=$(tail -10 "$CB_RESULTS" | wc -l)
    fails=$(tail -10 "$CB_RESULTS" | grep -c "fail") || true
    if (( total > 0 )); then
      local pct=$(( fails * 100 / total ))
      if (( pct >= 50 )); then
        add_warning "Failure rate: ${pct}% in last 10 builds (${fails}/${total})"
      else
        add_info "Failure rate: ${pct}% in last 10 builds (${fails}/${total})"
      fi
    fi
  fi
}

# ─── Signal 5: Build velocity — slow builds = throttling ───
check_build_velocity() {
  if [[ ! -f "$CB_RESULTS" ]]; then return; fi

  # Calculate average time between recent builds
  local timestamps
  timestamps=$(tail -10 "$CB_RESULTS" | cut -d'|' -f1)
  local count=0 total_gap=0 prev=0
  while IFS= read -r ts; do
    [[ -z "$ts" ]] && continue
    if (( prev > 0 )); then
      local gap=$(( ts - prev ))
      total_gap=$(( total_gap + gap ))
      count=$((count + 1))
    fi
    prev=$ts
  done <<< "$timestamps"

  if (( count > 0 )); then
    local avg_gap=$(( total_gap / count ))
    if (( avg_gap > 600 )); then
      add_warning "Build velocity: avg ${avg_gap}s between builds (>10min = likely throttled)"
    elif (( avg_gap > 300 )); then
      add_info "Build velocity: avg ${avg_gap}s between builds (normal-slow)"
    else
      add_info "Build velocity: avg ${avg_gap}s between builds"
    fi
  fi
}

# ─── Signal 6: Active Claude processes ───
check_active_sessions() {
  local claude_procs=0
  claude_procs=$(pgrep -c -f "claude.*dangerously" 2>/dev/null) || true
  add_info "Active Claude sessions: $claude_procs"

  # Check active workers — only warn for recently dead (PID file < 30 min old)
  local alive=0 dead=0 stale=0
  for pidfile in "$WORKER_LOGS"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid name
    pid=$(cat "$pidfile")
    name=$(basename "$pidfile" .pid)
    if kill -0 "$pid" 2>/dev/null; then
      alive=$((alive + 1))
    else
      # Check if PID file is recent (died unexpectedly) vs old (finished pipeline)
      local age_min
      age_min=$(( ( $(now_ts) - $(stat -c %Y "$pidfile") ) / 60 ))
      if (( age_min < 30 )); then
        dead=$((dead + 1))
        add_warning "Worker '$name' (PID $pid) DIED ${age_min}m ago"
      else
        stale=$((stale + 1))
      fi
    fi
  done
  add_info "Workers: ${alive} alive${dead:+, ${dead} recently dead}${stale:+, ${stale} finished}"
}

# ─── Output ───
render_text() {
  echo ""
  echo -e "${BLD}━━━ Throttle Monitor ━━━ $(now_fmt) ━━━${RST}"
  echo ""

  if (( ${#alerts[@]} > 0 )); then
    echo -e "  ${RED}${BLD}🚨 ALERTS${RST}"
    for a in "${alerts[@]}"; do
      echo -e "  ${RED}  ▸ $a${RST}"
    done
    echo ""
  fi

  if (( ${#warnings[@]} > 0 )); then
    echo -e "  ${YEL}${BLD}⚠  WARNINGS${RST}"
    for w in "${warnings[@]}"; do
      echo -e "  ${YEL}  ▸ $w${RST}"
    done
    echo ""
  fi

  if [[ "$ALERT_ONLY" != "true" ]] && (( ${#info[@]} > 0 )); then
    echo -e "  ${CYN}ℹ  STATUS${RST}"
    for i in "${info[@]}"; do
      echo -e "  ${CYN}  ▸ $i${RST}"
    done
    echo ""
  fi

  if (( ${#alerts[@]} == 0 && ${#warnings[@]} == 0 )); then
    echo -e "  ${GRN}✓  No throttling detected${RST}"
    echo ""
  fi

  if (( THROTTLE_EVENTS > 0 )); then
    echo -e "  ${YEL}Total throttle events this session: ${THROTTLE_EVENTS}${RST}"
    echo ""
  fi
}

render_json() {
  local status="ok"
  (( ${#alerts[@]} > 0 )) && status="alert"
  (( ${#alerts[@]} == 0 && ${#warnings[@]} > 0 )) && status="warning"

  local json_alerts="[]" json_warnings="[]" json_info="[]"
  if (( ${#alerts[@]} > 0 )); then
    json_alerts=$(printf '%s\n' "${alerts[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  fi
  if (( ${#warnings[@]} > 0 )); then
    json_warnings=$(printf '%s\n' "${warnings[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  fi
  if (( ${#info[@]} > 0 )); then
    json_info=$(printf '%s\n' "${info[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  fi

  cat << ENDJSON
{
  "timestamp": "$(date -Iseconds)",
  "status": "$status",
  "throttle_events": $THROTTLE_EVENTS,
  "alerts": $json_alerts,
  "warnings": $json_warnings,
  "info": $json_info
}
ENDJSON
}

# ─── Main ───
run_checks() {
  alerts=()
  warnings=()
  info=()

  load_state
  check_debug_logs
  check_build_logs
  check_worker_logs
  check_circuit_breaker
  check_build_velocity
  check_active_sessions
  save_state

  if [[ "$JSON_OUT" == "true" ]]; then
    render_json
  else
    render_text
  fi
}

if [[ "$WATCH" == "true" ]]; then
  while true; do
    clear
    run_checks
    sleep 30
  done
else
  run_checks
fi
