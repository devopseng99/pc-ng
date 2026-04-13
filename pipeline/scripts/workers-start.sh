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
source "$SCRIPT_DIR/pipeline-registry.sh"
WORKSPACE="/tmp/pc-autopilot"
WORKER_DIR="$WORKSPACE/.workers"
CONCURRENCY=2
PIPELINE=""
STOP=false
TIMEOUT=300
STALL=90
AUTO_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline)     PIPELINE="$2"; shift 2 ;;
    --concurrency)  CONCURRENCY="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --stall)        STALL="$2"; shift 2 ;;
    --stop)         STOP=true; shift ;;
    --auto-build)   AUTO_BUILD=true; shift ;;
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

resolve_manifest() {
  local pipeline_id="$1"
  if resolve_pipeline "$pipeline_id"; then
    local manifest_file="$WORKSPACE/manifests/$PC_MANIFEST"
    if [[ -f "$manifest_file" ]] || [[ -L "$manifest_file" ]]; then
      echo "$manifest_file"
      return 0
    fi
  fi
  echo ""
  return 1
}

start_worker() {
  local pipeline_id="$1"
  local manifest
  manifest=$(resolve_manifest "$pipeline_id") || { log "ERROR: Unknown pipeline: $pipeline_id"; return 1; }
  local log_file="$WORKER_DIR/${pipeline_id}.log"
  local pid_file="$WORKER_DIR/${pipeline_id}.pid"

  if [[ ! -f "$manifest" ]] && [[ ! -L "$manifest" ]]; then
    log "ERROR: Manifest not found: $manifest"
    return 1
  fi

  # Check if already running — don't interrupt, let it finish
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    log "Worker $pipeline_id already running (PID $(cat "$pid_file")) — skipping (let it finish)"
    return 0
  fi

  # Auto-generate CRDs before launching worker (idempotent — skips existing)
  log "Ensuring CRDs exist for $pipeline_id..."
  bash "$SCRIPT_DIR/generate-crds.sh" \
    --manifest "$manifest" \
    --pipeline "$pipeline_id" 2>&1 | while read -r line; do echo "  $line"; done

  log "Starting $pipeline_id worker (concurrency=$CONCURRENCY, timeout=${TIMEOUT}s)..."
  log "  Log: $log_file"

  # Record start time
  date +%s > "$WORKER_DIR/${pipeline_id}.started"

  # Build extra args
  local extra_args=""
  [[ "$AUTO_BUILD" == "true" ]] && extra_args="--auto-build"

  # Launch in background
  nohup bash "$SCRIPT_DIR/phase-a-codegen.sh" \
    --manifest "$manifest" \
    --pipeline-id "$pipeline_id" \
    --concurrency "$CONCURRENCY" \
    --timeout "$TIMEOUT" \
    --stall-timeout "$STALL" \
    $extra_args \
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
