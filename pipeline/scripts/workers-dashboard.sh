#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Auto-refreshing dashboard for background workers
# Polls every 30s, shows workers, CRD status, resources, recent activity
#
# Usage: ./workers-dashboard.sh [--interval 15]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL=30

for arg in "$@"; do
  case "$arg" in
    --interval) INTERVAL="$2"; shift 2 ;;
    [0-9]*)     INTERVAL="$arg" ;;
  esac
done

while true; do
  clear
  bash "$SCRIPT_DIR/workers-status.sh" 2>/dev/null
  printf "\033[2m  Refreshing every %ds — Ctrl-C to exit\033[0m\n" "$INTERVAL"
  sleep "$INTERVAL"
done
