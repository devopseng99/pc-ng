# PC-NG Pipeline Task List

Last updated: 2026-03-30 14:40

## Current State
| Phase | Count |
|---|---|
| Deployed | 169 |
| Deploying | 218 (code on GH, ready for Phase B) |
| Pending | 27 (actively building) |
| Building | 2 |
| Failed | 0 |

**Showroom**: https://showroom.istayintek.com — synced (416/416), 7 Redis subscribers, live SSE

## Pipeline IDs & Manifests
| Pipeline | Manifest | Status |
|---|---|---|
| `v1` | `use-cases-201-400.json` | Complete |
| `tech` | `use-cases-401-600.json` | 27 pending, actively building |
| `wasm` | `wasm-sandbox-apps.json` | Ready (15 apps) |
| `soa` | `pc-soa-v3-templates.json` | Ready (20 apps) |

## Start Commands
```bash
# Original pipelines (v1 + tech)
bash pipeline/scripts/workers-start.sh --concurrency 2

# Specific pipeline
bash pipeline/scripts/workers-start.sh --pipeline wasm --concurrency 2
bash pipeline/scripts/workers-start.sh --pipeline soa --concurrency 2
```

---

## Active Tasks

### Phase A — Codegen Remaining (~27 apps from tech)
- [x] Usage cap reset confirmed
- [x] Workers started (`/pc-start --concurrency 2`)
- [ ] Monitor via `/pc-status` or showroom
- [ ] Verify all complete (Pending → Deploying) — ETA ~1 hour

### Phase B — Deploy (218+ apps in queue)
- [ ] Run batch deploy: `bash pipeline/scripts/batch-deploy-k8s.sh`
- [ ] Verify CF tunnel routes and DNS records
- [ ] Check pod health for all new deployments

### WASM & Sandbox Apps (15 apps)
- [x] Manifest: `pipeline/manifests/wasm-sandbox-apps.json`
- [x] `wasm` case in `workers-start.sh`
- [x] "WASM & Sandbox Runtimes" category in `generate-prompt.sh`
- [ ] Start: `bash pipeline/scripts/workers-start.sh --pipeline wasm --concurrency 2`
- [ ] Deploy via Phase B

### PC-SOA-V3 — Next-Gen Templates (20 apps)
- [x] Manifest: `pipeline/manifests/pc-soa-v3-templates.json`
- [x] `soa` case in `workers-start.sh`
- [x] "Next-Gen UI Platform" category in `generate-prompt.sh`
- [x] Astro + Vite + shadcn/ui + Framer Motion stack in prompt generator
- [x] Mono-repo structure (Turborepo + pnpm workspaces) in prompt template
- [ ] Start: `bash pipeline/scripts/workers-start.sh --pipeline soa --concurrency 2`
- [ ] Deploy via Phase B

### Infrastructure
- [ ] CF tunnel token renewal (expires 2026-04-01 — 2 days)
- [ ] Investigate 3 pods not running
- [ ] Clean up /tmp build artifacts (12 completed repos)

---

## Completed
- [x] Phase A codegen: v1 pipeline — 31 built, 0 failed
- [x] Phase A codegen: tech pipeline — 53 built initially, 68 usage-cap, now building remaining
- [x] Circuit breaker: usage-cap → worker EXIT (exit 3)
- [x] Circuit breaker: hard-stop after 10 consecutive fails → halt + EXIT (exit 4)
- [x] CRD phase fix: code-pushed → "Deploying" not "Building"
- [x] Emergency halt + operations runbook (EMERGENCY-OPS.md)
- [x] Claude Code skills (pc-status, pc-halt, pc-start, pc-deploy, pc-reset)
- [x] Git push fixes (.gitignore injection, token stripping, git ref API)
- [x] Pipeline supervisor (30s monitoring loop)
- [x] Path audit — all skills/scripts consistent
- [x] Showroom sync verified (416/416, CRD watch + Redis pub/sub active)
- [x] pc-status skill updated with showroom health check
- [x] Memory updated with showroom reference + all learnings
