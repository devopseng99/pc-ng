#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Start background codegen workers
#
# Launches Phase A codegen as background processes logging to files.
# No tmux needed — check progress with workers-dashboard.sh or workers-status.sh
#
# Usage:
#   ./workers-start.sh                     # start both v1 + tech
#   ./workers-start.sh --pipeline v1       # start only v1
#   ./workers-start.sh --concurrency 6     # override concurrency
#   ./workers-start.sh --stop              # stop all workers
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="/tmp/pc-autopilot"
WORKER_DIR="$WORKSPACE/.workers"
CONCURRENCY=2
PIPELINE=""
STOP=false
TIMEOUT=300
STALL=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline)     PIPELINE="$2"; shift 2 ;;
    --concurrency)  CONCURRENCY="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --stall)        STALL="$2"; shift 2 ;;
    --stop)         STOP=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

mkdir -p "$WORKER_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

stop_workers() {
  local killed=0
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid name
    pid=$(cat "$pidfile")
    name=$(basename "$pidfile" .pid)
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      # Also kill child processes
      pkill -P "$pid" 2>/dev/null || true
      log "Stopped $name (PID $pid)"
      killed=$((killed + 1))
    fi
    rm -f "$pidfile"
  done
  log "Stopped $killed worker(s)"
}

if [[ "$STOP" == "true" ]]; then
  stop_workers
  exit 0
fi

start_worker() {
  local pipeline_id="$1"
  local manifest="$WORKSPACE/manifests/use-cases-${pipeline_id}.json"
  local log_file="$WORKER_DIR/${pipeline_id}.log"
  local pid_file="$WORKER_DIR/${pipeline_id}.pid"
  local manifest_key=""

  case "$pipeline_id" in
    v1)   manifest="$WORKSPACE/manifests/use-cases-201-400.json" ;;
    tech) manifest="$WORKSPACE/manifests/use-cases-401-600.json" ;;
    wasm) manifest="$WORKSPACE/manifests/wasm-sandbox-apps.json" ;;
    soa)  manifest="$WORKSPACE/manifests/pc-soa-v3-templates.json" ;;
    ai)   manifest="$WORKSPACE/manifests/ai-income-apps.json" ;;
    *)    log "ERROR: Unknown pipeline: $pipeline_id"; return 1 ;;
  esac

  if [[ ! -f "$manifest" ]] && [[ ! -L "$manifest" ]]; then
    log "ERROR: Manifest not found: $manifest"
    return 1
  fi

  # Check if already running
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    log "Worker $pipeline_id already running (PID $(cat "$pid_file"))"
    return 0
  fi

  log "Starting $pipeline_id worker (concurrency=$CONCURRENCY, timeout=${TIMEOUT}s)..."
  log "  Log: $log_file"

  # Record start time
  date +%s > "$WORKER_DIR/${pipeline_id}.started"

  # Launch in background
  nohup bash "$SCRIPT_DIR/phase-a-codegen.sh" \
    --manifest "$manifest" \
    --pipeline-id "$pipeline_id" \
    --concurrency "$CONCURRENCY" \
    --timeout "$TIMEOUT" \
    --stall-timeout "$STALL" \
    >> "$log_file" 2>&1 &

  local pid=$!
  echo "$pid" > "$pid_file"
  log "  Started PID $pid"
}

# Start workers
if [[ -n "$PIPELINE" ]]; then
  start_worker "$PIPELINE"
else
  start_worker "v1"
  start_worker "tech"
fi

log ""
log "Workers running in background. Monitor with:"
log "  $SCRIPT_DIR/workers-dashboard.sh        # live dashboard"
log "  $SCRIPT_DIR/workers-status.sh            # one-shot status"
log "  $SCRIPT_DIR/workers-start.sh --stop      # stop all"
log "  tail -f $WORKER_DIR/v1.log              # raw v1 log"
log "  tail -f $WORKER_DIR/tech.log            # raw tech log"
