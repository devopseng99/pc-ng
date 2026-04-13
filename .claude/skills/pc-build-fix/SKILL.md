---
name: pc-build-fix
description: Fix failed app builds using Claude Code instead of full Phase A regen. Reads build errors, makes targeted code fixes, retries build.
allowed-tools: Bash
user-invocable: true
argument-hint: [--crd NAME] [--pipeline NAME] [--all-failed] [--max-fixes 3]
---

# PC-NG Build Fix (Phase B Recovery)

Fix apps that failed during Phase B (npm build errors) by using Claude Code to make targeted code fixes instead of regenerating the entire app via Phase A.

## Arguments

- `--crd NAME` — Fix a single app by CRD name
- `--pipeline NAME` — Fix all failed apps in a pipeline
- `--all-failed` — Fix all failed apps across all pipelines
- `--max-fixes N` — Max fix attempts per app (default: 3)

## Steps

1. Show Failed CRDs with build-related errors:
```bash
echo "=== Failed Apps ==="
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
items = json.load(sys.stdin)['items']
failed = [i for i in items if i.get('status',{}).get('phase') == 'Failed']
if '${PIPELINE:-}':
    failed = [i for i in failed if i['spec'].get('pipeline') == '${PIPELINE:-}']
if '${CRD:-}':
    failed = [i for i in failed if i['metadata']['name'] == '${CRD:-}']
print(f'Failed apps: {len(failed)}')
for i in failed:
    s = i.get('status',{})
    sp = i['spec']
    err = s.get('errorMessage','')[:80]
    print(f'  {i[\"metadata\"][\"name\"]} ({sp[\"prefix\"]}) — {err}')
"
```

2. For each target app, run the build-fix loop:
```bash
bash /var/lib/rancher/ansible/db/pc/builder/build-fix-loop.sh $ARGUMENTS
```

3. Show results:
```bash
echo ""
echo "=== Results ==="
kubectl get pb -n paperclip-v3 --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn
```

Report: how many fixed, how many still failing, recommendations for apps needing full regen.
