#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# self-heal.sh — Autonomous self-healing daemon for PaperclipBuild CRDs
#
# Monitors for Failed CRDs, classifies failures, and dispatches appropriate
# fixes. Runs as a one-shot scanner or as a persistent daemon.
#
# Proven approach: autoloop cleared 63 apps in 9 rounds ($540 total).
# This script formalizes that as a permanent, budget-aware healing loop.
#
# Usage:
#   bash self-heal.sh                           # Run once (scan + fix)
#   bash self-heal.sh --daemon                  # Run continuously
#   bash self-heal.sh --daemon --interval 300   # Check every 5 minutes
#   bash self-heal.sh --dry-run                 # Show what would be fixed
#   bash self-heal.sh --pipeline tech           # Only heal one pipeline
#   bash self-heal.sh --max-fixes 10            # Fix at most N apps per round
#   bash self-heal.sh --max-cost 50.00          # Budget cap per round
#   bash self-heal.sh --status                  # Show healing stats
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pipeline-registry.sh"

WORKSPACE="/tmp/pc-autopilot"
LOG_FILE="$WORKSPACE/.self-heal.log"
STATS_FILE="$WORKSPACE/.self-heal-stats.json"
PID_FILE="$WORKSPACE/.self-heal.pid"
HALT_FILE="$WORKSPACE/.emergency-halt"
QUARANTINE_ANNOTATION="self-heal/quarantined"
RETRY_TRACKER_DIR="$WORKSPACE/.self-heal-retries"

# --- Defaults ---
DAEMON_MODE=false
DRY_RUN=false
SHOW_STATUS=false
INTERVAL=300
MAX_FIXES=10
MAX_COST="50.00"
PIPELINE_FILTER=""
MAX_QUARANTINE_ATTEMPTS=3

# --- Cost estimates (based on observed autoloop data) ---
COST_NOBUILDSCRIPT="0.29"
COST_BUILDERROR="0.08"
COST_DEPLOYERROR="0.01"
COST_PUSHERROR="0.01"

# Colors
BOLD="\033[1m" DIM="\033[2m" GREEN="\033[32m" RED="\033[31m"
YELLOW="\033[33m" CYAN="\033[36m" MAGENTA="\033[35m" RESET="\033[0m"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon)       DAEMON_MODE=true; shift ;;
    --interval)     INTERVAL="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --pipeline)     PIPELINE_FILTER="$2"; shift 2 ;;
    --max-fixes)    MAX_FIXES="$2"; shift 2 ;;
    --max-cost)     MAX_COST="$2"; shift 2 ;;
    --status)       SHOW_STATUS=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$WORKSPACE" "$RETRY_TRACKER_DIR"

# --- Logging ---
hlog() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SELF-HEAL] $*"
  echo -e "$msg" | tee -a "$LOG_FILE"
}

# --- Redis (optional — best-effort) ---
REDIS_PASS_FILE="$WORKSPACE/.redis-pass"
_redis_pass() {
  if [[ -f "$REDIS_PASS_FILE" ]]; then cat "$REDIS_PASS_FILE"
  else
    local pass
    pass=$(kubectl get secret redis-credentials -n paperclip-v3 \
      -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo '')
    [[ -n "$pass" ]] && { echo "$pass" > "$REDIS_PASS_FILE"; chmod 600 "$REDIS_PASS_FILE"; }
    echo "$pass"
  fi
}
rcli() {
  kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- \
    redis-cli -a "$(_redis_pass)" --no-auth-warning "$@" 2>/dev/null
}
redis_publish() {
  local type="$1" payload="$2"
  rcli PUBLISH "pipeline:events" \
    "{\"type\":\"${type}\",\"ts\":\"$(date -Iseconds)\",${payload}}" \
    >/dev/null 2>&1 || true
}

# ============================================================================
# STATUS COMMAND
# ============================================================================
show_status() {
  echo -e "${BOLD}${CYAN}=== Self-Heal Status ===${RESET}"
  echo ""

  # PID
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo -e "  Daemon:    ${GREEN}RUNNING${RESET} (PID $(cat "$PID_FILE"))"
  else
    echo -e "  Daemon:    ${DIM}not running${RESET}"
  fi

  # Stats
  if [[ -f "$STATS_FILE" ]]; then
    python3 -c "
import json, sys
with open('$STATS_FILE') as f:
    s = json.load(f)
print(f'  Last run:  {s.get(\"last_run\", \"never\")}')
print(f'  Rounds:    {s.get(\"rounds\", 0)}')
print(f'  Fixed:     {s.get(\"total_fixed\", 0)}')
print(f'  Cost:      \${s.get(\"total_cost\", 0):.2f}')
bt = s.get('by_type', {})
if bt:
    print(f'  By type:   {\"  \".join(f\"{k}={v}\" for k,v in sorted(bt.items()))}')
bp = s.get('by_pipeline', {})
if bp:
    print(f'  By pipe:   {\"  \".join(f\"{k}={v}\" for k,v in sorted(bp.items()))}')
" 2>/dev/null || echo "  (stats file unreadable)"
  else
    echo "  No stats recorded yet."
  fi

  echo ""

  # Current Failed CRDs
  local failed_count
  failed_count=$(kubectl get pb -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
failed = [i for i in data['items'] if i.get('status',{}).get('phase') == 'Failed']
print(len(failed))
" 2>/dev/null || echo "?")
  echo -e "  Failed CRDs: ${RED}${failed_count}${RESET}"

  # Quarantined
  local quarantined
  quarantined=$(kubectl get pb -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
q = [i for i in data['items']
     if i['metadata'].get('annotations',{}).get('$QUARANTINE_ANNOTATION') == 'true']
print(len(q))
" 2>/dev/null || echo "0")
  echo -e "  Quarantined: ${MAGENTA}${quarantined}${RESET}"

  # Halt file
  if [[ -f "$HALT_FILE" ]]; then
    echo -e "  Emergency:   ${RED}HALT ACTIVE${RESET}"
  else
    echo -e "  Emergency:   ${GREEN}clear${RESET}"
  fi

  echo ""

  # Recent log entries
  if [[ -f "$LOG_FILE" ]]; then
    echo -e "${BOLD}Recent activity:${RESET}"
    tail -10 "$LOG_FILE" | sed 's/^/  /'
  fi
}

if [[ "$SHOW_STATUS" == "true" ]]; then
  show_status
  exit 0
fi

# ============================================================================
# RETRY TRACKING (file-based, survives restarts)
# ============================================================================
get_heal_attempts() {
  local crd_name="$1"
  local f="$RETRY_TRACKER_DIR/$crd_name"
  [[ -f "$f" ]] && cat "$f" || echo "0"
}

increment_heal_attempts() {
  local crd_name="$1"
  local f="$RETRY_TRACKER_DIR/$crd_name"
  local count
  count=$(get_heal_attempts "$crd_name")
  echo $(( count + 1 )) > "$f"
}

clear_heal_attempts() {
  local crd_name="$1"
  rm -f "$RETRY_TRACKER_DIR/$crd_name"
}

is_quarantined() {
  local crd_name="$1"
  local val
  val=$(kubectl get pb "$crd_name" -n paperclip-v3 \
    -o jsonpath="{.metadata.annotations.self-heal/quarantined}" 2>/dev/null)
  [[ "$val" == "true" ]]
}

quarantine_crd() {
  local crd_name="$1" reason="$2"
  hlog "${RED}QUARANTINE${RESET} $crd_name: $reason"
  kubectl annotate pb "$crd_name" -n paperclip-v3 \
    "$QUARANTINE_ANNOTATION=true" \
    "self-heal/quarantine-reason=$reason" \
    "self-heal/quarantine-time=$(date -Iseconds)" \
    --overwrite 2>/dev/null || true
}

# ============================================================================
# FAILURE CLASSIFICATION
# ============================================================================
classify_failure() {
  local error_msg="$1"

  # Normalize to lowercase for matching
  local lower
  lower=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    *"no build script"*|*"nobuildscript"*|*"no code"*|*"empty repo"*)
      echo "NoBuildScript" ;;
    *"build failed"*|*"build error"*|*"builderror"*|*"compilation"*|*"syntax error"*|*"module not found"*)
      echo "BuildError" ;;
    *"deploy failed"*|*"deploy error"*|*"deployerror"*|*"kubectl"*|*"k8s"*|*"nginx"*)
      echo "DeployError" ;;
    *"push failed"*|*"git push"*|*"pusherror"*|*"not verified on github"*|*"remote.*reject"*)
      echo "PushError" ;;
    *"rate limit"*|*"ratelimit"*|*"429"*|*"overloaded"*|*"too many request"*)
      echo "RateLimitError" ;;
    *"usage cap"*|*"out of extra usage"*|*"usage.*reset"*)
      echo "UsageCap" ;;
    *)
      # Dig deeper: check build log if available
      echo "Unknown" ;;
  esac
}

cost_for_type() {
  case "$1" in
    NoBuildScript)   echo "$COST_NOBUILDSCRIPT" ;;
    BuildError)      echo "$COST_BUILDERROR" ;;
    DeployError)     echo "$COST_DEPLOYERROR" ;;
    PushError)       echo "$COST_PUSHERROR" ;;
    RateLimitError)  echo "0.00" ;;
    *)               echo "0.00" ;;
  esac
}

priority_for_type() {
  case "$1" in
    DeployError)     echo "1" ;;
    PushError)       echo "2" ;;
    BuildError)      echo "3" ;;
    NoBuildScript)   echo "4" ;;
    RateLimitError)  echo "5" ;;
    *)               echo "99" ;;
  esac
}

# ============================================================================
# CIRCUIT BREAKER CHECK
# ============================================================================
check_circuit_breaker() {
  local pipeline="$1"
  local cb_file="$WORKSPACE/.circuit-breaker-state-${pipeline}"
  if [[ -f "$cb_file" ]]; then
    local state
    state=$(cat "$cb_file" 2>/dev/null)
    if [[ "$state" == "open" ]]; then
      return 1
    fi
  fi
  return 0
}

# ============================================================================
# SCAN — Find all Failed CRDs
# ============================================================================
scan_failed_crds() {
  kubectl get pb -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json, sys

data = json.load(sys.stdin)
pipeline_filter = '${PIPELINE_FILTER}'

for item in data.get('items', []):
    status = item.get('status', {})
    phase = status.get('phase', '')
    if phase != 'Failed':
        continue

    spec = item.get('spec', {})
    meta = item.get('metadata', {})
    name = meta.get('name', '')
    pipeline = spec.get('pipeline', '')

    # Pipeline filter
    if pipeline_filter and pipeline != pipeline_filter:
        continue

    # Skip quarantined
    annotations = meta.get('annotations', {})
    if annotations.get('self-heal/quarantined') == 'true':
        continue

    error_msg = status.get('errorMessage', '')
    app_name = spec.get('appName', '')
    app_id = spec.get('appId', 0)
    prefix = spec.get('prefix', '')
    repo = spec.get('repo', '')

    # Output as pipe-delimited record
    print(f'{name}|{app_id}|{prefix}|{repo}|{pipeline}|{error_msg}|{app_name}')
" 2>/dev/null
}

# ============================================================================
# FIX DISPATCH — Execute the appropriate fix for each failure type
# ============================================================================
dispatch_fix() {
  local crd_name="$1" app_id="$2" prefix="$3" repo="$4" pipeline="$5" failure_type="$6" error_msg="$7"

  case "$failure_type" in
    DeployError)
      hlog "  FIX [$prefix] DeployError: resetting to Deploying for deploy retry"
      if [[ "$DRY_RUN" != "true" ]]; then
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Deploying","currentStep":"deploy-retry","errorMessage":""}}' \
          --subresource=status 2>/dev/null
      fi
      ;;

    PushError)
      hlog "  FIX [$prefix] PushError: resetting to Pending for full retry"
      if [[ "$DRY_RUN" != "true" ]]; then
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
          --subresource=status 2>/dev/null
      fi
      ;;

    BuildError)
      hlog "  FIX [$prefix] BuildError: resetting to Pending for build-fix retry"
      if [[ "$DRY_RUN" != "true" ]]; then
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Pending","currentStep":"build-fix-retry","errorMessage":""}}' \
          --subresource=status 2>/dev/null
      fi
      ;;

    NoBuildScript)
      hlog "  FIX [$prefix] NoBuildScript: resetting to Pending for full code generation"
      if [[ "$DRY_RUN" != "true" ]]; then
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
          --subresource=status 2>/dev/null
      fi
      ;;

    RateLimitError)
      hlog "  FIX [$prefix] RateLimitError: resetting to Pending (will back off automatically)"
      if [[ "$DRY_RUN" != "true" ]]; then
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
          --subresource=status 2>/dev/null
      fi
      ;;

    *)
      hlog "  SKIP [$prefix] $failure_type: no automated fix available"
      return 1
      ;;
  esac

  return 0
}

# ============================================================================
# STATS — Track cumulative results
# ============================================================================
update_stats() {
  local fixed_count="$1" round_cost="$2" by_type_json="$3" by_pipeline_json="$4"

  python3 -c "
import json, os, sys

stats_file = '$STATS_FILE'

# Load existing or initialize
if os.path.exists(stats_file):
    with open(stats_file) as f:
        stats = json.load(f)
else:
    stats = {
        'last_run': '',
        'rounds': 0,
        'total_fixed': 0,
        'total_cost': 0.0,
        'by_type': {},
        'by_pipeline': {}
    }

# Update
from datetime import datetime, timezone
stats['last_run'] = datetime.now(timezone.utc).isoformat()
stats['rounds'] = stats.get('rounds', 0) + 1
stats['total_fixed'] = stats.get('total_fixed', 0) + $fixed_count
stats['total_cost'] = round(stats.get('total_cost', 0.0) + $round_cost, 2)

# Merge by_type
round_types = json.loads('''$by_type_json''')
for k, v in round_types.items():
    stats['by_type'][k] = stats['by_type'].get(k, 0) + v

# Merge by_pipeline
round_pipes = json.loads('''$by_pipeline_json''')
for k, v in round_pipes.items():
    stats['by_pipeline'][k] = stats['by_pipeline'].get(k, 0) + v

with open(stats_file, 'w') as f:
    json.dump(stats, f, indent=2)
" 2>/dev/null
}

# ============================================================================
# MAIN HEAL ROUND
# ============================================================================
run_heal_round() {
  local round_start
  round_start=$(date -Iseconds)

  # 1. Check emergency halt
  if [[ -f "$HALT_FILE" ]]; then
    hlog "Emergency halt active ($HALT_FILE) — skipping round"
    return 0
  fi

  # 2. Scan for failed CRDs
  hlog "--- Round start: scanning for Failed CRDs ---"
  local failed_records
  failed_records=$(scan_failed_crds)

  if [[ -z "$failed_records" ]]; then
    hlog "No Failed CRDs found. Nothing to heal."
    return 0
  fi

  local total_failed
  total_failed=$(echo "$failed_records" | wc -l)
  hlog "Found $total_failed Failed CRDs"

  # 3. Classify and sort by priority
  local classified=()
  while IFS='|' read -r crd_name app_id prefix repo pipeline error_msg app_name_field; do
    [[ -z "$crd_name" ]] && continue

    local failure_type
    failure_type=$(classify_failure "$error_msg")

    local priority
    priority=$(priority_for_type "$failure_type")

    local cost
    cost=$(cost_for_type "$failure_type")

    classified+=("${priority}|${failure_type}|${cost}|${crd_name}|${app_id}|${prefix}|${repo}|${pipeline}|${error_msg}")
  done <<< "$failed_records"

  # Sort by priority (field 1)
  local sorted_records
  sorted_records=$(printf '%s\n' "${classified[@]}" | sort -t'|' -k1,1n)

  # 4. Apply fixes within budget and count limits
  local fixes_applied=0
  local round_cost="0.00"
  declare -A type_counts
  declare -A pipeline_counts
  local skipped_usage_cap=0
  local skipped_unknown=0
  local skipped_breaker=0
  local skipped_quarantine=0

  while IFS='|' read -r priority failure_type cost crd_name app_id prefix repo pipeline error_msg; do
    [[ -z "$crd_name" ]] && continue

    # Check emergency halt each iteration
    if [[ -f "$HALT_FILE" ]]; then
      hlog "Emergency halt detected mid-round — stopping"
      break
    fi

    # Skip UsageCap (cannot fix, must wait)
    if [[ "$failure_type" == "UsageCap" ]]; then
      skipped_usage_cap=$((skipped_usage_cap + 1))
      continue
    fi

    # Skip Unknown (log and move on)
    if [[ "$failure_type" == "Unknown" ]]; then
      skipped_unknown=$((skipped_unknown + 1))
      hlog "  SKIP [$prefix] Unknown failure: $(echo "$error_msg" | head -c 100)"
      continue
    fi

    # Max fixes per round
    if (( fixes_applied >= MAX_FIXES )); then
      hlog "Max fixes reached ($MAX_FIXES) — stopping round"
      break
    fi

    # Budget check (using bc for floating point)
    local new_cost
    new_cost=$(echo "$round_cost + $cost" | bc 2>/dev/null || echo "$round_cost")
    local over_budget
    over_budget=$(echo "$new_cost > $MAX_COST" | bc 2>/dev/null || echo "0")
    if [[ "$over_budget" == "1" ]]; then
      hlog "Budget cap reached (\$${round_cost}/\$${MAX_COST}) — stopping round"
      break
    fi

    # Circuit breaker check for this pipeline
    if [[ -n "$pipeline" ]] && ! check_circuit_breaker "$pipeline"; then
      skipped_breaker=$((skipped_breaker + 1))
      continue
    fi

    # Quarantine check: if too many failed attempts, quarantine
    local attempts
    attempts=$(get_heal_attempts "$crd_name")
    if (( attempts >= MAX_QUARANTINE_ATTEMPTS )); then
      if ! is_quarantined "$crd_name"; then
        quarantine_crd "$crd_name" "Failed $attempts consecutive heal attempts"
        skipped_quarantine=$((skipped_quarantine + 1))
      fi
      continue
    fi

    # Dispatch fix
    if dispatch_fix "$crd_name" "$app_id" "$prefix" "$repo" "$pipeline" "$failure_type" "$error_msg"; then
      fixes_applied=$((fixes_applied + 1))
      round_cost="$new_cost"
      increment_heal_attempts "$crd_name"

      # Track by type
      type_counts["$failure_type"]=$(( ${type_counts["$failure_type"]:-0} + 1 ))

      # Track by pipeline
      if [[ -n "$pipeline" ]]; then
        pipeline_counts["$pipeline"]=$(( ${pipeline_counts["$pipeline"]:-0} + 1 ))
      fi

      redis_publish "self_heal" \
        "\"action\":\"fix\",\"app\":\"$prefix\",\"id\":$app_id,\"type\":\"$failure_type\",\"pipeline\":\"$pipeline\""
    fi

  done <<< "$sorted_records"

  # 5. Build JSON objects for stats
  local by_type_json="{}"
  if (( ${#type_counts[@]} > 0 )); then
    by_type_json=$(python3 -c "
import json
d = {}
$(for k in "${!type_counts[@]}"; do echo "d['$k'] = ${type_counts[$k]}"; done)
print(json.dumps(d))
" 2>/dev/null || echo "{}")
  fi

  local by_pipeline_json="{}"
  if (( ${#pipeline_counts[@]} > 0 )); then
    by_pipeline_json=$(python3 -c "
import json
d = {}
$(for k in "${!pipeline_counts[@]}"; do echo "d['$k'] = ${pipeline_counts[$k]}"; done)
print(json.dumps(d))
" 2>/dev/null || echo "{}")
  fi

  # 6. Update persistent stats
  if (( fixes_applied > 0 )) && [[ "$DRY_RUN" != "true" ]]; then
    update_stats "$fixes_applied" "$round_cost" "$by_type_json" "$by_pipeline_json"
  fi

  # 7. Summary
  hlog "--- Round complete ---"
  hlog "  Fixed:           $fixes_applied"
  hlog "  Estimated cost:  \$${round_cost}"
  hlog "  Skipped (cap):   $skipped_usage_cap"
  hlog "  Skipped (unknown): $skipped_unknown"
  hlog "  Skipped (breaker): $skipped_breaker"
  hlog "  Quarantined:     $skipped_quarantine"

  if [[ "$DRY_RUN" == "true" ]]; then
    hlog "  (DRY RUN — no changes applied)"
  fi

  redis_publish "self_heal_round" \
    "\"fixed\":$fixes_applied,\"cost\":$round_cost,\"skipped_cap\":$skipped_usage_cap,\"skipped_unknown\":$skipped_unknown"
}

# ============================================================================
# DAEMON MODE
# ============================================================================
run_daemon() {
  # PID guard
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Self-heal daemon already running (PID $(cat "$PID_FILE"))"
    exit 1
  fi
  echo $$ > "$PID_FILE"
  trap 'rm -f "$PID_FILE"; hlog "Daemon stopped (PID $$)"; exit 0' EXIT INT TERM

  hlog "============================================="
  hlog "Self-heal daemon started (PID $$)"
  hlog "  Interval:    ${INTERVAL}s"
  hlog "  Max fixes:   $MAX_FIXES per round"
  hlog "  Max cost:    \$${MAX_COST} per round"
  hlog "  Pipeline:    ${PIPELINE_FILTER:-all}"
  hlog "  Dry run:     $DRY_RUN"
  hlog "============================================="

  while true; do
    run_heal_round

    # Check if we should stop
    if [[ -f "$HALT_FILE" ]]; then
      hlog "Emergency halt — daemon pausing until halt file removed"
      while [[ -f "$HALT_FILE" ]]; do
        sleep 30
      done
      hlog "Halt file removed — resuming daemon"
    fi

    sleep "$INTERVAL"
  done
}

# ============================================================================
# MAIN
# ============================================================================
if [[ "$DAEMON_MODE" == "true" ]]; then
  run_daemon
else
  run_heal_round
fi
