---
name: pc-status
description: Show pipeline status — CRD phases, worker health, circuit breaker, cluster resources, showroom sync, recent activity. Use when user asks about status, progress, or health.
allowed-tools: Bash, Read
user-invocable: true
---

# PC-NG Pipeline Status

Run the full status check and present a clear summary.

## Steps

1. Run the workers status script:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/workers-status.sh 2>/dev/null
```

2. Check the circuit breaker state:
```bash
cat /tmp/pc-autopilot/.circuit-breaker-state 2>/dev/null
cat /tmp/pc-autopilot/.circuit-breaker-results 2>/dev/null | tail -5
```

3. Check the emergency halt file:
```bash
ls -la /tmp/pc-autopilot/.emergency-halt 2>/dev/null && echo "HALT ACTIVE" || echo "No halt"
```

4. Show recent log activity from both workers:
```bash
tail -5 /tmp/pc-autopilot/.workers/v1.log 2>/dev/null
tail -5 /tmp/pc-autopilot/.workers/tech.log 2>/dev/null
```

5. If supervisor is running, show its recent actions:
```bash
grep "\[ACTION\]" /tmp/pc-autopilot/.workers/supervisor.log 2>/dev/null | tail -5
```

6. Check showroom sync (live dashboard):
```bash
curl -s https://showroom.istayintek.com/api/health 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'Showroom: {d[\"status\"]} | SSE clients: {d[\"checks\"][\"sseClients\"]} | DB: {d[\"checks\"][\"database\"]}')" 2>/dev/null || echo "Showroom: unreachable"
curl -s "https://showroom.istayintek.com/api/apps?limit=1" 2>/dev/null | python3 -c "import json,sys; print(f'Showroom apps synced: {json.load(sys.stdin).get(\"total\",\"?\")}')" 2>/dev/null
```

7. Show per-pipeline breakdown:
```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
from collections import defaultdict
items = json.load(sys.stdin)['items']
pipelines = defaultdict(lambda: defaultdict(int))
for i in items:
    p = i['spec'].get('pipeline','?')
    phase = i.get('status',{}).get('phase','Unknown')
    pipelines[p][phase] += 1
    pipelines[p]['total'] += 1
for p in sorted(pipelines):
    parts = ', '.join(f'{v} {k}' for k,v in sorted(pipelines[p].items()) if k != 'total')
    print(f'  {p:8s} ({pipelines[p][\"total\"]:3d}): {parts}')
" 2>/dev/null
```

## Output Format

Present as a concise table:
- CRD counts by phase (Deployed, Deploying, Building, Pending, Failed)
- **Per-pipeline breakdown** (v1, tech, wasm, soa — phases per pipeline)
- Worker status (running/stopped, current build, progress counters)
- Circuit breaker state (closed/open/half-open)
- Cluster resource usage
- Showroom sync status (total synced, SSE clients, health)
- Any errors or alerts from recent activity

Live dashboard: https://showroom.istayintek.com
