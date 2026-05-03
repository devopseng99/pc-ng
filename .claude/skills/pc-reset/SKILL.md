---
name: pc-reset
description: Reset Failed/NoBuildScript/Deploying CRDs back to Pending for retry. Optionally reset specific app IDs, pipelines, or phases. Also rotates old logs.
allowed-tools: Bash
user-invocable: true
argument-hint: [--app-id N] [--rotate-logs] [--all-failed] [--all-stale] [--phase PHASE] [--pipeline NAME]
---

# PC-NG Reset Builds

Reset CRDs to Pending for retry. Targets Failed by default, but can also reset NoBuildScript, stale Deploying, and RegenerationNeeded.

## Arguments

- `--all-failed` — Reset all Failed CRDs to Pending (default if no --app-id)
- `--all-stale` — Reset all Failed + NoBuildScript + RegenerationNeeded + stale Deploying to Pending
- `--phase PHASE` — Reset only CRDs in this specific phase (e.g., `--phase NoBuildScript`)
- `--pipeline NAME` — Only reset CRDs from this pipeline
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

2. Show current non-Deployed CRDs with error messages:
```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
from collections import defaultdict
counts = defaultdict(int)
for i in json.load(sys.stdin)['items']:
    s = i.get('status',{})
    phase = s.get('phase','Unknown')
    if phase not in ('Deployed','Pending'):
        counts[phase] += 1
        sp = i['spec']
        print(f'  [{phase:20s}] #{sp[\"appId\"]} {sp[\"prefix\"]} ({sp.get(\"pipeline\",\"?\")}) — {s.get(\"errorMessage\",\"?\")[:50]}')
print()
for phase, count in sorted(counts.items(), key=lambda x:-x[1]):
    print(f'{phase}: {count}')
"
```

3. Determine which phases to reset based on arguments:
- `--all-failed` or no flags → reset `Failed` only
- `--all-stale` → reset `Failed`, `NoBuildScript`, `RegenerationNeeded`, `Deploying`
- `--phase X` → reset only phase X
- `--pipeline NAME` → filter to that pipeline
- `--app-id N` → filter to that app ID

4. Reset matching CRDs to Pending:
```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys,subprocess
TARGET_PHASES = {'Failed'}  # Adjust per arguments: add NoBuildScript, Deploying, RegenerationNeeded as needed
count = 0
for i in json.load(sys.stdin)['items']:
    phase = i.get('status',{}).get('phase','')
    if phase in TARGET_PHASES:
        name = i['metadata']['name']
        subprocess.run(['kubectl','patch','paperclipbuild',name,'-n','paperclip-v3',
          '--type','merge','--subresource=status',
          '-p','{\"status\":{\"phase\":\"Pending\",\"errorMessage\":\"\"}}'],
          capture_output=True)
        print(f'Reset: {name}')
        count += 1
print(f'\nReset {count} CRDs to Pending')
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
