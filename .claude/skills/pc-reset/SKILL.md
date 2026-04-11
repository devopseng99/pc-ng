---
name: pc-reset
description: Reset Failed CRDs back to Pending for retry. Optionally reset specific app IDs. Also rotates old logs for a clean slate.
allowed-tools: Bash
user-invocable: true
argument-hint: [--app-id N] [--rotate-logs] [--all-failed]
---

# PC-NG Reset Failed Builds

Reset failed CRDs and optionally rotate logs.

## Arguments

- `--all-failed` — Reset all Failed CRDs to Pending (default if no --app-id)
- `--app-id N` — Reset a specific app ID
- `--rotate-logs` — Archive old logs before reset

## Steps

1. If `--rotate-logs` in arguments, archive logs:
```bash
ARCHIVE="/tmp/pc-autopilot/logs-archive-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ARCHIVE"
for f in /tmp/pc-autopilot/.workers/*.log; do
  [[ -f "$f" ]] && mv "$f" "$ARCHIVE/"
done
mv /tmp/pc-autopilot/logs/*.log "$ARCHIVE/" 2>/dev/null
echo "Archived to $ARCHIVE"
```

2. Show current Failed CRDs with error messages:
```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    s = i.get('status',{})
    if s.get('phase') == 'Failed':
        sp = i['spec']
        print(f'#{sp[\"appId\"]} {sp[\"prefix\"]} — {s.get(\"errorMessage\",\"?\")[:60]}')
"
```

3. Reset CRDs to Pending:
```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys,subprocess
for i in json.load(sys.stdin)['items']:
    if i.get('status',{}).get('phase') == 'Failed':
        name = i['metadata']['name']
        subprocess.run(['kubectl','patch','paperclipbuild',name,'-n','paperclip-v3',
          '--type','merge','--subresource=status',
          '-p','{\"status\":{\"phase\":\"Pending\",\"errorMessage\":\"\"}}'],
          capture_output=True)
        print(f'Reset: {name}')
"
```

4. Clear circuit breaker state (per-pipeline from registry + legacy shared):
```bash
> /tmp/pc-autopilot/.circuit-breaker-results
PIPELINES=$(source /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/pipeline-registry.sh && list_pipelines)
for p in $PIPELINES default; do
  echo "closed" > /tmp/pc-autopilot/.circuit-breaker-state-${p} 2>/dev/null
done
echo "closed" > /tmp/pc-autopilot/.circuit-breaker-state 2>/dev/null
```

5. Show updated status:
```bash
kubectl get pb -n paperclip-v3 --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn
```

Report: how many reset, current phase counts.
