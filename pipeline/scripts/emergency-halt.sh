#!/usr/bin/env bash
# ============================================================================
# EMERGENCY HALT — Immediately stops ALL pipeline operations
#
# Usage:
#   ./emergency-halt.sh          # halt everything
#   ./emergency-halt.sh --resume # clear halt and allow operations to resume
#   ./emergency-halt.sh --status # show what's running
# ============================================================================

WORKSPACE="/tmp/pc-autopilot"
HALT_FILE="$WORKSPACE/.emergency-halt"
WORKER_DIR="$WORKSPACE/.workers"
RED="\033[31m" GREEN="\033[32m" YELLOW="\033[33m" BOLD="\033[1m" RESET="\033[0m"

case "${1:-halt}" in
  --resume|resume)
    rm -f "$HALT_FILE"
    echo "closed" > "$WORKSPACE/.circuit-breaker-state" 2>/dev/null
    echo -e "${GREEN}${BOLD}RESUMED${RESET} — halt file removed, circuit breaker reset"
    echo "Workers will NOT auto-restart. Start manually:"
    echo "  pipeline/scripts/workers-start.sh"
    exit 0
    ;;

  --status|status)
    echo -e "${BOLD}=== Pipeline Process Status ===${RESET}"
    echo ""

    # Halt file
    if [[ -f "$HALT_FILE" ]]; then
      echo -e "  Halt file:    ${RED}ACTIVE${RESET} ($HALT_FILE)"
    else
      echo -e "  Halt file:    ${GREEN}not set${RESET}"
    fi

    # Circuit breaker
    cb_state=$(cat "$WORKSPACE/.circuit-breaker-state" 2>/dev/null || echo "unknown")
    case "$cb_state" in
      closed)    echo -e "  Breaker:      ${GREEN}closed (normal)${RESET}" ;;
      open)      echo -e "  Breaker:      ${RED}OPEN (tripped)${RESET}" ;;
      half-open) echo -e "  Breaker:      ${YELLOW}half-open (testing)${RESET}" ;;
      *)         echo -e "  Breaker:      ${YELLOW}$cb_state${RESET}" ;;
    esac

    # Workers
    for p in v1 tech; do
      pf="$WORKER_DIR/${p}.pid"
      if [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null; then
        echo -e "  Worker $p:    ${GREEN}RUNNING${RESET} (PID $(cat "$pf"))"
      else
        echo -e "  Worker $p:    ${RED}stopped${RESET}"
      fi
    done

    # Supervisor
    sf="$WORKER_DIR/supervisor.pid"
    if [[ -f "$sf" ]] && kill -0 "$(cat "$sf")" 2>/dev/null; then
      echo -e "  Supervisor:   ${GREEN}RUNNING${RESET} (PID $(cat "$sf"))"
    else
      echo -e "  Supervisor:   ${RED}stopped${RESET}"
    fi

    # Claude processes
    claude_count=$(pgrep -fc "claude.*--dangerously-skip" 2>/dev/null || true)
    claude_count=${claude_count:-0}; claude_count=${claude_count// /}
    if (( claude_count > 0 )); then
      echo -e "  Claude procs: ${YELLOW}${claude_count} active${RESET}"
      pgrep -fa "claude.*--dangerously-skip" 2>/dev/null | awk '{print "    PID " $1}'
    else
      echo -e "  Claude procs: ${GREEN}none${RESET}"
    fi

    # Batch deploy
    bd_count=$(pgrep -fc "batch-deploy" 2>/dev/null || true)
    bd_count=${bd_count:-0}; bd_count=${bd_count// /}
    if (( bd_count > 0 )); then
      echo -e "  Batch deploy: ${YELLOW}RUNNING${RESET}"
    else
      echo -e "  Batch deploy: ${GREEN}not running${RESET}"
    fi

    echo ""
    exit 0
    ;;

  --halt|halt|*)
    echo -e "${RED}${BOLD}╔══════════════════════════════════════╗${RESET}"
    echo -e "${RED}${BOLD}║       EMERGENCY HALT ACTIVATED       ║${RESET}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════╝${RESET}"
    echo ""

    # 1. Create halt file (workers check this every loop iteration)
    touch "$HALT_FILE"
    echo "open" > "$WORKSPACE/.circuit-breaker-state" 2>/dev/null
    echo -e "  [1/5] ${YELLOW}Halt file created${RESET}"

    # 2. Stop workers (sends SIGTERM to worker parent processes)
    killed=0
    for p in v1 tech; do
      pf="$WORKER_DIR/${p}.pid"
      if [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null; then
        kill "$(cat "$pf")" 2>/dev/null
        killed=$((killed + 1))
      fi
      rm -f "$pf"
    done
    echo -e "  [2/5] ${YELLOW}Stopped $killed worker(s)${RESET}"

    # 3. Stop supervisor
    sf="$WORKER_DIR/supervisor.pid"
    if [[ -f "$sf" ]] && kill -0 "$(cat "$sf")" 2>/dev/null; then
      kill "$(cat "$sf")" 2>/dev/null
      echo -e "  [3/5] ${YELLOW}Stopped supervisor${RESET}"
    else
      echo -e "  [3/5] Supervisor not running"
    fi
    rm -f "$sf"

    # 4. Kill batch deploy processes
    pkill -f "batch-deploy-k8s" 2>/dev/null && \
      echo -e "  [4/5] ${YELLOW}Stopped batch deploy${RESET}" || \
      echo -e "  [4/5] Batch deploy not running"

    # 5. Gracefully terminate Claude processes (SIGTERM, not SIGKILL)
    claude_pids=$(pgrep -f "claude.*--dangerously-skip" 2>/dev/null || true)
    if [[ -n "$claude_pids" ]]; then
      count=$(echo "$claude_pids" | wc -l)
      echo -e "  [5/5] ${YELLOW}Sending SIGTERM to $count Claude process(es)...${RESET}"
      echo "$claude_pids" | while read pid; do
        kill "$pid" 2>/dev/null || true
        echo "    Terminated PID $pid"
      done
      # Wait for graceful shutdown
      sleep 3
      # Force-kill any that didn't stop
      remaining=$(pgrep -f "claude.*--dangerously-skip" 2>/dev/null || true)
      if [[ -n "$remaining" ]]; then
        echo "$remaining" | xargs kill -9 2>/dev/null || true
        echo -e "    ${RED}Force-killed remaining processes${RESET}"
      fi
    else
      echo -e "  [5/5] No Claude processes running"
    fi

    echo ""
    echo -e "${BOLD}All pipeline operations stopped.${RESET}"
    echo ""
    echo "To resume operations:"
    echo "  pipeline/scripts/emergency-halt.sh --resume"
    echo "  pipeline/scripts/workers-start.sh"
    echo ""
    echo "To check status:"
    echo "  pipeline/scripts/emergency-halt.sh --status"
    ;;
esac
