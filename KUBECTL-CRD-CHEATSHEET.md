# Kubectl CRD Cheatsheet — PaperclipBuild

All commands target `PaperclipBuild` CRDs in the `paperclip-v3` namespace.
- API Group: `paperclip.istayintek.com/v1alpha1`
- Kind: `PaperclipBuild` | Shortname: `pb`
- 811 CRDs across 19 pipelines

---

## Quick Reference

```bash
NS=paperclip-v3   # every command below assumes this namespace
```

---

## 1. List & Query CRDs

### Basic listing

```bash
# All CRDs
kubectl get pb -n paperclip-v3

# Wide output (includes deploy URLs, timestamps)
kubectl get pb -n paperclip-v3 -o wide

# Sort by creation time
kubectl get pb -n paperclip-v3 --sort-by=.metadata.creationTimestamp

# Watch live changes
kubectl get pb -n paperclip-v3 --watch
```

### Filter by pipeline label

```bash
kubectl get pb -n paperclip-v3 -l pipeline=v1
kubectl get pb -n paperclip-v3 -l pipeline=tech
kubectl get pb -n paperclip-v3 -l pipeline=soa
kubectl get pb -n paperclip-v3 -l pipeline=ai
kubectl get pb -n paperclip-v3 -l pipeline=invest-bots
# ... any of the 19 pipelines
```

### Filter by phase (custom-columns + grep)

```bash
# Show name + phase columns, filter to a specific phase
kubectl get pb -n paperclip-v3 \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
  | grep Failed

kubectl get pb -n paperclip-v3 \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
  | grep Deployed

kubectl get pb -n paperclip-v3 \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
  | grep NoBuildScript
```

### Count by phase (Python one-liner)

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json, sys
from collections import Counter
items = json.load(sys.stdin)['items']
counts = Counter(i.get('status',{}).get('phase','Unknown') for i in items)
for phase, n in sorted(counts.items(), key=lambda x: -x[1]):
    print(f'  {phase}: {n}')
print(f'  Total: {len(items)}')
"
```

### Per-pipeline breakdown

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json, sys
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
    print(f'  {p:15s} ({pipelines[p][\"total\"]:3d}): {parts}')
"
```

---

## 2. Inspect Individual CRDs

### Full YAML

```bash
kubectl get pb pb-221-lpe -n paperclip-v3 -o yaml
```

### JSON output

```bash
kubectl get pb pb-221-lpe -n paperclip-v3 -o json
```

### Extract specific fields with jsonpath

```bash
# Get phase
kubectl get pb pb-221-lpe -n paperclip-v3 -o jsonpath='{.status.phase}'

# Get appName from spec
kubectl get pb pb-221-lpe -n paperclip-v3 -o jsonpath='{.spec.appName}'

# Get repo URL
kubectl get pb pb-221-lpe -n paperclip-v3 -o jsonpath='{.spec.repoUrl}'

# Get build error
kubectl get pb pb-221-lpe -n paperclip-v3 -o jsonpath='{.status.buildError}'

# Get deploy URL
kubectl get pb pb-221-lpe -n paperclip-v3 -o jsonpath='{.status.deployUrl}'
```

### List all CRDs with specific fields

```bash
kubectl get pb -n paperclip-v3 -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.appName}{"\n"}{end}'
```

---

## 3. Modify CRD Status (PATCH)

> **Important:** PaperclipBuild uses a `/status` subresource. Phase updates require patching the status subresource, not the main resource.

### Reset a single CRD to Pending (re-trigger build)

```bash
kubectl patch pb pb-221-lpe -n paperclip-v3 \
  --type merge --subresource status \
  -p '{"status":{"phase":"Pending","buildError":""}}'
```

### Reset to Deploying (re-trigger deploy only)

```bash
kubectl patch pb pb-221-lpe -n paperclip-v3 \
  --type merge --subresource status \
  -p '{"status":{"phase":"Deploying","buildError":""}}'
```

### Mark as Failed with error message

```bash
kubectl patch pb pb-221-lpe -n paperclip-v3 \
  --type merge --subresource status \
  -p '{"status":{"phase":"Failed","buildError":"manual: build timeout"}}'
```

### Mark as NoBuildScript

```bash
kubectl patch pb pb-221-lpe -n paperclip-v3 \
  --type merge --subresource status \
  -p '{"status":{"phase":"NoBuildScript"}}'
```

### Clear build error only (keep current phase)

```bash
kubectl patch pb pb-221-lpe -n paperclip-v3 \
  --type merge --subresource status \
  -p '{"status":{"buildError":""}}'
```

### Set deploy URL

```bash
kubectl patch pb pb-221-lpe -n paperclip-v3 \
  --type merge --subresource status \
  -p '{"status":{"deployUrl":"https://pb-221-lpe.istayintek.com"}}'
```

---

## 4. Bulk Operations (Python one-liners)

### Reset ALL Failed CRDs to Pending

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json, sys, subprocess
items = json.load(sys.stdin)['items']
failed = [i['metadata']['name'] for i in items if i.get('status',{}).get('phase') == 'Failed']
print(f'Resetting {len(failed)} Failed CRDs to Pending...')
for name in failed:
    subprocess.run(['kubectl','patch','pb',name,'-n','paperclip-v3',
        '--type','merge','--subresource','status',
        '-p','{\"status\":{\"phase\":\"Pending\",\"buildError\":\"\"}}'])
    print(f'  {name} -> Pending')
"
```

### Reset Failed CRDs for a specific pipeline

```bash
kubectl get pb -n paperclip-v3 -l pipeline=soa -o json | python3 -c "
import json, sys, subprocess
items = json.load(sys.stdin)['items']
failed = [i['metadata']['name'] for i in items if i.get('status',{}).get('phase') == 'Failed']
print(f'Resetting {len(failed)} Failed soa CRDs to Pending...')
for name in failed:
    subprocess.run(['kubectl','patch','pb',name,'-n','paperclip-v3',
        '--type','merge','--subresource','status',
        '-p','{\"status\":{\"phase\":\"Pending\",\"buildError\":\"\"}}'])
"
```

### List all build errors

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
for i in items:
    err = i.get('status',{}).get('buildError','')
    if err:
        name = i['metadata']['name']
        phase = i.get('status',{}).get('phase','?')
        print(f'{name} [{phase}]: {err[:120]}')
"
```

### Export CRD state to CSV

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json, sys, csv
items = json.load(sys.stdin)['items']
w = csv.writer(sys.stdout)
w.writerow(['name','appName','pipeline','phase','deployUrl','buildError'])
for i in items:
    w.writerow([
        i['metadata']['name'],
        i['spec'].get('appName',''),
        i['spec'].get('pipeline',''),
        i.get('status',{}).get('phase',''),
        i.get('status',{}).get('deployUrl',''),
        i.get('status',{}).get('buildError','')
    ])
" > /tmp/crds-export.csv
```

### Find CRDs missing deploy URLs

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
for i in items:
    phase = i.get('status',{}).get('phase','')
    url = i.get('status',{}).get('deployUrl','')
    if phase == 'Deployed' and not url:
        print(f'  {i[\"metadata\"][\"name\"]} — Deployed but no URL')
"
```

---

## 5. Create & Delete CRDs

### Create a new CRD from stdin

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: paperclip.istayintek.com/v1alpha1
kind: PaperclipBuild
metadata:
  name: pb-60318-myapp
  namespace: paperclip-v3
  labels:
    pipeline: tech
spec:
  appName: my-app-name
  companyId: "60318"
  pipeline: tech
  repoUrl: https://github.com/devopseng99/pb-60318-myapp
  pcInstance: pc-v2
  buildScript: build.sh
status:
  phase: Pending
EOF
```

### Create from a YAML file

```bash
kubectl apply -f manifests/my-crd.yaml
```

### Delete a CRD

```bash
kubectl delete pb pb-60318-myapp -n paperclip-v3
```

### Delete all CRDs for a pipeline (use with caution)

```bash
kubectl delete pb -n paperclip-v3 -l pipeline=test-pipeline
```

---

## 6. CRD Schema & Definition

### View the CRD definition

```bash
kubectl get crd paperclipbuilds.paperclip.istayintek.com -o yaml
```

### List all registered CRD types

```bash
kubectl get crd | grep paperclip
```

### Describe CRD (shows schema, columns, subresources)

```bash
kubectl describe crd paperclipbuilds.paperclip.istayintek.com
```

---

## 7. Labels & Annotations

### Add/update a label

```bash
kubectl label pb pb-221-lpe -n paperclip-v3 priority=high
kubectl label pb pb-221-lpe -n paperclip-v3 priority=high --overwrite
```

### Remove a label

```bash
kubectl label pb pb-221-lpe -n paperclip-v3 priority-
```

### Add an annotation

```bash
kubectl annotate pb pb-221-lpe -n paperclip-v3 notes="needs manual review"
```

### Select by multiple labels

```bash
kubectl get pb -n paperclip-v3 -l "pipeline=v1,priority=high"
```

---

## 8. Namespace & Cluster Operations

### List all namespaces

```bash
kubectl get ns
```

### Key namespaces

```bash
kubectl get pods -n paperclip-v3     # CRDs, Redis, nginx, workers
kubectl get pods -n paperclip        # pc (v1 instance, scaled to 0)
kubectl get pods -n paperclip-v2     # pc-v2 (tech instance, scaled to 0)
kubectl get pods -n paperclip-v4     # pc-v4 (invest-bots instance)
kubectl get pods -n paperclip-v5     # pc-v5 (ecom instance)
kubectl get pods -n openfile         # OpenFile tax app
kubectl get pods -n direct-file      # Direct File tax app (scaled to 0)
```

### Cluster resource usage

```bash
kubectl top nodes
kubectl top pods -n paperclip-v3 --sort-by=memory
```

---

## 9. Secrets

### Extract a secret value

```bash
kubectl get secret redis-credentials -n paperclip-v3 \
  -o jsonpath='{.data.password}' | base64 -d
```

### Extract board API key (for PC instances)

```bash
kubectl get secret pc-v4-board-api-key -n paperclip-v4 \
  -o jsonpath='{.data.key}' | base64 -d
```

### List all secrets in a namespace

```bash
kubectl get secrets -n paperclip-v3
```

---

## 10. Pod Operations

### Get nginx pod (serves all app static files)

```bash
kubectl get pods -n paperclip-v3 -l app=nginx
```

### Copy files to/from nginx

```bash
# Deploy built files to nginx
kubectl cp ./dist/. nginx-paperclip-0:/usr/share/nginx/html/pb-221-lpe/ \
  -n paperclip-v3

# Download files from nginx
kubectl cp nginx-paperclip-0:/usr/share/nginx/html/pb-221-lpe/index.html \
  -n paperclip-v3 ./index.html
```

### Check if app files exist in nginx

```bash
kubectl exec -n paperclip-v3 nginx-paperclip-0 -- \
  ls /usr/share/nginx/html/pb-221-lpe/
```

### Shell into a pod

```bash
kubectl exec -it nginx-paperclip-0 -n paperclip-v3 -- /bin/sh
```

### View pod logs

```bash
kubectl logs nginx-paperclip-0 -n paperclip-v3
kubectl logs nginx-paperclip-0 -n paperclip-v3 --tail=50 -f
```

### Restart a deployment

```bash
kubectl rollout restart deploy/nginx -n paperclip-v3
```

---

## 11. Scale Operations

### Scale a deployment

```bash
kubectl scale deploy/pc-v4 -n paperclip-v4 --replicas=1
kubectl scale deploy/pc-v4 -n paperclip-v4 --replicas=0
```

### Scale all deployments in a namespace

```bash
kubectl scale deploy --all -n direct-file --replicas=1
kubectl scale sts --all -n direct-file --replicas=1
```

### Check current replicas

```bash
kubectl get deploy -n paperclip-v4 -o wide
```

---

## 12. Pipeline Registry (ConfigMap)

### View the pipeline registry

```bash
kubectl get configmap pipeline-registry -n paperclip-v3 -o yaml
```

### Use the registry helper script

```bash
source /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/pipeline-registry.sh

# List all 19 pipelines
list_pipelines

# Get PC instance for a pipeline
get_pc_instance "invest-bots"   # -> pc-v4

# Get namespace
get_namespace "invest-bots"     # -> paperclip-v4

# Get company ID range
get_id_range "v1"               # -> 201-400
```

---

## 13. Troubleshooting Patterns

### CRD stuck in Building

```bash
# Check how long it's been building
kubectl get pb pb-221-lpe -n paperclip-v3 \
  -o jsonpath='{.status.lastTransitionTime}'

# Force reset to Pending
kubectl patch pb pb-221-lpe -n paperclip-v3 \
  --type merge --subresource status \
  -p '{"status":{"phase":"Pending","buildError":""}}'
```

### Find CRDs with stale errors

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
for i in items:
    phase = i.get('status',{}).get('phase','')
    err = i.get('status',{}).get('buildError','')
    if phase == 'Deployed' and err:
        print(f'  {i[\"metadata\"][\"name\"]} — Deployed but has stale error: {err[:80]}')
"
```

### Verify CRD API version

```bash
# Must be v1alpha1, NOT v1 (v1 causes silent failures)
kubectl api-resources | grep paperclip
```

### Check CRD events

```bash
kubectl describe pb pb-221-lpe -n paperclip-v3 | tail -20
```

---

## 14. Useful Aliases

Add to `~/.bashrc`:

```bash
alias kpb='kubectl get pb -n paperclip-v3'
alias kpbw='kubectl get pb -n paperclip-v3 --watch'
alias kpbf='kubectl get pb -n paperclip-v3 -o custom-columns="NAME:.metadata.name,PHASE:.status.phase" | grep Failed'
alias kpbn='kubectl get pb -n paperclip-v3 -o custom-columns="NAME:.metadata.name,PHASE:.status.phase" | grep NoBuildScript'
alias kpbc='kubectl get pb -n paperclip-v3 -o json | python3 -c "import json,sys; from collections import Counter; items=json.load(sys.stdin)[\"items\"]; counts=Counter(i.get(\"status\",{}).get(\"phase\",\"?\") for i in items); [print(f\"  {p}: {n}\") for p,n in sorted(counts.items(), key=lambda x:-x[1])]; print(f\"  Total: {len(items)}\")"'
```

---

## Gotchas

| Pitfall | Details |
|---------|---------|
| API version | Use `v1alpha1` not `v1` — v1 silently fails |
| Status subresource | Phase patches MUST use `--subresource status` |
| Spec field | It's `appName` not `name` in the spec |
| No budget/email/type | CRD schema has NO budget, description, email, or type fields |
| Label selector | Pipeline label is lowercase: `pipeline=v1` not `pipeline=V1` |
| Namespace | Always `-n paperclip-v3` — CRDs are NOT in default namespace |
