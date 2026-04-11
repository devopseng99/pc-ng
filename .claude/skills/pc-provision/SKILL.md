---
name: pc-provision
description: Provision a new Paperclip instance end-to-end — Helm install, bootstrap (admin + API key + secrets), CF tunnel route, DNS, validation. Also supports teardown.
allowed-tools: Bash, Read
user-invocable: true
---

# PC-NG Provision New Instance

Provision or teardown a Paperclip instance by name.

## Arguments

- `NAME` (required) — Instance name, e.g. `pc-v5`. Derives namespace as `paperclip-v5`, slug as `pc-v5`.
- `--teardown` — Remove the instance entirely (Helm, tunnel, DNS, namespace, PVs)
- `--node NODE` — Target worker node (default: `mgplcb05`)
- `--email EMAIL` — Admin email (default: `hrsd0001@gmail.com`)
- `--dry-run` — Show what would be done without executing

## Argument Parsing

Parse the first positional argument as the instance name. Extract the version suffix to derive namespace and context:

```
NAME=pc-v5          ->  RELEASE=pc-v5, NAMESPACE=paperclip-v5, SLUG=pc-v5, CONTEXT=v5
NAME=pc-v6          ->  RELEASE=pc-v6, NAMESPACE=paperclip-v6, SLUG=pc-v6, CONTEXT=v6
```

If the name doesn't start with `pc-`, prefix it automatically.

## Steps

### Pre-flight Checks

1. Verify the Helm chart exists:
```bash
ls /var/lib/rancher/ansible/db/pc/pc-helm-charts/charts/pc/Chart.yaml 2>/dev/null || echo "MISSING: Helm chart not found"
```

2. Check if the instance already exists:
```bash
helm list -n ${NAMESPACE} 2>/dev/null | grep ${RELEASE}
kubectl get ns ${NAMESPACE} 2>/dev/null
```

3. Check CF token is available and not expired. Token may be in `~/cf-token--expires-apr-2` or another `~/cf-token*` file. The token is account-scoped (cfat_ prefix) — verify using the accounts endpoint, NOT /user/tokens/verify:
```bash
# Find the most recent CF token file
CF_TOKEN_FILE=$(ls -t ~/cf-token--expires-* 2>/dev/null | head -1)
[[ -z "$CF_TOKEN_FILE" ]] && echo "WARNING: No CF token file found"
# Token file may contain a curl command — extract raw token if so
CF_TOKEN=$(cat "$CF_TOKEN_FILE" | tr -d '\n\r\t ')
if echo "$CF_TOKEN" | grep -q "Bearer "; then
  CF_TOKEN=$(echo "$CF_TOKEN" | grep -oP 'Bearer \K\S+')
fi
echo "Token file: $CF_TOKEN_FILE (${#CF_TOKEN} chars)"
# Account-scoped tokens must verify at /accounts/{id}/tokens/verify
curl -sf -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/9709bd1f498109e65ff5d1898fec15ee/tokens/verify" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'CF Token: {d[\"result\"][\"status\"]} (expires {d[\"result\"][\"expires_on\"]})')" 2>/dev/null || echo "CF Token: INVALID or EXPIRED"
```

4. If `--dry-run`, print the plan and stop.

### Provision (default)

5. Run the provision script:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/provision-pc.sh \
  --release ${RELEASE} \
  --namespace ${NAMESPACE} \
  --slug ${SLUG} \
  --context ${CONTEXT} \
  --admin-email ${EMAIL} \
  ${NODE:+--node $NODE}
```

6. After provision completes, verify the full stack:
```bash
# Pod health
kubectl get pods -n ${NAMESPACE} -o wide

# External URL
curl -s https://${SLUG}.istayintek.com/api/health | python3 -m json.tool

# API key works
API_KEY=$(kubectl get secret ${RELEASE}-board-api-key -n ${NAMESPACE} -o jsonpath='{.data.key}' | base64 -d)
curl -s -H "Authorization: Bearer $API_KEY" https://${SLUG}.istayintek.com/api/companies | python3 -c "import json,sys; print(f'Companies: {len(json.load(sys.stdin))}')"
```

### Teardown (--teardown)

5. Run the teardown:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/provision-pc.sh \
  --release ${RELEASE} \
  --namespace ${NAMESPACE} \
  --teardown
```

6. Verify removal:
```bash
kubectl get ns ${NAMESPACE} 2>&1
helm list -n ${NAMESPACE} 2>&1
```

## Output Format

Present a clear summary:

**Provision success:**
| Field | Value |
|-------|-------|
| Release | pc-v5 |
| Namespace | paperclip-v5 |
| URL | https://pc-v5.istayintek.com |
| Admin | hrsd0001@gmail.com |
| API Key | `kubectl get secret pc-v5-board-api-key -n paperclip-v5 ...` |
| Pods | Running/Ready counts |

**Teardown success:**
- Confirm Helm release removed, tunnel route removed, DNS removed, namespace deleted.

## Important Notes

- The provision script creates persistent dirs on the target node via `kubectl debug node/`
- Helm values are written to `/var/lib/rancher/ansible/db/pc/overrides-${RELEASE}.yaml`
- The bootstrap step (Step 14 in provision-pc.sh) auto-creates admin user + API key + K8s secrets
- `instance_user_roles` must have `instance_admin` for the API key to work (bootstrap-instance.sh handles this)
- CF tunnel route is added to the REMOTE API config (not just the ConfigMap) — this is critical
- After provisioning, remember to update pipeline-to-instance mapping if this instance will serve pipeline apps
