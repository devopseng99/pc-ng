#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Phase A — Code Generation Only
#
# Onboards apps and generates code via Claude Code. Does NOT deploy.
# Completed builds are pushed to GitHub and CRD set to "Building" -> done.
# Run Phase B (batch-deploy-k8s.sh) separately to deploy finished builds.
#
# Usage:
#   ./phase-a-codegen.sh --manifest <file.json> --pipeline-id v1 [--concurrency 4]
#   ./phase-a-codegen.sh --manifest <file.json> --pipeline-id tech --dry-run
#   ./phase-a-codegen.sh --manifest <file.json> --pipeline-id v1 --timeout 300
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="/tmp/pc-autopilot"
REGISTRY="$WORKSPACE/registry/deployed.json"
LOG_DIR="$WORKSPACE/logs"
PC_DIR="/var/lib/rancher/ansible/db/pc"
STATUS_FILE="$WORKSPACE/.codegen-status"
READY_DIR="$WORKSPACE/.ready-to-deploy"

CONCURRENCY=2
MANIFEST=""
BUILD_TIMEOUT=300
PIPELINE_ID="v1"
DRY_RUN=false
SKIP_ONBOARD=false
STALL_TIMEOUT=90  # kill build if no file changes in this many seconds

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --concurrency)   CONCURRENCY="$2"; shift 2 ;;
    --pipeline-id)   PIPELINE_ID="$2"; shift 2 ;;
    --timeout)       BUILD_TIMEOUT="$2"; shift 2 ;;
    --stall-timeout) STALL_TIMEOUT="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --skip-onboard)  SKIP_ONBOARD=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$MANIFEST" ]] && { echo "Error: --manifest required"; exit 1; }

# --- Load secrets ---
export GH_TOKEN="${GH_TOKEN:-$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)}"
export BOARD_API_KEY="${BOARD_API_KEY:-$(kubectl get secret pc-board-api-key -n paperclip -o jsonpath='{.data.key}' | base64 -d 2>/dev/null || echo '')}"

# --- Redis ---
REDIS_PASS_FILE="/tmp/pc-autopilot/.redis-pass"
_redis_pass() {
  if [[ -f "$REDIS_PASS_FILE" ]]; then cat "$REDIS_PASS_FILE"
  else
    local pass; pass=$(kubectl get secret redis-credentials -n paperclip-v3 -o jsonpath='{.data.password}' | base64 -d)
    echo "$pass" > "$REDIS_PASS_FILE"; chmod 600 "$REDIS_PASS_FILE"; echo "$pass"
  fi
}
rcli() { kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- redis-cli -a "$(_redis_pass)" --no-auth-warning "$@" 2>/dev/null; }
redis_publish() {
  local type="$1" payload="$2"
  rcli PUBLISH "pipeline:events" "{\"type\":\"${type}\",\"pipeline\":\"${PIPELINE_ID}\",\"ts\":\"$(date -Iseconds)\",${payload}}" >/dev/null 2>&1 || true
}

# --- Helpers ---
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_app() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

mkdir -p "$LOG_DIR" "$READY_DIR"

# --- CRD helpers ---
create_crd_entry() {
  local id="$1" name="$2" prefix="$3" repo="$4" category="${5:-Misc}"
  local crd_name="pb-${id}-$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
  kubectl get paperclipbuild "$crd_name" -n paperclip-v3 &>/dev/null && return 0
  kubectl apply -f - <<EOF || { echo "WARN: CRD creation failed for $crd_name — continuing without CRD tracking"; return 0; }
apiVersion: paperclip.istayintek.com/v1alpha1
kind: PaperclipBuild
metadata:
  name: ${crd_name}
  namespace: paperclip-v3
spec:
  appId: ${id}
  appName: "${name}"
  prefix: "${prefix}"
  repo: "${repo}"
  category: "${category}"
  pipeline: "${PIPELINE_ID}"
EOF
}

update_crd_status() {
  local id="$1" prefix="$2" phase="$3" step="${4:-}" extra="${5:-}"
  local crd_name="pb-${id}-$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
  local patch="{\"status\":{\"phase\":\"${phase}\",\"currentStep\":\"${step}\"${extra:+,$extra}}}"
  kubectl patch paperclipbuild "$crd_name" -n paperclip-v3 --type merge -p "$patch" --subresource=status 2>/dev/null || true
}

is_built() {
  # Check if repo has code on GitHub (non-empty)
  local repo="$1"
  local size
  size=$(curl -sH "Authorization: token $GH_TOKEN" "https://api.github.com/repos/devopseng99/$repo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('size',0))" 2>/dev/null)
  [[ "$size" -gt 0 ]] 2>/dev/null
}

is_deployed() {
  local id="$1"
  local crd_name
  crd_name=$(kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin).get('items',[]):
    if i['spec'].get('appId') == $id and i.get('status',{}).get('phase') == 'Deployed':
        print('yes'); break
" 2>/dev/null)
  [[ "$crd_name" == "yes" ]]
}

get_entries() {
  python3 -c "
import json
with open('$1') as f: data = json.load(f)
apps = data.get('apps', data.get('use_cases', []))
for a in apps: print(json.dumps(a))
"
}

# --- Stall-detecting build runner ---
# Runs claude with a hard timeout, but also kills if no new files appear in /tmp/$repo
run_build_with_watchdog() {
  local repo="$1" prompt="$2" logfile="$3"
  local build_dir="/tmp/$repo"

  echo "[$(date -Iseconds)] Build started" > "$logfile"

  # Launch claude in background
  echo "$prompt" | timeout "$BUILD_TIMEOUT" claude --dangerously-skip-permissions -p - >> "$logfile" 2>&1 &
  local claude_pid=$!

  # Watchdog: check for stalled builds
  local last_change
  last_change=$(date +%s)

  while kill -0 "$claude_pid" 2>/dev/null; do
    sleep 10
    # Check if any files changed recently in build dir
    if [[ -d "$build_dir" ]]; then
      local newest
      newest=$(find "$build_dir" -type f -newer "$logfile" -print -quit 2>/dev/null || true)
      if [[ -n "$newest" ]]; then
        last_change=$(date +%s)
        touch "$logfile"  # refresh reference timestamp
      fi
    fi

    local now
    now=$(date +%s)
    local idle=$(( now - last_change ))
    if (( idle > STALL_TIMEOUT )); then
      echo "[$(date -Iseconds)] WATCHDOG: No file activity for ${idle}s — killing stalled build" >> "$logfile"
      kill "$claude_pid" 2>/dev/null; wait "$claude_pid" 2>/dev/null || true
      return 1
    fi
  done

  wait "$claude_pid" 2>/dev/null
  return $?
}

# --- Check if build produced output ---
has_build_output() {
  local repo="$1"
  [[ -f "/tmp/$repo/out/index.html" ]] || \
  [[ -f "/tmp/$repo/dist/index.html" ]] || \
  [[ -f "/tmp/$repo/.next/server/app/page.js" ]] || \
  [[ -f "/tmp/$repo/package.json" ]]
}

# --- Push built code to GitHub ---
push_to_github() {
  local repo="$1" name="$2"
  local build_dir="/tmp/$repo"
  local push_output
  cd "$build_dir"

  # Ensure git is initialized with correct remote URL
  local expected_url="https://${GH_TOKEN}@github.com/devopseng99/${repo}.git"
  if [[ ! -d .git ]]; then
    git init -q
    git remote add origin "$expected_url"
  else
    # Claude Code may have initialized git with a different remote — fix it
    git remote set-url origin "$expected_url" 2>/dev/null || \
      git remote add origin "$expected_url" 2>/dev/null || true
  fi

  git add -A 2>/dev/null
  if git diff --cached --quiet 2>/dev/null; then
    # Nothing new to commit — check if remote already has code
    if verify_on_github "$repo"; then
      return 0
    fi
    # Local has commits but remote is empty — force push existing
    if git log --oneline -1 &>/dev/null; then
      git branch -M main 2>/dev/null
      push_output=$(git push -f origin main 2>&1) || {
        log_app "PUSH" "git push failed: $push_output"
        return 1
      }
      return 0
    fi
    return 1  # nothing to commit and nothing on remote
  fi
  git commit -q -m "feat: initial ${name} app — generated by PC pipeline" 2>/dev/null || true
  git branch -M main 2>/dev/null
  push_output=$(git push -f origin main 2>&1) || {
    log_app "PUSH" "git push failed: $push_output"
    return 1
  }
}

# --- Verify code actually reached GitHub ---
verify_on_github() {
  local repo="$1"
  local http_code
  # Check if main branch exists (faster + more reliable than repo size which lags)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/repos/devopseng99/${repo}/git/ref/heads/main" 2>/dev/null)
  [[ "$http_code" == "200" ]]
}

# --- Process single app (codegen only) ---
process_codegen() {
  local entry="$1"
  local id name prefix type repo budget description features design_bg design_primary design_vibe email category

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
    log_app "$prefix" "SKIP: Already deployed"
    return 0
  fi

  # Skip if already has code (already built)
  if is_built "$repo"; then
    log_app "$prefix" "SKIP: Repo already has code — ready for deploy"
    # Mark ready for deploy
    echo "$entry" > "$READY_DIR/${id}-${prefix}.json"
    return 0
  fi

  local logfile="$LOG_DIR/${prefix}-$(date '+%Y%m%d-%H%M%S').log"
  log_app "$prefix" "Starting codegen: $name (id=$id, category=$category)"

  # Step 1: Create GitHub repo
  gh repo create "devopseng99/$repo" --public --description "$name — $description" 2>&1 || true

  # Step 2: Onboard
  if [[ "$SKIP_ONBOARD" != "true" ]] && [[ -n "$BOARD_API_KEY" ]]; then
    update_crd_status "$id" "$prefix" "Onboarding" "onboarding"
    log_app "$prefix" "Onboarding..."
    local company_id
    company_id=$("$PC_DIR/client-onboarding/scripts/onboard-full.sh" \
      --name "$name" --prefix "$prefix" --email "$email" --budget "$budget" \
      --business-type "$type" --repo "https://github.com/devopseng99/$repo" 2>&1 | \
      grep -oP 'company_id[=:]\s*\K[a-f0-9-]+' | head -1 || echo "unknown")

    # Move issues to todo
    if [[ "$company_id" != "unknown" ]]; then
      log_app "$prefix" "Moving issues to todo..."
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
" 2>/dev/null || true)
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

  # Step 3: Generate prompt
  log_app "$prefix" "Generating build prompt (category=$category)..."
  local prompt
  prompt=$("$SCRIPT_DIR/generate-prompt.sh" \
    --name "$name" --type "$type" --repo "$repo" \
    --description "$description" --features "$features" \
    --bg "$design_bg" --primary "$design_primary" --vibe "$design_vibe" \
    --category "$category")

  # Step 4: Run Claude Code with watchdog
  update_crd_status "$id" "$prefix" "Building" "ai-codegen"
  log_app "$prefix" "Building via Claude Code (timeout=${BUILD_TIMEOUT}s, stall=${STALL_TIMEOUT}s)..."
  redis_publish "build_start" "\"app\":\"$prefix\",\"id\":$id,\"category\":\"$category\""

  local build_ok=false
  local max_retries=3
  for attempt in $(seq 1 $max_retries); do
    local build_start_ts
    build_start_ts=$(date +%s)

    if run_build_with_watchdog "$repo" "$prompt" "$logfile"; then
      build_ok=true
      break
    elif has_build_output "$repo"; then
      log_app "$prefix" "Build process failed but output exists — recovering"
      build_ok=true
      break
    fi

    # If it failed in <30s, it's likely rate-limited — wait and retry
    local elapsed=$(( $(date +%s) - build_start_ts ))
    if (( elapsed < 30 )) && (( attempt < max_retries )); then
      local backoff=$(( 30 * attempt ))
      log_app "$prefix" "Build failed in ${elapsed}s (likely rate-limited) — retry $attempt/$max_retries in ${backoff}s..."
      sleep "$backoff"
      rm -rf "/tmp/$repo" 2>/dev/null
    else
      break
    fi
  done

  if [[ "$build_ok" != "true" ]]; then
    log_app "$prefix" "BUILD FAILED after $max_retries attempts (see $logfile)"
    update_crd_status "$id" "$prefix" "Failed" "ai-codegen" "\"errorMessage\":\"Build failed or timed out\""
    redis_publish "build_complete" "\"app\":\"$prefix\",\"id\":$id,\"status\":\"failed\""
    rm -rf "/tmp/$repo" 2>/dev/null
    return 1
  fi

  # Step 5: Push to GitHub + verify
  log_app "$prefix" "Pushing code to GitHub..."
  local push_ok=false

  # Attempt 1: normal push
  if push_to_github "$repo" "$name" >> "$logfile" 2>&1; then
    # Verify code actually reached GitHub (catches silent push failures)
    sleep 5
    if verify_on_github "$repo"; then
      push_ok=true
    else
      log_app "$prefix" "Push returned 0 but GitHub repo is empty — retrying with clean git"
    fi
  else
    log_app "$prefix" "Push failed (rc=$?) — retrying with clean git init"
  fi

  # Attempt 2: clean git reinit + force push
  if [[ "$push_ok" != "true" ]] && [[ -d "/tmp/$repo" ]]; then
    log_app "$prefix" "Retry push: reinitializing git..."
    rm -rf "/tmp/$repo/.git" 2>/dev/null
    (
      cd "/tmp/$repo"
      git init -q
      git remote add origin "https://${GH_TOKEN}@github.com/devopseng99/${repo}.git"
      git add -A
      git commit -q -m "feat: initial ${name} app — generated by PC pipeline"
      git branch -M main
      git push -f origin main
    ) >> "$logfile" 2>&1
    sleep 5
    if verify_on_github "$repo"; then
      push_ok=true
      log_app "$prefix" "Retry push succeeded — verified on GitHub"
    fi
  fi

  if [[ "$push_ok" == "true" ]]; then
    log_app "$prefix" "CODE READY: devopseng99/$repo (verified on GitHub)"
    update_crd_status "$id" "$prefix" "Building" "code-pushed" "\"errorMessage\":\"\""
    redis_publish "build_complete" "\"app\":\"$prefix\",\"id\":$id,\"status\":\"success\""
    echo "$entry" > "$READY_DIR/${id}-${prefix}.json"
  else
    log_app "$prefix" "PUSH FAILED: Code exists locally but could not reach GitHub"
    update_crd_status "$id" "$prefix" "Failed" "git-push" "\"errorMessage\":\"Git push failed — code not verified on GitHub\""
    redis_publish "build_complete" "\"app\":\"$prefix\",\"id\":$id,\"status\":\"failed\""
  fi

  # Cleanup build artifacts (code is on GitHub now or marked failed)
  rm -rf "/tmp/$repo" 2>/dev/null
  log_app "$prefix" "Cleaned /tmp/$repo"
}

# --- Main ---
main() {
  mkdir -p "$LOG_DIR" "$READY_DIR"

  local entries=()
  while IFS= read -r line; do
    entries+=("$line")
  done < <(get_entries "$MANIFEST")

  local total=${#entries[@]}
  log "Phase A — Code Generation (pipeline=$PIPELINE_ID)"
  log "  Manifest: $MANIFEST"
  log "  Apps: $total"
  log "  Concurrency: $CONCURRENCY"
  log "  Build timeout: ${BUILD_TIMEOUT}s / Stall timeout: ${STALL_TIMEOUT}s"
  log ""

  if [[ "$DRY_RUN" == "true" ]]; then
    for entry in "${entries[@]}"; do
      echo "$entry" | python3 -c "
import json,sys
e = json.load(sys.stdin)
print(f'  [{e[\"id\"]}] {e[\"name\"]} ({e[\"prefix\"]})  [{e.get(\"category\",\"?\")}]  repo={e[\"repo\"]}')
"
    done
    return
  fi

  # PID guard
  local pidfile="$WORKSPACE/.pid-codegen-${PIPELINE_ID}"
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "ERROR: Codegen $PIPELINE_ID already running (PID $(cat "$pidfile"))"
    exit 1
  fi
  echo $$ > "$pidfile"
  trap "rm -f '$pidfile'" EXIT

  local completed=0 failed=0 skipped=0
  local job_pids=() job_names=()

  reap_jobs() {
    local new_pids=() new_names=()
    for idx in "${!job_pids[@]}"; do
      if ! kill -0 "${job_pids[$idx]}" 2>/dev/null; then
        wait "${job_pids[$idx]}" 2>/dev/null && true
        local rc=$?
        if [[ $rc -eq 0 ]]; then
          completed=$((completed + 1))
        else
          failed=$((failed + 1))
        fi
        log "[${job_names[$idx]}] finished (rc=$rc)  [done=$completed fail=$failed skip=$skipped / $total]"
      else
        new_pids+=("${job_pids[$idx]}")
        new_names+=("${job_names[$idx]}")
      fi
    done
    job_pids=("${new_pids[@]+"${new_pids[@]}"}")
    job_names=("${new_names[@]+"${new_names[@]}"}")
  }

  for entry in "${entries[@]}"; do
    # Wait for a slot
    while (( ${#job_pids[@]} >= CONCURRENCY )); do
      reap_jobs
      (( ${#job_pids[@]} >= CONCURRENCY )) && sleep 5
    done

    local entry_id entry_prefix
    entry_id=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    entry_prefix=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['prefix'])")

    # Skip already deployed
    if is_deployed "$entry_id"; then
      skipped=$((skipped + 1))
      continue
    fi

    log_app "$entry_prefix" "Launching codegen slot..."
    process_codegen "$entry" &
    job_pids+=($!)
    job_names+=("$entry_prefix")
  done

  # Wait for remaining
  while (( ${#job_pids[@]} > 0 )); do
    reap_jobs
    (( ${#job_pids[@]} > 0 )) && sleep 5
  done

  # Summary
  local ready
  ready=$(ls "$READY_DIR"/*.json 2>/dev/null | wc -l)
  log ""
  log "=== Phase A Complete ==="
  log "  Completed: $completed"
  log "  Failed:    $failed"
  log "  Skipped:   $skipped"
  log "  Ready to deploy: $ready"
  log ""
  log "Run Phase B to deploy:"
  log "  $SCRIPT_DIR/batch-deploy-k8s.sh"
  redis_publish "codegen_complete" "\"completed\":$completed,\"failed\":$failed,\"skipped\":$skipped,\"ready\":$ready"
}

main
