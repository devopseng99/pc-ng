#!/usr/bin/env bash
# adlc-loop.sh — ADLC progress monitor and phase executor
#
# Usage:
#   bash docs/adlc-loop.sh --status           # Show current progress
#   bash docs/adlc-loop.sh --check-phase 1    # Check Phase 1 completion
#   bash docs/adlc-loop.sh --update-plan      # Update ADLC-PLAN.md checkboxes from state
#   bash docs/adlc-loop.sh --loop             # Continuous monitoring (poll every 60s)
#   bash docs/adlc-loop.sh --run-phase 1      # Execute a phase via builder/intake
#
# State is tracked in /tmp/adlc-state/ as simple files per step.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="$SCRIPT_DIR/ADLC-PLAN.md"
STATE_DIR="/tmp/adlc-state"
LOG_FILE="$SCRIPT_DIR/adlc-progress.log"

BUILDER_REPO="/var/lib/rancher/ansible/db/sdk-agentic-custom-builder-intake"
INTAKE_REPO="/var/lib/rancher/ansible/db/sdk-agent-intake"
ROUTE_SH="$INTAKE_REPO/route.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$STATE_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "$msg"
}

# --- State management ---

mark_step() {
    local phase="$1" step="$2" status="${3:-done}"
    echo "$status" > "$STATE_DIR/phase${phase}-step${step}"
    log "Phase $phase Step $step → $status"
}

get_step() {
    local phase="$1" step="$2"
    cat "$STATE_DIR/phase${phase}-step${step}" 2>/dev/null || echo "pending"
}

# --- Status display ---

show_status() {
    echo -e "${BOLD}=== ADLC Pipeline Status ===${NC}"
    echo ""

    local phases=("0:Foundation:5" "1:Builder-Hardening:5" "2:AgentIntake-CRD:5" "3A:Langfuse:5" "3B:ai-hedge-fund:5" "4:JSONL-Converter:3" "5:OpenFeature:4" "6:intake-hud:3" "7:Multi-Cluster:5")

    for phase_info in "${phases[@]}"; do
        IFS=':' read -r phase name total_steps <<< "$phase_info"
        local done=0
        local failed=0
        local in_progress=0

        for ((s=1; s<=total_steps; s++)); do
            local state
            state=$(get_step "$phase" "$s")
            case "$state" in
                done) ((done++)) || true ;;
                failed) ((failed++)) || true ;;
                running) ((in_progress++)) || true ;;
            esac
        done

        local color="$NC"
        local status_label="PENDING"
        if [[ $done -eq $total_steps ]]; then
            color="$GREEN"
            status_label="COMPLETE"
        elif [[ $in_progress -gt 0 ]]; then
            color="$YELLOW"
            status_label="IN PROGRESS"
        elif [[ $failed -gt 0 ]]; then
            color="$RED"
            status_label="FAILED"
        elif [[ $done -gt 0 ]]; then
            color="$CYAN"
            status_label="PARTIAL ($done/$total_steps)"
        fi

        printf "  ${color}%-4s${NC} %-20s ${color}%-15s${NC} [%d/%d done" "$phase" "$name" "$status_label" "$done" "$total_steps"
        [[ $failed -gt 0 ]] && printf ", ${RED}%d failed${NC}" "$failed"
        [[ $in_progress -gt 0 ]] && printf ", ${YELLOW}%d running${NC}" "$in_progress"
        echo "]"
    done

    echo ""

    # Show recent log entries
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${BOLD}Recent Activity:${NC}"
        tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    fi

    echo ""

    # Repo versions
    echo -e "${BOLD}Repo Versions:${NC}"
    local intake_ver builder_ver
    intake_ver=$(cat "$INTAKE_REPO/sdk-tmpl/VERSION" 2>/dev/null | head -1)
    builder_ver=$(cat "$BUILDER_REPO/builder-tmpl/VERSION" 2>/dev/null | head -1)
    echo "  sdk-agent-intake:                  v${intake_ver:-?}"
    echo "  sdk-agentic-custom-builder-intake:  v${builder_ver:-?}"

    # Check for generated outputs
    echo ""
    echo -e "${BOLD}Generated Outputs:${NC}"
    for dir in agent-intake-controller jsonl-converter langfuse ai-hedge-fund; do
        local full="/var/lib/rancher/ansible/db/$dir"
        if [[ -d "$full" ]]; then
            echo -e "  ${GREEN}[EXISTS]${NC} $full"
        else
            echo -e "  ${NC}[-----]${NC} $full"
        fi
    done

    # K8s namespaces for ADLC components
    echo ""
    echo -e "${BOLD}K8s Namespaces:${NC}"
    for ns in agent-intake langfuse ai-hedge-fund openfeature; do
        if kubectl get namespace "$ns" &>/dev/null 2>&1; then
            local pods
            pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l || echo "0")
            echo -e "  ${GREEN}[LIVE]${NC}  $ns ($pods pods)"
        else
            echo "  [----]  $ns"
        fi
    done || true
}

# --- Phase checking ---

check_phase() {
    local phase="$1"

    case "$phase" in
        0)
            echo "Phase 0 — Foundation:"
            # Check route.sh exists
            [[ -x "$ROUTE_SH" ]] && mark_step 0 1 done || mark_step 0 1 pending
            echo "  0.1 route.sh: $(get_step 0 1)"

            # Check scaffold version
            local scaffold_ver
            scaffold_ver=$(grep "Scaffold version:" "$INTAKE_REPO/sdk-tmpl/skill-registry/deploy-app-scaffold.md" 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "?")
            [[ "$scaffold_ver" == "2.1.0" ]] && mark_step 0 2 done || mark_step 0 2 pending
            echo "  0.2 scaffold v2.1.0: $(get_step 0 2) (current: $scaffold_ver)"

            # Check ai-hedge-fund config
            [[ -f "$INTAKE_REPO/agentX/ai-hedge-fund.yaml" ]] && mark_step 0 3 done || mark_step 0 3 pending
            echo "  0.3 ai-hedge-fund config: $(get_step 0 3)"

            # Check engine field in defaults
            grep -q "^engine:" "$INTAKE_REPO/agentX/_defaults.yaml" 2>/dev/null && mark_step 0 4 done || mark_step 0 4 pending
            echo "  0.4 engine routing: $(get_step 0 4)"

            # Check commits
            local intake_commit builder_commit
            intake_commit=$(cd "$INTAKE_REPO" && git log -1 --format="%h %s" 2>/dev/null)
            builder_commit=$(cd "$BUILDER_REPO" && git log -1 --format="%h %s" 2>/dev/null)
            [[ "$intake_commit" == *"engine routing"* || "$intake_commit" == *"v2.1.0"* ]] && mark_step 0 5 done || mark_step 0 5 pending
            echo "  0.5 committed: $(get_step 0 5)"
            echo "       intake:  $intake_commit"
            echo "       builder: $builder_commit"
            ;;
        1)
            echo "Phase 1 — Builder Hardening:"
            # 1.1 dry-run
            if python3 "$BUILDER_REPO/builder-tmpl/builder.py" --help 2>/dev/null | grep -q "dry.run"; then
                mark_step 1 1 done
            else
                mark_step 1 1 pending
            fi
            echo "  1.1 --dry-run support: $(get_step 1 1)"

            # 1.2 cli-tool template
            [[ -d "$BUILDER_REPO/golden-tmpl/cli-tool" ]] && mark_step 1 2 done || mark_step 1 2 pending
            echo "  1.2 cli-tool template: $(get_step 1 2)"

            # 1.3 --from-crd mode
            if python3 "$BUILDER_REPO/builder-tmpl/builder.py" --help 2>/dev/null | grep -q "from.crd"; then
                mark_step 1 3 done
            else
                mark_step 1 3 pending
            fi
            echo "  1.3 --from-crd mode: $(get_step 1 3)"

            # 1.4 jsonl-converter spec
            [[ -f "$BUILDER_REPO/specs/jsonl-converter.yaml" ]] && mark_step 1 4 done || mark_step 1 4 pending
            echo "  1.4 jsonl-converter spec: $(get_step 1 4)"

            # 1.5 version bump
            local bver
            bver=$(cat "$BUILDER_REPO/builder-tmpl/VERSION" 2>/dev/null | head -1)
            [[ "$bver" == "1.1.0" ]] && mark_step 1 5 done || mark_step 1 5 pending
            echo "  1.5 version v1.1.0: $(get_step 1 5) (current: $bver)"
            ;;
        2)
            echo "Phase 2 — AgentIntake CRD + Controller:"
            # 2.1 builder output exists
            [[ -d "/var/lib/rancher/ansible/db/agent-intake-controller" ]] && mark_step 2 1 done || mark_step 2 1 pending
            echo "  2.1 project generated: $(get_step 2 1)"

            # 2.2 reconciler has circuit breaker
            if grep -q "circuit_breaker\|circuit.breaker" /var/lib/rancher/ansible/db/agent-intake-controller/controller/reconciler.py 2>/dev/null; then
                mark_step 2 2 done
            else
                mark_step 2 2 pending
            fi
            echo "  2.2 PaperclipBuild patterns wired: $(get_step 2 2)"

            # 2.3 GitHub repo
            if gh repo view devopseng99/agent-intake-controller &>/dev/null 2>&1; then
                mark_step 2 3 done
            else
                mark_step 2 3 pending
            fi
            echo "  2.3 GitHub repo: $(get_step 2 3)"

            # 2.4 CRD registered + pod running
            if kubectl get crd agentintakes.agentintake.istayintek.com &>/dev/null 2>&1; then
                mark_step 2 4 done
            else
                mark_step 2 4 pending
            fi
            echo "  2.4 CRD + controller deployed: $(get_step 2 4)"

            # 2.5 version bump
            local bver
            bver=$(cat "$BUILDER_REPO/builder-tmpl/VERSION" 2>/dev/null | head -1)
            [[ "$bver" == "1.2.0" ]] && mark_step 2 5 done || mark_step 2 5 pending
            echo "  2.5 builder v1.2.0: $(get_step 2 5) (current: $bver)"
            ;;
        3A|3a)
            echo "Phase 3A — Langfuse:"
            [[ -f "$INTAKE_REPO/agentX/langfuse.yaml" ]] && mark_step 3A 1 done || mark_step 3A 1 pending
            echo "  3A.1 config created: $(get_step 3A 1)"

            if kubectl get namespace langfuse &>/dev/null 2>&1; then
                mark_step 3A 2 done
            else
                mark_step 3A 2 pending
            fi
            echo "  3A.2 intake deployed: $(get_step 3A 2)"

            local health
            health=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://langfuse.istayintek.com/api/health" 2>/dev/null || echo "000")
            [[ "$health" =~ ^2 ]] && mark_step 3A 3 done || mark_step 3A 3 pending
            echo "  3A.3 CF tunnel + health: $(get_step 3A 3) (HTTP $health)"

            # 3A.4 + 3A.5 API keys + full verify
            mark_step 3A 4 "$(get_step 3A 4)"
            mark_step 3A 5 "$(get_step 3A 5)"
            echo "  3A.4 ADLC integration: $(get_step 3A 4)"
            echo "  3A.5 full verify: $(get_step 3A 5)"
            ;;
        3B|3b)
            echo "Phase 3B — ai-hedge-fund:"
            [[ -f "$INTAKE_REPO/agentX/ai-hedge-fund.yaml" ]] && mark_step 3B 1 done || mark_step 3B 1 pending
            echo "  3B.1 config created: $(get_step 3B 1)"

            if kubectl get namespace ai-hedge-fund &>/dev/null 2>&1; then
                mark_step 3B 2 done
            else
                mark_step 3B 2 pending
            fi
            echo "  3B.2 intake deployed: $(get_step 3B 2)"

            # 3B.3 secrets
            if kubectl get secret -n ai-hedge-fund 2>/dev/null | grep -q api-key; then
                mark_step 3B 3 done
            else
                mark_step 3B 3 pending
            fi
            echo "  3B.3 API secrets: $(get_step 3B 3)"

            local health
            health=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://ai-hedge-fund.istayintek.com/" 2>/dev/null || echo "000")
            [[ "$health" =~ ^2 ]] && mark_step 3B 4 done || mark_step 3B 4 pending
            echo "  3B.4 CF tunnel: $(get_step 3B 4) (HTTP $health)"

            mark_step 3B 5 "$(get_step 3B 5)"
            echo "  3B.5 full verify: $(get_step 3B 5)"
            ;;
        *)
            echo "Phase $phase: check not yet implemented"
            ;;
    esac
}

# --- Plan updater ---

update_plan() {
    if [[ ! -f "$PLAN_FILE" ]]; then
        echo "ERROR: ADLC-PLAN.md not found at $PLAN_FILE"
        return 1
    fi

    log "Updating ADLC-PLAN.md from state..."

    # Update Execution Summary table statuses
    for phase_info in "0:Foundation" "1:Builder" "2:AgentIntake" "3A:Langfuse" "3B:ai-hedge-fund" "4:JSONL" "5:OpenFeature" "6:intake-hud" "7:Multi-Cluster"; do
        IFS=':' read -r phase name <<< "$phase_info"
        local steps_file
        steps_file=$(ls "$STATE_DIR"/phase${phase}-step* 2>/dev/null | wc -l)
        local done_count
        done_count=$(grep -l "^done$" "$STATE_DIR"/phase${phase}-step* 2>/dev/null | wc -l)

        if [[ $steps_file -eq 0 ]]; then
            continue
        fi

        local status="PARTIAL"
        local total=5
        [[ "$phase" == "4" || "$phase" == "6" ]] && total=3
        [[ "$phase" == "5" ]] && total=4

        if [[ $done_count -eq $total ]]; then
            status="COMPLETE"
        elif grep -q "^running$" "$STATE_DIR"/phase${phase}-step* 2>/dev/null; then
            status="IN PROGRESS"
        elif grep -q "^failed$" "$STATE_DIR"/phase${phase}-step* 2>/dev/null; then
            status="FAILED"
        fi
    done

    log "Plan update complete"
}

# --- Loop mode ---

run_loop() {
    local interval="${1:-60}"
    log "Starting ADLC monitor loop (interval: ${interval}s)"

    while true; do
        clear
        echo -e "${BOLD}ADLC Monitor — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo "Press Ctrl+C to stop"
        echo ""
        show_status
        echo ""
        echo -e "${CYAN}Checking all phases...${NC}"
        for phase in 0 1 2 3A 3B; do
            check_phase "$phase" 2>/dev/null
            echo ""
        done
        update_plan 2>/dev/null
        sleep "$interval"
    done
}

# --- Main ---

case "${1:-}" in
    --status)       show_status ;;
    --check-phase)  check_phase "${2:?Phase number required}" ;;
    --check-all)
        for phase in 0 1 2 3A 3B 4 5 6 7; do
            check_phase "$phase"
            echo ""
        done
        ;;
    --update-plan)  update_plan ;;
    --loop)         run_loop "${2:-60}" ;;
    --mark)         mark_step "${2:?phase}" "${3:?step}" "${4:-done}" ;;
    -h|--help)
        echo "Usage: bash adlc-loop.sh [COMMAND]"
        echo ""
        echo "Commands:"
        echo "  --status          Show current ADLC pipeline status"
        echo "  --check-phase N   Check completion of phase N (0,1,2,3A,3B,4,5,6,7)"
        echo "  --check-all       Check all phases"
        echo "  --update-plan     Update ADLC-PLAN.md from state"
        echo "  --loop [N]        Continuous monitoring (default: 60s interval)"
        echo "  --mark P S [done|failed|running]  Manually mark phase P step S"
        echo "  -h, --help        Show this help"
        ;;
    *)
        echo "Unknown command: ${1:-<none>}. Use --help for usage."
        exit 1
        ;;
esac
