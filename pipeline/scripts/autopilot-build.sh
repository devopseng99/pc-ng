#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PC Autopilot — Automated app pipeline: onboard → build → deploy
# v3: Redis pub/sub, circuit breaker, validation gate, remediation, queue mode
#
# Usage:
#   ./autopilot-build.sh --manifest <file.json> --id <N>
#   ./autopilot-build.sh --manifest <file.json> --range <start>-<end>
#   ./autopilot-build.sh --manifest <file.json> --all [--concurrency 2] [--pipeline-id v1]
#   ./autopilot-build.sh --retry-failed
#   ./autopilot-build.sh --queue-mode --enqueue --manifest <file.json> --pipeline-id v1
#   ./autopilot-build.sh --queue-mode --worker --concurrency 2 --pipeline-id v1
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
REGISTRY="$ROOT_DIR/registry/deployed.json"
LOCKFILE="$ROOT_DIR/.registry.lock"
LOG_DIR="$ROOT_DIR/logs"
PC_DIR="/var/lib/rancher/ansible/db/pc"
STATUS_FILE="$ROOT_DIR/.pipeline-status"

CONCURRENCY=2
MANIFEST=""
TARGET_ID=""
RANGE_START=""
RANGE_END=""
BUILD_ALL=false
RETRY_FAILED=false
DRY_RUN=false
SKIP_ONBOARD=false
SKIP_BUILD=false
SKIP_DEPLOY=false
MIN_DISK_MB=800
PIPELINE_ID="v1"
QUEUE_MODE=false
QUEUE_ENQUEUE=false
QUEUE_WORKER=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)    MANIFEST="$2"; shift 2 ;;
    --id)          TARGET_ID="$2"; shift 2 ;;
    --range)       IFS='-' read -r RANGE_START RANGE_END <<< "$2"; shift 2 ;;
    --all)         BUILD_ALL=true; shift ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --retry-failed) RETRY_FAILED=true; shift ;;
    --skip-onboard) SKIP_ONBOARD=true; shift ;;
    --skip-build)   SKIP_BUILD=true; shift ;;
    --skip-deploy)  SKIP_DEPLOY=true; shift ;;
    --pipeline-id)  PIPELINE_ID="$2"; shift 2 ;;
    --queue-mode)   QUEUE_MODE=true; shift ;;
    --enqueue)      QUEUE_ENQUEUE=true; shift ;;
    --worker)       QUEUE_WORKER=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Load secrets ---
export GH_TOKEN="${GH_TOKEN:-$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)}"
export BOARD_API_KEY="${BOARD_API_KEY:-$(kubectl get secret pc-board-api-key -n paperclip -o jsonpath='{.data.key}' | base64 -d)}"
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(kubectl get secret cloudflare-api-keys -n paperclip -o jsonpath='{.data.CLOUDFLARE_API_TOKEN}' | base64 -d)}"
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$(kubectl get secret cloudflare-api-keys -n paperclip -o jsonpath='{.data.CLOUDFLARE_ACCOUNT_ID}' | base64 -d)}"

# --- Helpers ---
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_app() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

# ==========================================================================
# Phase 3: Redis integration helpers
# ==========================================================================

# Redis CLI wrapper — all Redis ops go through kubectl exec
REDIS_PASS_FILE="/tmp/pc-autopilot/.redis-pass"
_redis_pass() {
  if [[ -f "$REDIS_PASS_FILE" ]]; then
    cat "$REDIS_PASS_FILE"
  else
    local pass
    pass=$(kubectl get secret redis-credentials -n paperclip-v3 -o jsonpath='{.data.password}' | base64 -d)
    echo "$pass" > "$REDIS_PASS_FILE"
    chmod 600 "$REDIS_PASS_FILE"
    echo "$pass"
  fi
}

rcli() {
  kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- \
    redis-cli -a "$(_redis_pass)" --no-auth-warning "$@" 2>/dev/null
}

# --- Phase 3a: Redis pub/sub event publishing ---
EVENTS_CHANNEL="pipeline:events"

redis_publish() {
  local event_type="$1" payload="$2"
  local msg="{\"type\":\"${event_type}\",\"pipeline\":\"${PIPELINE_ID}\",\"ts\":\"$(date -Iseconds)\",${payload}}"
  rcli PUBLISH "$EVENTS_CHANNEL" "$msg" >/dev/null 2>&1 || true
}

# --- Phase 3b: Deploy validation gate ---
validate_deploy() {
  local url="$1" prefix="$2" retries=3 delay=10
  for attempt in $(seq 1 $retries); do
    local http_code
    http_code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^(200|301|302|304)$ ]]; then
      log_app "$prefix" "Deploy validated: HTTP $http_code (attempt $attempt)"
      return 0
    fi
    log_app "$prefix" "Deploy check attempt $attempt/$retries: HTTP $http_code"
    (( attempt < retries )) && sleep $delay
  done
  log_app "$prefix" "Deploy validation FAILED after $retries attempts"
  return 1
}

# --- Phase 3c: Circuit breaker ---
CB_MAX_STREAK=5       # pause after 5 consecutive failures
CB_BASE_DELAY=60      # initial backoff seconds
CB_MAX_DELAY=300      # cap at 5 minutes

circuit_breaker_check() {
  local streak_file="$ROOT_DIR/.control/${PIPELINE_ID}.fail_streak"
  local streak=0
  [[ -f "$streak_file" ]] && streak=$(cat "$streak_file" 2>/dev/null)
  [[ ! "$streak" =~ ^[0-9]+$ ]] && streak=0

  if (( streak >= CB_MAX_STREAK )); then
    # Exponential backoff: 60, 120, 240, 300(cap)
    local delay=$(( CB_BASE_DELAY * (2 ** (streak - CB_MAX_STREAK)) ))
    (( delay > CB_MAX_DELAY )) && delay=$CB_MAX_DELAY
    log "CIRCUIT BREAKER: $streak consecutive failures — cooling off ${delay}s"
    redis_publish "circuit_breaker" "\"streak\":$streak,\"delay\":$delay"
    sleep $delay
  fi
}

circuit_breaker_record_failure() {
  local streak_file="$ROOT_DIR/.control/${PIPELINE_ID}.fail_streak"
  local streak=0
  [[ -f "$streak_file" ]] && streak=$(cat "$streak_file" 2>/dev/null)
  [[ ! "$streak" =~ ^[0-9]+$ ]] && streak=0
  echo $(( streak + 1 )) > "$streak_file"
}

circuit_breaker_reset() {
  local streak_file="$ROOT_DIR/.control/${PIPELINE_ID}.fail_streak"
  echo 0 > "$streak_file"
}

# --- Phase 3d: Remediation queue ---
remediation_loop() {
  log "=== Entering remediation sweep ==="
  local remediated=0

  # 1. Deploy orphaned builds (built but never deployed — out/ exists in /tmp)
  local orphans
  orphans=$(python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('status') == 'build_failed' and a.get('repo'):
        print(a['repo'])
" 2>/dev/null || true)

  for repo in $orphans; do
    if [[ -d "/tmp/$repo/out" ]] || [[ -d "/tmp/$repo/dist" ]] || [[ -d "/tmp/$repo/.next" ]]; then
      log "Remediation: deploying orphaned build /tmp/$repo"
      if "$SCRIPT_DIR/deploy-cf.sh" --repo "$repo" --name "$repo" 2>/dev/null; then
        local url="https://${repo}.pages.dev"
        # Update registry status
        python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('repo') == '$repo':
        a['status'] = 'deployed'
        a['url'] = '$url'
        break
with open('$REGISTRY', 'w') as f: json.dump(data, f, indent=2)
" 2>/dev/null
        remediated=$((remediated + 1))
        log "Remediation: $repo → deployed"
      fi
    fi
  done

  # 2. Retry deploy_failed apps
  local deploy_failed
  deploy_failed=$(python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('status') == 'deploy_failed':
        print(json.dumps(a))
" 2>/dev/null || true)

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local repo prefix
    repo=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['repo'])")
    prefix=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['prefix'])")
    log "Remediation: retrying deploy for $prefix ($repo)"
    if "$SCRIPT_DIR/deploy-cf.sh" --repo "$repo" --name "$repo" 2>/dev/null; then
      local url="https://${repo}.pages.dev"
      if validate_deploy "$url" "$prefix"; then
        python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('repo') == '$repo':
        a['status'] = 'deployed'
        a['url'] = '$url'
        break
with open('$REGISTRY', 'w') as f: json.dump(data, f, indent=2)
" 2>/dev/null
        remediated=$((remediated + 1))
      fi
    fi
  done <<< "$deploy_failed"

  # 3. Spot-check a sample of deployed URLs
  local sample
  sample=$(python3 -c "
import json, random
with open('$REGISTRY') as f: data = json.load(f)
deployed = [a for a in data.get('apps', []) if a.get('status') == 'deployed' and a.get('url')]
for a in random.sample(deployed, min(5, len(deployed))):
    print(a['prefix'] + ' ' + a['url'])
" 2>/dev/null || true)

  while IFS=' ' read -r prefix url; do
    [[ -z "$prefix" ]] && continue
    if ! validate_deploy "$url" "$prefix"; then
      log "Remediation: $prefix ($url) returning errors — marking deploy_unverified"
      python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('prefix') == '$prefix':
        a['status'] = 'deploy_unverified'
        break
with open('$REGISTRY', 'w') as f: json.dump(data, f, indent=2)
" 2>/dev/null
    fi
  done <<< "$sample"

  # 4. Re-validate deploy_unverified
  local unverified
  unverified=$(python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('status') == 'deploy_unverified' and a.get('url'):
        print(a['prefix'] + ' ' + a['url'])
" 2>/dev/null || true)

  while IFS=' ' read -r prefix url; do
    [[ -z "$prefix" ]] && continue
    if validate_deploy "$url" "$prefix"; then
      log "Remediation: $prefix re-validated OK → deployed"
      python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('prefix') == '$prefix':
        a['status'] = 'deployed'
        break
with open('$REGISTRY', 'w') as f: json.dump(data, f, indent=2)
" 2>/dev/null
      remediated=$((remediated + 1))
    fi
  done <<< "$unverified"

  log "=== Remediation complete: $remediated apps healed ==="
  redis_publish "remediation_complete" "\"healed\":$remediated"
}

# --- Phase 3e: Redis sorted set priority queue ---
QUEUE_KEY="${PIPELINE_ID}:builds"

queue_enqueue_manifest() {
  local manifest="$1"
  log "Enqueuing apps from $manifest into Redis queue $QUEUE_KEY..."
  local count=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local id priority
    id=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    priority=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('priority', 5))")

    # Skip already deployed
    if is_deployed "$id"; then continue; fi

    # ZADD queue with priority as score (lower = higher priority)
    rcli ZADD "$QUEUE_KEY" NX "$priority" "$entry" >/dev/null
    count=$((count + 1))
  done < <(get_entries "$manifest")
  log "Enqueued $count apps into $QUEUE_KEY"
  redis_publish "queue_enqueued" "\"count\":$count,\"queue\":\"$QUEUE_KEY\""
}

queue_dequeue() {
  # ZPOPMIN returns the entry with the lowest score (highest priority)
  local result
  result=$(rcli ZPOPMIN "$QUEUE_KEY" 1 2>/dev/null)
  # result format: entry\nscore  — we want just the entry (first line)
  echo "$result" | head -1
}

queue_length() {
  rcli ZCARD "$QUEUE_KEY" 2>/dev/null
}

queue_worker_loop() {
  log "Starting queue worker for $QUEUE_KEY (concurrency=$CONCURRENCY)..."
  local completed=0 failed=0
  local job_pids=() job_names=()

  while true; do
    reload_concurrency
    circuit_breaker_check

    # Reap finished jobs
    local new_pids=() new_names=()
    for idx in "${!job_pids[@]}"; do
      if ! kill -0 "${job_pids[$idx]}" 2>/dev/null; then
        wait "${job_pids[$idx]}" 2>/dev/null && true
        local exit_code=$?
        local finished_name=${job_names[$idx]}
        if [[ $exit_code -eq 0 ]]; then
          completed=$((completed + 1))
          circuit_breaker_reset
          redis_publish "build_complete" "\"app\":\"$finished_name\",\"status\":\"success\""
          log "[$finished_name] DONE (completed=$completed, failed=$failed)"
        else
          failed=$((failed + 1))
          circuit_breaker_record_failure
          redis_publish "build_complete" "\"app\":\"$finished_name\",\"status\":\"failed\""
          log "[$finished_name] FAILED (completed=$completed, failed=$failed)"
        fi
      else
        new_pids+=("${job_pids[$idx]}")
        new_names+=("${job_names[$idx]}")
      fi
    done
    job_pids=("${new_pids[@]+"${new_pids[@]}"}")
    job_names=("${new_names[@]+"${new_names[@]}"}")

    # Fill available slots
    while (( ${#job_pids[@]} < CONCURRENCY )); do
      local entry
      entry=$(queue_dequeue)
      if [[ -z "$entry" ]] || [[ "$entry" == "(empty"* ]]; then
        # Queue empty — run remediation if no jobs running
        if (( ${#job_pids[@]} == 0 )); then
          remediation_loop
          log "Queue empty, worker idle. Checking again in 30s..."
          sleep 30
        fi
        break
      fi

      local entry_prefix
      entry_prefix=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['prefix'])" 2>/dev/null || echo "???")

      log_app "$entry_prefix" "Dequeued from $QUEUE_KEY — launching build..."
      redis_publish "build_start" "\"app\":\"$entry_prefix\""
      process_app "$entry" &
      job_pids+=($!)
      job_names+=("$entry_prefix")
    done

    # If jobs are running, short sleep before checking again
    if (( ${#job_pids[@]} > 0 )); then
      sleep 3
    fi
  done
}

ensure_registry() {
  [[ -f "$REGISTRY" ]] || echo '{"apps":[]}' > "$REGISTRY"
}

# File-locked registry write — prevents race conditions between concurrent builds
register_app() {
  local id="$1" name="$2" prefix="$3" repo="$4" url="$5" company_id="$6" status="$7"
  ensure_registry
  (
    flock -w 30 200 || { log_app "$prefix" "WARN: Could not acquire registry lock"; return 1; }
    python3 -c "
import json, sys
entry = {
  'id': $id, 'name': '''$name''', 'prefix': '$prefix',
  'repo': '$repo', 'url': '$url', 'company_id': '$company_id',
  'status': '$status', 'deployed_at': '$(date +%Y-%m-%d)'
}
with open('$REGISTRY') as f: data = json.load(f)
apps = data.get('apps', [])
updated = False
for i, a in enumerate(apps):
    if a.get('id') == $id:
        apps[i] = entry
        updated = True
        break
if not updated:
    apps.append(entry)
data['apps'] = sorted(apps, key=lambda x: x['id'])
with open('$REGISTRY', 'w') as f: json.dump(data, f, indent=2)
print(f'Registry: {\"updated\" if updated else \"added\"} [{entry[\"prefix\"]}] {entry[\"name\"]} → {entry[\"status\"]}')
"
  ) 200>"$LOCKFILE"
}

# Check if app is already deployed — enables safe re-runs
is_deployed() {
  local id="$1"
  [[ ! -f "$REGISTRY" ]] && return 1
  python3 -c "
import json, sys
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps', []):
    if a.get('id') == $id and a.get('status') == 'deployed':
        sys.exit(0)
sys.exit(1)
"
}

# Check available disk space on /tmp before building
check_disk_space() {
  local avail_mb
  avail_mb=$(df -BM /tmp --output=avail | tail -1 | tr -d ' M')
  if (( avail_mb < MIN_DISK_MB )); then
    log "WARN: Only ${avail_mb}MB free on /tmp (need ${MIN_DISK_MB}MB). Cleaning orphans..."
    # Clean any stale build dirs older than 30 min
    find /tmp -maxdepth 1 -type d -name '*-*' -mmin +30 -exec rm -rf {} + 2>/dev/null || true
    avail_mb=$(df -BM /tmp --output=avail | tail -1 | tr -d ' M')
    if (( avail_mb < MIN_DISK_MB )); then
      log "ERROR: Still only ${avail_mb}MB free. Cannot proceed."
      return 1
    fi
    log "Cleaned up. Now ${avail_mb}MB free."
  fi
  return 0
}

# Update pipeline status file for monitoring
update_status() {
  local completed="$1" total="$2" current="$3"
  echo "{\"completed\":$completed,\"total\":$total,\"current\":\"$current\",\"pipeline\":\"$PIPELINE_ID\",\"concurrency\":$CONCURRENCY,\"updated\":\"$(date -Iseconds)\"}" > "$STATUS_FILE"
}

# Hot-reload concurrency and check pause state from control files
reload_concurrency() {
  local ctl_file="$ROOT_DIR/.control/${PIPELINE_ID}.concurrency"
  if [[ -f "$ctl_file" ]]; then
    local new_val
    new_val=$(cat "$ctl_file" 2>/dev/null)
    if [[ "$new_val" =~ ^[0-9]+$ ]] && (( new_val >= 1 && new_val <= 10 )); then
      if (( new_val != CONCURRENCY )); then
        log "Concurrency changed: $CONCURRENCY → $new_val (pipeline=$PIPELINE_ID)"
        CONCURRENCY=$new_val
      fi
    fi
  fi
  local pause_file="$ROOT_DIR/.control/${PIPELINE_ID}.paused"
  while [[ -f "$pause_file" ]] && [[ "$(cat "$pause_file" 2>/dev/null)" == "true" ]]; do
    log "Pipeline $PIPELINE_ID PAUSED — waiting..."
    sleep 30
  done
}

# Create or update PaperclipBuild CRD status — fire-and-forget, non-blocking
update_crd_status() {
  local id="$1" prefix="$2" phase="$3" stage="${4:-}" extra_json="${5:-}"
  local cr_name="pb-${id}-$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"

  kubectl patch paperclipbuild "$cr_name" \
    -n paperclip-v3 \
    --type merge \
    -p "{\"status\":{\"phase\":\"$phase\"${stage:+,\"stage\":\"$stage\"}${extra_json:+,$extra_json}}}" \
    2>/dev/null &
}

# Create initial PaperclipBuild CR for an app entering the pipeline
create_crd_entry() {
  local id="$1" name="$2" prefix="$3" repo="$4" category="${5:-Misc}"
  local cr_name="pb-${id}-$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"

  kubectl apply -f - 2>/dev/null <<EOF &
apiVersion: paperclip.istayintek.com/v1alpha1
kind: PaperclipBuild
metadata:
  name: $cr_name
  namespace: paperclip-v3
  labels:
    pipeline: "$PIPELINE_ID"
    app-id: "$id"
spec:
  appId: $id
  appName: "$name"
  prefix: "$prefix"
  category: "$category"
  pipeline: "$PIPELINE_ID"
  repo: "$repo"
  priority: 5
EOF
}

# --- Extract entries from manifest ---
get_entries() {
  local manifest="$1"
  if [[ -n "$TARGET_ID" ]]; then
    python3 -c "
import json
with open('$manifest') as f: data = json.load(f)
entries = data if isinstance(data, list) else data.get('use_cases', [])
for e in entries:
    if e['id'] == $TARGET_ID:
        print(json.dumps(e))
"
  elif [[ -n "$RANGE_START" ]]; then
    python3 -c "
import json
with open('$manifest') as f: data = json.load(f)
entries = data if isinstance(data, list) else data.get('use_cases', [])
for e in entries:
    if $RANGE_START <= e['id'] <= $RANGE_END:
        print(json.dumps(e))
"
  elif [[ "$BUILD_ALL" == "true" ]]; then
    python3 -c "
import json
with open('$manifest') as f: data = json.load(f)
entries = data if isinstance(data, list) else data.get('use_cases', [])
for e in entries:
    print(json.dumps(e))
"
  fi
}

# --- Pipeline: single app ---
process_app() {
  local entry="$1"
  local id name prefix type repo budget description features design_bg design_primary design_vibe email category

  # Parse all fields in one python call (faster than 12 separate calls)
  eval "$(echo "$entry" | python3 -c "
import json, sys, shlex
e = json.load(sys.stdin)
print(f'id={e[\"id\"]}')
print(f'name={shlex.quote(e[\"name\"])}')
print(f'prefix={shlex.quote(e[\"prefix\"])}')
print(f'type={shlex.quote(e[\"type\"])}')
print(f'repo={shlex.quote(e[\"repo\"])}')
print(f'budget={e[\"budget\"]}')
print(f'description={shlex.quote(e[\"description\"])}')
print(f'features={shlex.quote(\", \".join(e.get(\"features\", [])))}')
print(f'design_bg={shlex.quote(e.get(\"design\", {}).get(\"bg\", \"#FFFFFF\"))}')
print(f'design_primary={shlex.quote(e.get(\"design\", {}).get(\"primary\", \"#3B82F6\"))}')
print(f'design_vibe={shlex.quote(e.get(\"design\", {}).get(\"vibe\", \"Professional and modern\"))}')
print(f'email={shlex.quote(e.get(\"email\", f\"client@{e[chr(114)+chr(101)+chr(112)+chr(111)]}.com\"))}')
print(f'category={shlex.quote(e.get(\"category\", \"Misc Services\"))}')
")"

  create_crd_entry "$id" "$name" "$prefix" "$repo" "$category"

  # Skip if already deployed
  if is_deployed "$id"; then
    log_app "$prefix" "SKIP: Already deployed (id=$id)"
    return 0
  fi

  # Check disk space
  if ! check_disk_space; then
    log_app "$prefix" "ABORT: Insufficient disk space"
    register_app "$id" "$name" "$prefix" "$repo" "" "unknown" "disk_full"
    return 1
  fi

  local logfile="$LOG_DIR/${prefix}-$(date '+%Y%m%d-%H%M%S').log"
  log_app "$prefix" "Starting pipeline for: $name (id=$id, category=$category)"

  # Step 1: Create GitHub repo
  log_app "$prefix" "Creating GitHub repo: devopseng99/$repo"
  gh repo create "devopseng99/$repo" --public --description "$name — $description" 2>&1 || true

  local company_id="unknown"

  if [[ "$SKIP_ONBOARD" != "true" ]]; then
    # Step 2: Onboard
    update_crd_status "$id" "$prefix" "Onboarding" "onboarding"
    log_app "$prefix" "Onboarding..."
    company_id=$("$PC_DIR/client-onboarding/scripts/onboard-full.sh" \
      --name "$name" \
      --prefix "$prefix" \
      --email "$email" \
      --budget "$budget" \
      --business-type "$type" \
      --repo "https://github.com/devopseng99/$repo" 2>&1 | \
      grep -oP 'company_id[=:]\s*\K[a-f0-9-]+' | head -1 || echo "unknown")

    # Step 3: Move issues to todo
    log_app "$prefix" "Moving issues to todo..."
    if [[ "$company_id" != "unknown" ]]; then
      local issue_ids
      issue_ids=$(kubectl exec -n paperclip deploy/pc -- curl -s \
        -H "Authorization: Bearer $BOARD_API_KEY" \
        "http://localhost:3100/api/companies/$company_id/issues?limit=15" | \
        python3 -c "
import json,sys
data = json.load(sys.stdin)
issues = data if isinstance(data, list) else data.get('issues', data.get('data', []))
for i in issues:
    if i.get('status') == 'backlog': print(i['id'])
" 2>/dev/null)
      for iid in $issue_ids; do
        kubectl exec -n paperclip deploy/pc -- curl -s -X PATCH \
          -H "Authorization: Bearer $BOARD_API_KEY" \
          -H "Content-Type: application/json" \
          -d '{"status":"todo"}' \
          "http://localhost:3100/api/issues/$iid" > /dev/null 2>&1
        sleep 1
      done
    fi
  fi

  if [[ "$SKIP_BUILD" != "true" ]]; then
    # Step 4: Generate category-aware build prompt
    log_app "$prefix" "Generating build prompt (category=$category)..."
    local prompt
    prompt=$("$SCRIPT_DIR/generate-prompt.sh" \
      --name "$name" \
      --type "$type" \
      --repo "$repo" \
      --description "$description" \
      --features "$features" \
      --bg "$design_bg" \
      --primary "$design_primary" \
      --vibe "$design_vibe" \
      --category "$category")

    # Step 5: Build via Claude Code (15-min timeout, post-crash recovery)
    update_crd_status "$id" "$prefix" "Building" "ai-codegen"
    log_app "$prefix" "Building app via Claude Code..."
    echo "[$(date -Iseconds)] Build started: $name (id=$id, category=$category, pipeline=$PIPELINE_ID)" > "$logfile"
    if ! echo "$prompt" | timeout 900 claude --dangerously-skip-permissions -p - >> "$logfile" 2>&1; then
      # Post-crash recovery: check if output was actually built despite process failure
      if [[ -f "/tmp/$repo/out/index.html" ]] || [[ -f "/tmp/$repo/dist/index.html" ]] || [[ -f "/tmp/$repo/.next/server/app/page.js" ]]; then
        log_app "$prefix" "Build process failed/timed out but output exists — continuing to deploy"
        echo "[$(date -Iseconds)] Build process exited non-zero but output detected — recovering" >> "$logfile"
      else
        log_app "$prefix" "BUILD FAILED — see $logfile"
        update_crd_status "$id" "$prefix" "Failed" "ai-codegen" "\"errorMessage\":\"Build failed\""
        register_app "$id" "$name" "$prefix" "$repo" "" "$company_id" "build_failed"
        return 1
      fi
    fi
    log_app "$prefix" "Build succeeded"
  fi

  if [[ "$SKIP_DEPLOY" != "true" ]]; then
    # Step 6: Deploy to Cloudflare Pages
    update_crd_status "$id" "$prefix" "Deploying" "cloudflare-deploy"
    log_app "$prefix" "Deploying to CF Pages..."
    if ! "$SCRIPT_DIR/deploy-cf.sh" --repo "$repo" --name "$repo" 2>&1 | tee -a "$logfile"; then
      log_app "$prefix" "DEPLOY FAILED — see $logfile"
      update_crd_status "$id" "$prefix" "Failed" "cloudflare-deploy" "\"errorMessage\":\"Deploy failed\""
      register_app "$id" "$name" "$prefix" "$repo" "" "$company_id" "deploy_failed"
      return 1
    fi

    local url="https://${repo}.pages.dev"

    # Step 6b: Validate deploy (Phase 3b)
    if validate_deploy "$url" "$prefix"; then
      update_crd_status "$id" "$prefix" "Deployed" "cloudflare-deploy" "\"deployUrl\":\"$url\",\"completedAt\":\"$(date -Iseconds)\""
      register_app "$id" "$name" "$prefix" "$repo" "$url" "$company_id" "deployed"
      log_app "$prefix" "DEPLOYED & VERIFIED: $url"
      redis_publish "app_deployed" "\"app\":\"$prefix\",\"id\":$id,\"url\":\"$url\""
    else
      update_crd_status "$id" "$prefix" "DeployUnverified" "cloudflare-deploy" "\"deployUrl\":\"$url\",\"completedAt\":\"$(date -Iseconds)\""
      register_app "$id" "$name" "$prefix" "$repo" "$url" "$company_id" "deploy_unverified"
      log_app "$prefix" "DEPLOYED but UNVERIFIED: $url (will retry in remediation)"
      redis_publish "app_deploy_unverified" "\"app\":\"$prefix\",\"id\":$id,\"url\":\"$url\""
    fi
  fi

  # Step 7: Cleanup build artifacts
  rm -rf "/tmp/$repo" 2>/dev/null
  log_app "$prefix" "Pipeline complete — cleaned /tmp/$repo"
}

# --- Main ---
main() {
  ensure_registry
  mkdir -p "$LOG_DIR" "$ROOT_DIR/.control"

  # PID guard — prevent double-launch of the same pipeline
  PIDFILE="$ROOT_DIR/.pid-${PIPELINE_ID}"
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "ERROR: Pipeline $PIPELINE_ID already running (PID $(cat "$PIDFILE"))"
    exit 1
  fi
  echo $$ > "$PIDFILE"
  trap "rm -f '$PIDFILE'" EXIT

  # Seed control file with initial concurrency (if not already set)
  local ctl_file="$ROOT_DIR/.control/${PIPELINE_ID}.concurrency"
  if [[ ! -f "$ctl_file" ]]; then
    echo "$CONCURRENCY" > "$ctl_file"
  fi

  if [[ "$RETRY_FAILED" == "true" ]]; then
    log "Retrying failed builds from registry..."
    python3 -c "
import json
with open('$REGISTRY') as f: data = json.load(f)
for a in data.get('apps',[]):
    if a.get('status') in ('build_failed','deploy_failed','deploy_unverified','disk_full'):
        print(json.dumps(a))
" | while read -r entry; do
      process_app "$entry"
    done
    return
  fi

  # --- Queue mode (Phase 3e) ---
  if [[ "$QUEUE_MODE" == "true" ]]; then
    if [[ "$QUEUE_ENQUEUE" == "true" ]]; then
      [[ -z "$MANIFEST" ]] && { echo "Error: --manifest required for --enqueue"; exit 1; }
      queue_enqueue_manifest "$MANIFEST"
      return
    elif [[ "$QUEUE_WORKER" == "true" ]]; then
      queue_worker_loop
      return
    else
      echo "Error: --queue-mode requires --enqueue or --worker"
      exit 1
    fi
  fi

  [[ -z "$MANIFEST" ]] && { echo "Error: --manifest required"; exit 1; }

  local entries=()
  while IFS= read -r line; do
    entries+=("$line")
  done < <(get_entries "$MANIFEST")

  local total=${#entries[@]}
  log "Processing $total apps (concurrency=$CONCURRENCY)"

  if [[ "$DRY_RUN" == "true" ]]; then
    for entry in "${entries[@]}"; do
      local entry_id
      entry_id=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
      local skip_marker=""
      if is_deployed "$entry_id"; then
        skip_marker=" [SKIP: already deployed]"
      fi
      echo "$entry" | python3 -c "import json,sys; e=json.load(sys.stdin); print(f'  [{e[\"id\"]}] {e[\"name\"]} ({e[\"prefix\"]}) → {e[\"repo\"]}  [{e.get(\"category\",\"?\")}]')"
      [[ -n "$skip_marker" ]] && echo "        $skip_marker"
    done
    return
  fi

  # --- Concurrency pool: always keep $CONCURRENCY jobs running ---
  local completed=0
  local failed=0
  local skipped=0
  local job_pids=()    # array of PIDs
  local job_names=()   # array of prefix names (parallel to PIDs)

  log "Starting pipeline with max $CONCURRENCY concurrent builds..."
  update_status 0 "$total" "starting"

  # Helper: reap finished jobs from pool
  reap_finished_jobs() {
    local new_pids=() new_names=()
    for idx in "${!job_pids[@]}"; do
      if ! kill -0 "${job_pids[$idx]}" 2>/dev/null; then
        wait "${job_pids[$idx]}" 2>/dev/null && true
        local exit_code=$?
        local finished_name=${job_names[$idx]}

        if [[ $exit_code -eq 0 ]]; then
          completed=$((completed + 1))
          circuit_breaker_reset
          redis_publish "build_complete" "\"app\":\"$finished_name\",\"status\":\"success\""
          log "[$finished_name] DONE ($completed/$total completed, $failed failed)"
        else
          failed=$((failed + 1))
          circuit_breaker_record_failure
          redis_publish "build_complete" "\"app\":\"$finished_name\",\"status\":\"failed\""
          log "[$finished_name] FAILED ($completed/$total completed, $failed failed)"
        fi
        update_status "$completed" "$total" "$finished_name done"
      else
        new_pids+=("${job_pids[$idx]}")
        new_names+=("${job_names[$idx]}")
      fi
    done
    job_pids=("${new_pids[@]+"${new_pids[@]}"}")
    job_names=("${new_names[@]+"${new_names[@]}"}")
  }

  for entry in "${entries[@]}"; do
    # Hot-reload concurrency and check pause state
    reload_concurrency
    # Circuit breaker check before launching new builds
    circuit_breaker_check

    # If at capacity, wait for a slot to free up
    while (( ${#job_pids[@]} >= CONCURRENCY )); do
      reap_finished_jobs
      # If still at capacity, short sleep
      if (( ${#job_pids[@]} >= CONCURRENCY )); then
        sleep 3
        reload_concurrency
      fi
    done

    # Extract prefix for logging
    local entry_prefix
    entry_prefix=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['prefix'])")

    # Check if already deployed before spawning
    local entry_id
    entry_id=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    if is_deployed "$entry_id"; then
      log_app "$entry_prefix" "SKIP: Already deployed"
      skipped=$((skipped + 1))
      continue
    fi

    # Launch job in background
    log_app "$entry_prefix" "Launching build slot..."
    redis_publish "build_start" "\"app\":\"$entry_prefix\",\"id\":$entry_id"
    process_app "$entry" &
    job_pids+=($!)
    job_names+=("$entry_prefix")
  done

  # Wait for remaining jobs
  while (( ${#job_pids[@]} > 0 )); do
    reap_finished_jobs
    (( ${#job_pids[@]} > 0 )) && sleep 3
  done

  # Run remediation at end of manifest
  remediation_loop

  update_status "$completed" "$total" "finished"
  redis_publish "pipeline_complete" "\"total\":$total,\"completed\":$completed,\"failed\":$failed,\"skipped\":$skipped"
  log "=== Pipeline Complete ==="
  log "  Total:     $total"
  log "  Deployed:  $completed"
  log "  Failed:    $failed"
  log "  Skipped:   $skipped"
  log "  Registry:  $REGISTRY"
  log "  Logs:      $LOG_DIR/"
}

main "$@"
