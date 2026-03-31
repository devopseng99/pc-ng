#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Pipeline Supervisor — Autonomous monitoring + error recovery loop
#
# Checks pipeline status every 30s, diagnoses failures from build logs,
# auto-retries transient errors, and marks unresolvable issues as PendingHITL.
#
# Usage:
#   ./pipeline-supervisor.sh                    # run in foreground
#   ./pipeline-supervisor.sh --interval 60      # custom interval
#   ./pipeline-supervisor.sh --once             # single check, no loop
#   ./pipeline-supervisor.sh --auto-deploy      # also run batch deploy when ready
#   ./pipeline-supervisor.sh --auto-workers     # restart workers when stopped + pending
#
# Error categories & actions:
#   usage-cap     → pause workers, log wait time
#   rate-limit    → reset CRD to Pending (phase-a handles backoff)
#   push-failed   → reset CRD to Pending for retry
#   build-timeout → retry once, then PendingHITL
#   stale-build   → building >20min with no code on GH → reset to Pending
#   deploy-fail   → retry once, then PendingHITL
#   unknown       → PendingHITL immediately
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="/tmp/pc-autopilot"
WORKER_DIR="$WORKSPACE/.workers"
LOG_DIR="$WORKSPACE/logs"
SUPERVISOR_LOG="$WORKER_DIR/supervisor.log"
READY_DIR="$WORKSPACE/.ready-to-deploy"
INTERVAL=30
RUN_ONCE=false
AUTO_DEPLOY=false
AUTO_WORKERS=false
MAX_AUTO_RETRIES=2          # max times supervisor will auto-retry a single app
STALE_BUILD_MINUTES=20      # building for this long with no GH code = stale
DEPLOY_BATCH_SIZE=10        # deploy this many at a time before re-checking

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)      INTERVAL="$2"; shift 2 ;;
    --once)          RUN_ONCE=true; shift ;;
    --auto-deploy)   AUTO_DEPLOY=true; shift ;;
    --auto-workers)  AUTO_WORKERS=true; shift ;;
    --max-retries)   MAX_AUTO_RETRIES="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# Colors
BOLD="\033[1m" DIM="\033[2m" GREEN="\033[32m" RED="\033[31m" YELLOW="\033[33m" CYAN="\033[36m" MAGENTA="\033[35m" RESET="\033[0m"

mkdir -p "$WORKER_DIR" "$LOG_DIR" "$READY_DIR"

# --- Secrets ---
export GH_TOKEN="${GH_TOKEN:-$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d 2>/dev/null || echo '')}"

# --- Redis ---
REDIS_PASS_FILE="/tmp/pc-autopilot/.redis-pass"
_redis_pass() {
  if [[ -f "$REDIS_PASS_FILE" ]]; then cat "$REDIS_PASS_FILE"
  else
    local pass; pass=$(kubectl get secret redis-credentials -n paperclip-v3 -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo '')
    [[ -n "$pass" ]] && { echo "$pass" > "$REDIS_PASS_FILE"; chmod 600 "$REDIS_PASS_FILE"; }
    echo "$pass"
  fi
}
rcli() { kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- redis-cli -a "$(_redis_pass)" --no-auth-warning "$@" 2>/dev/null; }
redis_publish() {
  local type="$1" payload="$2"
  rcli PUBLISH "pipeline:events" "{\"type\":\"${type}\",\"ts\":\"$(date -Iseconds)\",${payload}}" >/dev/null 2>&1 || true
}

# --- Logging ---
slog() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SUPERVISOR] $*"
  echo -e "$msg" | tee -a "$SUPERVISOR_LOG"
}

slog_action() {
  local action="$1" app="$2" detail="$3"
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ACTION] ${action} | ${app} | ${detail}"
  echo -e "$msg" | tee -a "$SUPERVISOR_LOG"
}

# --- Retry tracker (file-based, survives restarts) ---
RETRY_DIR="$WORKSPACE/.supervisor-retries"
mkdir -p "$RETRY_DIR"

get_retry_count() {
  local crd_name="$1"
  local f="$RETRY_DIR/$crd_name"
  [[ -f "$f" ]] && cat "$f" || echo "0"
}

increment_retry() {
  local crd_name="$1"
  local f="$RETRY_DIR/$crd_name"
  local count
  count=$(get_retry_count "$crd_name")
  echo $(( count + 1 )) > "$f"
}

clear_retry() {
  local crd_name="$1"
  rm -f "$RETRY_DIR/$crd_name"
}

# --- GitHub check (git ref API — instant, no lag) ---
repo_has_code() {
  local repo="$1"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/repos/devopseng99/${repo}/git/ref/heads/main" 2>/dev/null)
  [[ "$http_code" == "200" ]]
}

# --- Worker status ---
workers_running() {
  local running=0
  for p in v1 tech; do
    local pf="$WORKER_DIR/${p}.pid"
    if [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null; then
      running=$((running + 1))
    fi
  done
  echo "$running"
}

# --- Detect usage cap from recent logs ---
detect_usage_cap() {
  for p in v1 tech; do
    local lf="$WORKER_DIR/${p}.log"
    [[ -f "$lf" ]] || continue
    # Check last 50 lines for usage cap message
    if tail -50 "$lf" 2>/dev/null | grep -qi "out of extra usage\|usage.*reset"; then
      return 0
    fi
  done
  # Also check recent build logs (last 10 minutes)
  find "$LOG_DIR" -name "*.log" -mmin -10 -print0 2>/dev/null | \
    xargs -0 grep -li "out of extra usage" 2>/dev/null | head -1 | grep -q . && return 0
  return 1
}

# --- Diagnose a failed CRD by reading its build log ---
diagnose_failure() {
  local crd_name="$1" prefix="$2" error_msg="$3"

  # Find the most recent log for this app
  local logfile
  logfile=$(ls -t "$LOG_DIR/${prefix}-"*.log 2>/dev/null | head -1)

  local diagnosis="unknown"
  local detail=""

  # Check error message from CRD first
  case "$error_msg" in
    *"usage"*|*"out of extra"*)
      diagnosis="usage-cap"
      detail="Claude Max usage cap hit"
      ;;
    *"push failed"*|*"not verified on GitHub"*)
      diagnosis="push-failed"
      detail="Git push to GitHub failed"
      ;;
    *"timed out"*|*"Build failed or timed out"*)
      diagnosis="build-timeout"
      detail="Build exceeded timeout"
      ;;
    *"rate"*|*"429"*|*"overloaded"*)
      diagnosis="rate-limit"
      detail="API rate limit hit"
      ;;
  esac

  # If still unknown, dig into the build log
  if [[ "$diagnosis" == "unknown" ]] && [[ -n "$logfile" ]] && [[ -f "$logfile" ]]; then
    local log_tail
    log_tail=$(tail -30 "$logfile" 2>/dev/null)

    if echo "$log_tail" | grep -qi "out of extra usage\|usage.*reset"; then
      diagnosis="usage-cap"
      detail="Usage cap detected in build log"
    elif echo "$log_tail" | grep -qi "rate.limit\|429\|overloaded\|too many"; then
      diagnosis="rate-limit"
      detail="Rate limit detected in build log"
    elif echo "$log_tail" | grep -qi "WATCHDOG.*killing\|stalled"; then
      diagnosis="build-timeout"
      detail="Build stalled (watchdog killed)"
    elif echo "$log_tail" | grep -qi "push.*fail\|remote.*reject\|unable to access"; then
      diagnosis="push-failed"
      detail="Push failure detected in build log"
    elif echo "$log_tail" | grep -qi "SIGTERM\|SIGKILL\|killed\|OOM"; then
      diagnosis="resource-kill"
      detail="Process killed (possibly OOM)"
    elif echo "$log_tail" | grep -qi "error\|Error\|ERROR"; then
      # Extract the first error line as detail
      detail=$(echo "$log_tail" | grep -i "error" | tail -1 | head -c 120)
      diagnosis="build-error"
    fi
  fi

  echo "${diagnosis}|${detail}"
}

# --- Take action based on diagnosis ---
handle_failure() {
  local crd_name="$1" app_id="$2" prefix="$3" repo="$4" diagnosis="$5" detail="$6"

  local retries
  retries=$(get_retry_count "$crd_name")

  case "$diagnosis" in
    usage-cap)
      # Don't retry — pause and wait
      slog_action "PAUSE" "$prefix (#$app_id)" "Usage cap: $detail — waiting for reset"
      # Don't reset to Pending — leave as Failed so workers don't pick it up
      # Will be bulk-reset when cap lifts
      return 0
      ;;

    rate-limit)
      # Always retryable — reset to Pending
      slog_action "RETRY" "$prefix (#$app_id)" "Rate limit (attempt $((retries+1))) — resetting to Pending"
      kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
        -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
        --subresource=status 2>/dev/null
      increment_retry "$crd_name"
      redis_publish "supervisor_action" "\"action\":\"retry\",\"app\":\"$prefix\",\"id\":$app_id,\"reason\":\"rate-limit\""
      ;;

    push-failed)
      if (( retries < MAX_AUTO_RETRIES )); then
        # Check if code actually made it to GitHub despite "failure"
        if repo_has_code "$repo"; then
          slog_action "FIX" "$prefix (#$app_id)" "Push 'failed' but code IS on GitHub — marking Building"
          kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
            -p '{"status":{"phase":"Building","currentStep":"code-pushed","errorMessage":""}}' \
            --subresource=status 2>/dev/null
          clear_retry "$crd_name"
        else
          slog_action "RETRY" "$prefix (#$app_id)" "Push failed, no code on GH (attempt $((retries+1))) — resetting"
          kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
            -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
            --subresource=status 2>/dev/null
          increment_retry "$crd_name"
        fi
      else
        slog_action "HITL" "$prefix (#$app_id)" "Push failed after $retries retries — needs human review"
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p "{\"status\":{\"phase\":\"PendingHITL\",\"currentStep\":\"push-failed\",\"errorMessage\":\"Push failed after $retries retries: $detail\"}}" \
          --subresource=status 2>/dev/null
        redis_publish "supervisor_action" "\"action\":\"hitl\",\"app\":\"$prefix\",\"id\":$app_id,\"reason\":\"push-failed-max-retries\""
      fi
      ;;

    build-timeout|build-error|resource-kill)
      if (( retries < MAX_AUTO_RETRIES )); then
        slog_action "RETRY" "$prefix (#$app_id)" "$diagnosis (attempt $((retries+1))): $detail"
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
          --subresource=status 2>/dev/null
        increment_retry "$crd_name"
        redis_publish "supervisor_action" "\"action\":\"retry\",\"app\":\"$prefix\",\"id\":$app_id,\"reason\":\"$diagnosis\""
      else
        slog_action "HITL" "$prefix (#$app_id)" "$diagnosis after $retries retries: $detail"
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p "{\"status\":{\"phase\":\"PendingHITL\",\"currentStep\":\"$diagnosis\",\"errorMessage\":\"$diagnosis after $retries retries: $(echo "$detail" | head -c 200)\"}}" \
          --subresource=status 2>/dev/null
        redis_publish "supervisor_action" "\"action\":\"hitl\",\"app\":\"$prefix\",\"id\":$app_id,\"reason\":\"$diagnosis-max-retries\""
      fi
      ;;

    unknown|*)
      if (( retries < 1 )); then
        # Give unknown errors one retry
        slog_action "RETRY" "$prefix (#$app_id)" "Unknown error (1st retry): $detail"
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
          --subresource=status 2>/dev/null
        increment_retry "$crd_name"
      else
        slog_action "HITL" "$prefix (#$app_id)" "Unknown error after retry: $detail"
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p "{\"status\":{\"phase\":\"PendingHITL\",\"currentStep\":\"unknown-error\",\"errorMessage\":\"Undiagnosed failure: $(echo "$detail" | head -c 200)\"}}" \
          --subresource=status 2>/dev/null
        redis_publish "supervisor_action" "\"action\":\"hitl\",\"app\":\"$prefix\",\"id\":$app_id,\"reason\":\"unknown\""
      fi
      ;;
  esac
}

# --- Check stale "Building" CRDs (stuck with no code on GitHub) ---
check_stale_builds() {
  local now_epoch
  now_epoch=$(date +%s)

  kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json, sys, datetime
data = json.load(sys.stdin)
for item in data['items']:
    status = item.get('status', {})
    phase = status.get('phase', '')
    if phase != 'Building':
        continue
    spec = item['spec']
    name = item['metadata']['name']
    # Check if it's been building for too long
    started = status.get('startedAt', '')
    if not started:
        continue
    try:
        start_dt = datetime.datetime.fromisoformat(started.replace('Z', '+00:00'))
        age_min = (datetime.datetime.now(datetime.timezone.utc) - start_dt).total_seconds() / 60
        if age_min > ${STALE_BUILD_MINUTES}:
            print(f'{name}|{spec.get(\"appId\",0)}|{spec.get(\"prefix\",\"\")}|{spec.get(\"repo\",\"\")}|{age_min:.0f}')
    except:
        pass
" 2>/dev/null | while IFS='|' read -r crd_name app_id prefix repo age_min; do
    [[ -z "$crd_name" ]] && continue

    if repo_has_code "$repo"; then
      # Code exists — mark as ready, not stale
      slog_action "FIX" "$prefix (#$app_id)" "Building ${age_min}min but code IS on GitHub — updating"
      kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
        -p '{"status":{"phase":"Building","currentStep":"code-pushed","errorMessage":""}}' \
        --subresource=status 2>/dev/null
    else
      local retries
      retries=$(get_retry_count "$crd_name")
      if (( retries < MAX_AUTO_RETRIES )); then
        slog_action "RETRY" "$prefix (#$app_id)" "Stale build (${age_min}min, no code on GH) — resetting"
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p '{"status":{"phase":"Pending","currentStep":"","errorMessage":""}}' \
          --subresource=status 2>/dev/null
        increment_retry "$crd_name"
      else
        slog_action "HITL" "$prefix (#$app_id)" "Stale build ${age_min}min, no code after $retries retries"
        kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge \
          -p "{\"status\":{\"phase\":\"PendingHITL\",\"currentStep\":\"stale-build\",\"errorMessage\":\"Build stale ${age_min}min, no code on GH after $retries retries\"}}" \
          --subresource=status 2>/dev/null
      fi
    fi
  done
}

# --- Print status dashboard ---
print_status() {
  local running
  running=$(workers_running)

  printf "\n${BOLD}${CYAN}═══ Pipeline Supervisor ═══${RESET}  %s\n" "$(date '+%H:%M:%S')"

  # Workers
  printf "${BOLD}Workers:${RESET} "
  for p in v1 tech; do
    local pf="$WORKER_DIR/${p}.pid"
    if [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null; then
      printf "${GREEN}●${RESET}${p} "
    else
      printf "${RED}○${RESET}${p} "
    fi
  done
  echo ""

  # CRD counts
  local status_json
  status_json=$(kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null)

  local deployed building pending failed hitl total
  deployed=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Deployed'))" 2>/dev/null || echo 0)
  building=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Building'))" 2>/dev/null || echo 0)
  pending=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Pending'))" 2>/dev/null || echo 0)
  failed=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Failed'))" 2>/dev/null || echo 0)
  hitl=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='PendingHITL'))" 2>/dev/null || echo 0)
  total=$(echo "$status_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['items']))" 2>/dev/null || echo 0)

  local ready
  ready=$(ls "$READY_DIR"/*.json 2>/dev/null | wc -l)

  printf "${BOLD}CRDs:${RESET} ${GREEN}${deployed}${RESET} deployed | ${CYAN}${building}${RESET} building | ${YELLOW}${pending}${RESET} pending | ${RED}${failed}${RESET} failed"
  if (( hitl > 0 )); then
    printf " | ${MAGENTA}${hitl}${RESET} HITL"
  fi
  printf " | ${DIM}${total} total${RESET}\n"
  printf "${BOLD}Deploy queue:${RESET} ${ready} ready\n"

  # Resources
  local node_stats
  node_stats=$(kubectl top node mgplcb05 --no-headers 2>/dev/null | awk '{print $3, $5}')
  if [[ -n "$node_stats" ]]; then
    printf "${BOLD}Node:${RESET} CPU=%s MEM=%s\n" $(echo "$node_stats")
  fi

  echo "$status_json"  # pass through for further processing
}

# --- Process all Failed CRDs ---
process_failures() {
  local status_json="$1"

  local failures
  failures=$(echo "$status_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    status = item.get('status', {})
    if status.get('phase') == 'Failed':
        spec = item['spec']
        name = item['metadata']['name']
        err = status.get('errorMessage', '')
        print(f'{name}|{spec.get(\"appId\",0)}|{spec.get(\"prefix\",\"\")}|{spec.get(\"repo\",\"\")}|{err}')
" 2>/dev/null)

  [[ -z "$failures" ]] && return 0

  local fail_count=0 retry_count=0 hitl_count=0 cap_count=0

  # Check for usage cap first (affects all failures)
  local is_cap=false
  if detect_usage_cap; then
    is_cap=true
  fi

  while IFS='|' read -r crd_name app_id prefix repo error_msg; do
    [[ -z "$crd_name" ]] && continue
    fail_count=$((fail_count + 1))

    local diag
    diag=$(diagnose_failure "$crd_name" "$prefix" "$error_msg")
    local diagnosis="${diag%%|*}"
    local detail="${diag#*|}"

    # If usage cap is active and diagnosis is usage-cap, just count
    if [[ "$is_cap" == "true" ]] && [[ "$diagnosis" == "usage-cap" ]]; then
      cap_count=$((cap_count + 1))
      continue
    fi

    handle_failure "$crd_name" "$app_id" "$prefix" "$repo" "$diagnosis" "$detail"

    if [[ "$diagnosis" == *"hitl"* ]] || (( $(get_retry_count "$crd_name") > MAX_AUTO_RETRIES )); then
      hitl_count=$((hitl_count + 1))
    else
      retry_count=$((retry_count + 1))
    fi

  done <<< "$failures"

  if (( fail_count > 0 )); then
    slog "Processed $fail_count failures: $retry_count retried, $hitl_count→HITL, $cap_count usage-cap (waiting)"
  fi
}

# --- Auto-deploy ready apps ---
auto_deploy() {
  local ready
  ready=$(ls "$READY_DIR"/*.json 2>/dev/null | wc -l)
  (( ready == 0 )) && return 0

  slog "Auto-deploying $ready ready apps via batch-deploy-k8s.sh..."
  bash "$SCRIPT_DIR/batch-deploy-k8s.sh" >> "$SUPERVISOR_LOG" 2>&1
  local rc=$?
  if (( rc == 0 )); then
    slog "Batch deploy completed successfully"
  else
    slog "Batch deploy exited with rc=$rc — check logs"
  fi
}

# --- Auto-restart workers if stopped but pending work exists ---
auto_restart_workers() {
  local running
  running=$(workers_running)
  (( running > 0 )) && return 0

  # Check if there are Pending CRDs
  local pending
  pending=$(kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json,sys
print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Pending'))
" 2>/dev/null || echo 0)

  (( pending == 0 )) && return 0

  # Don't restart if usage cap is active
  if detect_usage_cap; then
    slog "Workers stopped + $pending pending, but usage cap active — NOT restarting"
    return 0
  fi

  slog "Workers stopped but $pending apps pending — auto-restarting workers"
  bash "$SCRIPT_DIR/workers-start.sh" >> "$SUPERVISOR_LOG" 2>&1
  redis_publish "supervisor_action" "\"action\":\"restart-workers\",\"pending\":$pending"
}

# --- Main supervisor loop ---
main() {
  slog "═══════════════════════════════════════════════"
  slog "Pipeline Supervisor started"
  slog "  Interval: ${INTERVAL}s"
  slog "  Auto-deploy: $AUTO_DEPLOY"
  slog "  Auto-workers: $AUTO_WORKERS"
  slog "  Max retries: $MAX_AUTO_RETRIES"
  slog "  Stale build threshold: ${STALE_BUILD_MINUTES}min"
  slog "═══════════════════════════════════════════════"

  local cycle=0
  while true; do
    cycle=$((cycle + 1))

    # 1. Print status dashboard (also returns status_json)
    local status_output
    status_output=$(print_status)
    # The last line of print_status output to stdout is the JSON
    # But since we're piping... let's just fetch fresh
    local status_json
    status_json=$(kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null)

    # 2. Process failures — diagnose + auto-retry/HITL
    process_failures "$status_json"

    # 3. Check for stale builds (every 3rd cycle to reduce GH API calls)
    if (( cycle % 3 == 0 )); then
      check_stale_builds
    fi

    # 4. Auto-deploy if enabled and ready apps exist
    if [[ "$AUTO_DEPLOY" == "true" ]]; then
      local ready
      ready=$(ls "$READY_DIR"/*.json 2>/dev/null | wc -l)
      if (( ready >= 5 )) || (( cycle % 6 == 0 && ready > 0 )); then
        auto_deploy
      fi
    fi

    # 5. Auto-restart workers if enabled
    if [[ "$AUTO_WORKERS" == "true" ]]; then
      auto_restart_workers
    fi

    # 6. Check completion
    local deployed pending building failed hitl
    deployed=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Deployed'))" 2>/dev/null)
    pending=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Pending'))" 2>/dev/null)
    building=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Building'))" 2>/dev/null)
    failed=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='Failed'))" 2>/dev/null)
    hitl=$(echo "$status_json" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i.get('status',{}).get('phase')=='PendingHITL'))" 2>/dev/null)

    # All done if no pending/building/failed
    if (( pending == 0 && building == 0 && failed == 0 )); then
      slog "ALL CLEAR: $deployed deployed, $hitl need human review, 0 in-flight"
      if (( hitl > 0 )); then
        slog "HITL apps need manual review:"
        echo "$status_json" | python3 -c "
import json, sys
for item in json.load(sys.stdin)['items']:
    s = item.get('status',{})
    if s.get('phase') == 'PendingHITL':
        sp = item['spec']
        print(f'  #{sp[\"appId\"]} {sp[\"prefix\"]} — {s.get(\"errorMessage\",\"?\")[:80]}')
" 2>/dev/null | tee -a "$SUPERVISOR_LOG"
      fi
      [[ "$RUN_ONCE" == "true" ]] && break
    fi

    [[ "$RUN_ONCE" == "true" ]] && break

    sleep "$INTERVAL"
  done

  slog "Supervisor exiting"
}

main
