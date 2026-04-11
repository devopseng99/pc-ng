# Paperclip Platform — Endpoints & Connection Reference

## Paperclip Instances

| Instance | External URL | Internal Service | Namespace | Version |
|---|---|---|---|---|
| **pc** | `https://pc.istayintek.com` | `pc.paperclip.svc.cluster.local:3100` | paperclip | 0.3.1 |
| **pc-v2** | `https://pc-v2.istayintek.com` | `pc-v2.paperclip-v2.svc.cluster.local:3100` | paperclip-v2 | 0.3.1 |
| **pc-v4** | `https://pc-v4.istayintek.com` | `pc-v4.paperclip-v4.svc.cluster.local:3100` | paperclip-v4 | 0.3.1 |
| **pc-v5** | `https://pc-v5.istayintek.com` | `pc-v5.paperclip-v5.svc.cluster.local:3100` | paperclip-v5 | 0.3.1 |

### Pipeline → Instance Mapping

| Pipeline | Instance | Companies |
|---|---|---|
| v1 (213 apps) | pc | 218 |
| tech (203 apps) | pc-v2 | 204 |
| wasm/soa/ai/cf/mcp/ecom/crypto/invest (205 apps) | pc-v4 | 206 |
| external-ops (17 companies, separate purpose) | pc-v5 | 17 |

Mapping implemented in `phase-a-codegen.sh` via `resolve_pc_instance()`.

---

## Paperclip API Routes

All routes require `Authorization: Bearer <BOARD_API_KEY>` unless noted.

### Health & Auth (no auth required)

| Method | Route | Notes |
|---|---|---|
| GET | `/api/health` | Returns status, version, bootstrapStatus |
| POST | `/api/auth/sign-up/email` | Body: `{email, password, name}` — creates user |
| POST | `/api/auth/sign-in/email` | Body: `{email, password}` — returns session token |

### Board-Level (board API key auth)

| Method | Route | Notes |
|---|---|---|
| GET | `/api/companies` | List all companies (returns array) |
| POST | `/api/companies` | Create company: `{name, issuePrefix, budgetMonthlyCents}` |
| GET | `/api/companies/:id` | Single company details |
| GET | `/api/plugins` | List installed plugins |
| POST | `/api/plugins/install` | Install plugin |

### Company-Scoped

| Method | Route | Notes |
|---|---|---|
| GET | `/api/companies/:companyId/issues` | List issues (supports `?limit=N`) |
| GET | `/api/companies/:companyId/agents` | List agents |
| GET | `/api/companies/:companyId/goals` | Goal hierarchy |
| GET | `/api/companies/:companyId/members` | Team members |
| GET | `/api/companies/:companyId/activity` | Activity log |
| GET | `/api/companies/:companyId/secrets` | Company secrets |
| GET | `/api/companies/:companyId/skills` | Attached skills |

### Issue-Scoped

| Method | Route | Notes |
|---|---|---|
| GET | `/api/issues/:issueId` | Single issue |
| PATCH | `/api/issues/:issueId` | Update issue (e.g. `{status: "todo"}`) |
| GET | `/api/issues/:issueId/comments` | Issue comments |
| GET | `/api/issues/:issueId/attachments` | Attachments |

### Agent-Scoped

| Method | Route | Notes |
|---|---|---|
| GET | `/api/agents/:agentId` | Agent details |

---

## Showroom Dashboard

| | |
|---|---|
| **URL** | `https://showroom.istayintek.com` |
| **Internal** | `pc-showroom-app.pc-showroom.svc.cluster.local:80` |
| **Source** | `/var/lib/rancher/ansible/db/pc-agui` |

### Showroom API

| Method | Route | Notes |
|---|---|---|
| GET | `/api/health` | DB status, SSE clients, memory, uptime |
| GET | `/api/apps` | App listing (`?limit=N&phase=X&category=X&search=X`) |
| GET | `/api/apps/:id` | Single app with build events |
| GET | `/api/events` | SSE stream (live real-time updates) |
| GET | `/api/ui-config` | Active AGUI layout config |

---

## Database Connections

| Instance | Pod | Host | Port | DB | User |
|---|---|---|---|---|---|
| pc | `pc-postgresql-0` | `pc-postgresql.paperclip.svc.cluster.local` | 5432 | paperclip | postgres |
| pc-v2 | `pc-v2-postgresql-0` | `pc-v2-postgresql.paperclip-v2.svc.cluster.local` | 5432 | paperclip | postgres |
| pc-v4 | `pc-v4-postgresql-0` | `pc-v4-postgresql.paperclip-v4.svc.cluster.local` | 5432 | paperclip | postgres |
| pc-v5 | `pc-v5-postgresql-0` | `pc-v5-postgresql.paperclip-v5.svc.cluster.local` | 5432 | paperclip | postgres |
| showroom | `showroom-pg-0` | `showroom-pg.pc-showroom.svc.cluster.local` | 5432 | — | — |

### Quick DB Access
```bash
# Direct psql into any instance
kubectl exec pc-postgresql-0 -n paperclip -- psql -U postgres -d paperclip
kubectl exec pc-v2-postgresql-0 -n paperclip-v2 -- psql -U postgres -d paperclip
kubectl exec pc-v4-postgresql-0 -n paperclip-v4 -- psql -U postgres -d paperclip
kubectl exec pc-v5-postgresql-0 -n paperclip-v5 -- psql -U postgres -d paperclip
```

### Key DB Tables (46 tables reference company_id)

| Table | Purpose |
|---|---|
| `companies` | Company records (name, issuePrefix, budget) |
| `agents` | AI agents (1 per company from onboarding) |
| `goals` | Goal hierarchy (6 per company from onboarding) |
| `issues` | Tasks/issues (10 per company from onboarding) |
| `activity_log` | Audit trail of all actions |
| `agent_task_sessions` | Agent work sessions |
| `agent_runtime_state` | Token usage, cost, last run status |
| `heartbeat_runs` | Agent execution history |
| `cost_events` | API cost tracking |
| `issue_comments` | Agent work product comments |
| `board_api_keys` | API key hashes for auth |
| `instance_user_roles` | Admin role grants (must be `instance_admin`) |

---

## K8s Secrets

| Secret | Namespace | Keys | Purpose |
|---|---|---|---|
| `pc-board-api-key` | paperclip | `key` | Board API key for pc |
| `pc-v2-board-api-key` | paperclip-v2 | `key` | Board API key for pc-v2 |
| `pc-v2-board-api-key` | paperclip-v3 | `key` | Cross-namespace copy |
| `pc-v2-admin-credentials` | paperclip-v2 | `email, password, name, user-id, api-key` | Admin creds |
| `pc-v4-board-api-key` | paperclip-v4 | `key` | Board API key for pc-v4 |
| `pc-v4-board-api-key` | paperclip-v3 | `key` | Cross-namespace copy |
| `pc-v4-admin-credentials` | paperclip-v4 | `email, password, name, user-id, api-key` | Admin creds |
| `pc-v5-board-api-key` | paperclip-v5 | `key` | Board API key for pc-v5 |
| `pc-v5-board-api-key` | paperclip-v3 | `key` | Cross-namespace copy |
| `pc-v5-admin-credentials` | paperclip-v5 | `email, password, name, user-id, api-key` | Admin creds |
| `pc-postgres-secret` | paperclip | `postgres-password` | PG password |
| `pc-v2-postgres-secret` | paperclip-v2 | `postgres-password` | PG password |
| `pc-v4-postgres-secret` | paperclip-v4 | `postgres-password` | PG password |
| `pc-v5-postgres-secret` | paperclip-v5 | `postgres-password` | PG password |
| `redis-credentials` | paperclip-v3 | `password` | Redis auth |

### Retrieve API Keys
```bash
kubectl get secret pc-board-api-key -n paperclip -o jsonpath='{.data.key}' | base64 -d
kubectl get secret pc-v2-board-api-key -n paperclip-v2 -o jsonpath='{.data.key}' | base64 -d
kubectl get secret pc-v4-board-api-key -n paperclip-v4 -o jsonpath='{.data.key}' | base64 -d
kubectl get secret pc-v5-board-api-key -n paperclip-v5 -o jsonpath='{.data.key}' | base64 -d
```

---

## Redis

| | |
|---|---|
| **Host** | `redis-pc-ng-master.paperclip-v3.svc.cluster.local` |
| **Port** | 6379 |
| **Secret** | `redis-credentials` in `paperclip-v3` |
| **Pub/Sub Channel** | `pipeline:events` |

Used by showroom for real-time CRD event streaming.

---

## Cloudflare Tunnel

| | |
|---|---|
| **Tunnel Name** | `rke2mgmtonly` |
| **Namespace** | `cfd` |
| **Deployment** | `rke2mgmtonly-cfd-cloudflare-tunnel` |
| **ConfigMap** | `rke2mgmtonly-cfd-cloudflare-tunnel` in `cfd` |
| **Token** | `~/cf-token--expires-apr-2` (expires 2026-04-02) |

### Tunnel Ingress Routes

| Hostname | Backend Service |
|---|---|
| `pc.istayintek.com` | `http://pc.paperclip.svc.cluster.local:3100` |
| `pc-v2.istayintek.com` | `http://pc-v2.paperclip-v2.svc.cluster.local:3100` |
| `pc-v4.istayintek.com` | `http://pc-v4.paperclip-v4.svc.cluster.local:3100` |
| `pc-v5.istayintek.com` | `http://pc-v5.paperclip-v5.svc.cluster.local:3100` |
| `showroom.istayintek.com` | `http://pc-showroom-app.pc-showroom.svc.cluster.local:80` |
| `*.istayintek.com` (apps) | `http://{app-name}.paperclip.svc.cluster.local:80` |
| Catch-all | `http_status:404` |

### Adding Tunnel Routes (Phase B deploy)
```bash
# batch-deploy-k8s.sh adds routes via CF API:
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/{TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"config":{"ingress":[...existing + new route...]}}'
```

---

## Pipeline Infrastructure

| Component | Namespace | Purpose |
|---|---|---|
| PaperclipBuild CRDs | paperclip-v3 | Build state tracking (561 CRDs) |
| Redis | paperclip-v3 | Event pub/sub for showroom |
| Showroom app | pc-showroom | Live dashboard |
| Showroom PG | pc-showroom | App data + UI config |
| App pods (72 deployed) | paperclip | Static nginx pods for v1 apps |
| CF tunnel | cfd | External HTTPS routing |

### CRD Quick Reference
```bash
kubectl get pb -n paperclip-v3                    # List all builds
kubectl get pb -n paperclip-v3 -o wide            # With details
kubectl patch pb <name> -n paperclip-v3 \
  --type merge --subresource=status \
  -p '{"status":{"phase":"Pending"}}'              # Reset a CRD
```

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `pipeline/scripts/phase-a-codegen.sh` | Phase A: AI codegen + GitHub push |
| `pipeline/scripts/batch-deploy-k8s.sh` | Phase B: K8s pod + CF tunnel deploy |
| `pipeline/scripts/bootstrap-instance.sh` | Bootstrap new PC instance (user + API key + secrets) |
| `pipeline/scripts/bulk-onboard.sh` | Batch company creation across instances |
| `pipeline/scripts/workers-start.sh` | Start pipeline workers |
| `pipeline/scripts/workers-status.sh` | Status check |
| `pipeline/scripts/emergency-halt.sh` | Kill all workers |
| `pipeline/scripts/generate-prompt.sh` | Build prompt generator |
