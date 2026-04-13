---
name: pc-build
description: Trigger Phase B — build static apps from GitHub and deploy to shared Nginx pod. Arguments control pipeline, concurrency, dry-run.
allowed-tools: Bash
user-invocable: true
argument-hint: [--pipeline NAME] [--crd NAME] [--concurrency N] [--retry-failed] [--dry-run] [--limit N]
---

# PC-NG Build & Deploy (Phase B)

Build apps from GitHub repos and deploy static files to the shared Nginx wildcard vhost pod.
This is the canonical Phase B skill. `/pc-deploy` is an alias for this.

## Arguments

- `$ARGUMENTS` — Passed directly to build-and-deploy.sh
- `--pipeline NAME` — Build only apps from this pipeline
- `--crd NAME` — Build a single app by CRD name
- `--concurrency N` — Parallel builds (default: 1, max: 4)
- `--retry-failed` — Retry previously failed builds
- `--dry-run` — Preview what would be built without building
- `--limit N` — Build only first N apps

## Steps

1. Show current Deploying CRDs (the build queue):
```bash
echo "=== Build Queue ==="
if [[ -n "${PIPELINE:-}" ]]; then
  kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
items = json.load(sys.stdin)['items']
deploying = [i for i in items if i.get('status',{}).get('phase') == 'Deploying' and i['spec'].get('pipeline') == '$PIPELINE']
print(f'Deploying apps ({\"$PIPELINE\"}): {len(deploying)}')
for i in deploying[:10]:
    print(f'  {i[\"metadata\"][\"name\"]} — {i[\"spec\"][\"prefix\"]}')
if len(deploying) > 10: print(f'  ... and {len(deploying)-10} more')
"
else
  kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
from collections import defaultdict
items = json.load(sys.stdin)['items']
by_pipeline = defaultdict(int)
for i in items:
    if i.get('status',{}).get('phase') == 'Deploying':
        by_pipeline[i['spec'].get('pipeline','?')] += 1
total = sum(by_pipeline.values())
print(f'Total Deploying: {total}')
for p in sorted(by_pipeline): print(f'  {p}: {by_pipeline[p]}')
"
fi
```

2. Run build-and-deploy:
```bash
bash /var/lib/rancher/ansible/db/pc/builder/build-and-deploy.sh $ARGUMENTS
```

3. Show updated CRD phase counts:
```bash
echo ""
echo "=== Updated Status ==="
kubectl get pb -n paperclip-v3 --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn
```

Report: how many built successfully, how many failed, updated totals.
