#!/usr/bin/env bash
# Background monitor — logs status every 30s to a file for tracking
WORKSPACE="/tmp/pc-autopilot"
STATUS_LOG="$WORKSPACE/.workers/monitor.log"
INTERVAL=${1:-30}

mkdir -p "$WORKSPACE/.workers"

while true; do
  {
    echo "========== $(date '+%Y-%m-%d %H:%M:%S') =========="
    
    # Worker PIDs
    for p in v1 tech; do
      pf="$WORKSPACE/.workers/${p}.pid"
      if [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null; then
        echo "  $p: RUNNING (PID $(cat "$pf"))"
      else
        echo "  $p: STOPPED"
      fi
    done

    # Progress from logs
    for p in v1 tech; do
      lf="$WORKSPACE/.workers/${p}.log"
      [[ -f "$lf" ]] && grep -oP 'done=\d+ fail=\d+ skip=\d+ / \d+' "$lf" | tail -1 | sed "s/^/  $p: /"
    done

    # CRD summary
    kubectl get paperclipbuild -n paperclip-v3 -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
p={}
for i in d['items']:
    ph=i.get('status',{}).get('phase','?')
    p[ph]=p.get(ph,0)+1
print('  CRDs: ' + ', '.join(f'{v} {k}' for k,v in sorted(p.items(),key=lambda x:-x[1])))" 2>/dev/null

    # Resources
    kubectl top nodes --no-headers 2>/dev/null | awk '{printf "  %s CPU=%s(%s) MEM=%s(%s)\n",$1,$2,$3,$4,$5}'

    # Ready to deploy
    ready=$(ls "$WORKSPACE/.ready-to-deploy/"*.json 2>/dev/null | wc -l)
    pods=$(kubectl get pods -n paperclip -l managed-by=pc-ng --no-headers 2>/dev/null | wc -l)
    echo "  Ready-to-deploy: $ready | K8s pods: $pods"
    echo ""
  } >> "$STATUS_LOG" 2>/dev/null

  sleep "$INTERVAL"
done
