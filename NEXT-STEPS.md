# Paperclip Pipeline — Next Steps

## URGENT (2026-05-03)

### 1. Phase B for 16 Deploying Apps — AGENTS ACTIVE
- invest-bots: 9 remaining (6 deployed, worker #6 completed $0.30)
- v1: 3, cf: 1, deep-trade: 1, ecom: 2
- Builds deploy to shared nginx (static-sites ns) — does NOT need pc/pc-v2 up
- **Autonomous:** Dispatcher spawns workers from supervisor tasks. Re-run invest-bots worker for remaining 9.

### 2. Build-Fix on 86 Failed — AGENTS ACTIVE
- v1 build-fix worker #8 RUNNING (PID active, processing 5/34)
- soa build-fix worker #7 RUNNING (PID active, processing 5/18)
- Remaining: tech (17), api-jobs (8), cf (3), ai (2), crypto (1), retail (1), ecom (1), mcp (1)
- Next supervisor run will pick up remaining pipelines

### 3. Host Resource Monitoring & Agent HUD
- 12+ stale claude processes (Mar 30–Apr 25) consuming ~6.5GB RAM
- /var/lib/rancher at 90% disk (45/50GB) — needs cleanup
- Use `bash agents/hud.sh` for one-screen view of agents, resources, progress

### 4. Phase A for 2 Pending + 20 NoBuildScript Apps
- 2 Pending CRDs in v1 — long-name variant repos
- 20 NoBuildScript: wasm (4), tech (8), ai (3), cf (4), mcp (1)

---

## SHORT TERM

### 6. Direct File Namespace — Scaled to Zero
- All deployments and statefulsets in `direct-file` ns at 0/0 replicas (discovered 2026-04-21)
- OpenFile namespace still running (5/5 pods, all 1/1 Running, uptime ~6d)
- Likely scaled down in isolated pc-v7 session — check if intentional or resource pressure
- To restore: `kubectl scale deploy --all --replicas=1 -n direct-file && kubectl scale sts --all --replicas=1 -n direct-file`

### 7. OpenFile & Direct File — Factgraph Fix
- Both APIs have factgraph disabled (ClassCastException workaround)
- Upstream fix: IRS-Public/fact-graph PR #82 (commit `79a9529`)
- Need: merge upstream fix → rebuild API image → set `LOAD_AT_STARTUP=true` → redeploy
- **Managed in isolated pc-v7 session**

### 8. SOA Pipeline Rework
- 18/20 Failed (90%) — worst pipeline by far
- Root cause: turbo-astro broken imports/missing output
- Use build-fix-loop first before reworking prompts

### 9. API-Jobs Pipeline Triage
- 8/20 Failed (40%) — second worst
- Run build-fix-loop first, then assess remaining failures

### 10. Per-Pod Deploy Cleanup
- ~74 remaining per-pod deploys in paperclip namespace (all replicas=0, disabled)
- Pattern: verify nginx has files → delete deploy+svc+tunnel → if no files, reset CRD to Deploying

### 11. Scale Up pc/pc-v2 for Onboarding Only (NOT for builds)
- Builds deploy to shared nginx — does NOT need PC instances up
- pc + pc-v2 only needed if new companies must be created (onboarding)
- All existing CRDs already have companies — scaling up is low priority
- pc (v1): 0/0 for 39 days. pc-v2 (tech): 0/0 for similar period.

---

## MEDIUM TERM

### 12. Skill Registry — MCP Server
- Wrap skill operations as MCP tools → available as native tools in ANY Claude session without synced files
- Auth, logging, remote triggers (CI/cron)
- See `~/claude-skills/README.md` for architecture

### 13. Codegen Quality Improvements
- 85 Failed + 20 NoBuildScript = 105 apps needing attention (13%)
- Per-pipeline prompt tuning for problem categories (soa, api-jobs)

### 14. Pipeline Monitoring Hardening
- `agents/hud.sh` provides one-screen view (agents, resources, progress)
- Formalize supervisor→dispatcher→worker loop as cron (currently manual)
- Add alerting: Slack/email on worker completion or circuit breaker trips

### 15. CF Token Automation
- Current token expires 2026-11-30 (`~/cf-token--expires-nov-30-2026`)

### 16. SDK Agent Intake — Push to GitHub
- `/var/lib/rancher/ansible/db/sdk-agent-intake` has no remote yet
- `--skill` flag and config-level `skill:` field working locally
- Needs remote repo creation + initial push

---

## COMPLETED

- [x] **Composable profile system** (2026-05-03) — v3.0.0. 3-layer profiles (capability/domain/composite) with `include:` and `layer:` fields. Recursive resolver with cycle detection. Multi-profile `--init`. Smart two-pass detection. 10 profiles across 3 layers.
- [x] **Skill consolidation — 3-phase** (2026-05-03) — 45→34 skills. Phase 1 (dedup), Phase 2 (universal skills with embedded gotchas), Phase 3 (test-suite replaces 5 test skills). 11 orphan dirs cleaned up.
- [x] **SDK agent intake integration** (2026-05-03) — `intake.py` has `--skill` flag + config-level `skill:` field. 3-level resolution: local→registry→prefixed. `bootstrap-project.sh --for-intake` creates symlinks + config template.
- [x] **Use-case guides** (2026-05-03) — 3 guides in `~/claude-skills/guides/`: container-build, k8s-deploy, test-suite. Common failures + use cases per universal skill.
- [x] **bootstrap-project.sh** (2026-05-03) — One-command onboarding. `--profile`, `--with-claude-md`, `--for-intake`, `--dry-run`. Generates manifests, CLAUDE.md, intake symlinks.
- [x] **Versioned skill registry** (2026-05-02→05-03) — 34 skills in `devopseng99/claude-skills` at v3.0.0. `skill-sync.sh` (~1400 lines, 17+ flags). All 6 projects synced. `skill-analyze.sh` for reports.
- [x] **pc-ng-v2 agent control plane** (2026-05-03) — Supervisor, dispatcher, build-fix agents. #N- session numbering, audit hooks, 365d retention. Dispatcher stdin-inheritance bug fixed.
- [x] **First autonomous run** (2026-05-03) — Supervisor produced 3 tasks ($0.20). Dispatcher spawned 3 workers. invest-bots: 6/15 deployed ($0.30). soa + v1 fix workers active.
- [x] **CF Pages cleanup** (2026-05-03) — Deleted 95 duplicate CF Pages projects (all had nginx equivalents). 5 remaining: sui, pc-showroom, tech-showroom + 2 beauty apps added as CRDs.
- [x] **pc-v4 scaled up** (2026-05-03) — pc-v4 running (1/1 app + 1/1 PG, 336 companies). Ready for invest-bots Phase B.
- [x] **811 total CRDs** (2026-05-03) — Added pb-60316-znb (ZR Nail Beauty) + pb-60317-zbs (Zuzu Beauty Salon) to ecom pipeline.
- [x] **OpenFile & Direct File APIs LIVE** (2026-04-13) — Both IRS tax apps fully running on pc-v7. Spring Boot API + React + PG + Redis + LocalStack per namespace. Factgraph disabled (upstream fix needed), all 4 URLs returning 200.
- [x] **invest-bots Phase A complete** (2026-04-13) — 19th pipeline, 15 AI trading bots. All 15/15 code on GitHub, all Deploying. 809 total CRDs.
- [x] **pc-v7 provisioned + populated** (2026-04-13) — Instance at https://pc-v7.istayintek.com. Hosts OpenFile + Direct File (2 companies). NOT for pipeline apps.
- [x] **CF tunnel wildcard ordering fix** (2026-04-13) — `provision-pc.sh` insert(-1) → insert before wildcard.
- [x] **Openfile + Direct File tunnel entries** (2026-04-13) — 4 tunnel routes (2 per app) + DNS CNAMEs.
- [x] **deep-trade pipeline** (2026-04-13) — 18th pipeline, 15 AI research dashboards. **14/15 Deployed (93%)**.
- [x] **Dual-variant orphan model** (2026-04-13) — 29 pre-pipeline apps get TWO CRDs each. 794→809 total CRDs.
- [x] **ziprun-courier cleanup** (2026-04-13) — Template for remaining 74 per-pod cleanups.
- [x] **Deploy target audit** (2026-04-12) — 3 layers: nginx (654), CF Pages (97), K8s pods (75 disabled).
- [x] **Phase B first full run** (2026-04-12) — 629/721 Deployed (87.2%)
- [x] **Phase B automation** — `/pc-build`, `/pc-build-fix`, `--auto-build` flag, `build-fix-loop.sh`
- [x] **Phase A — all 19 pipelines complete** — all apps have code on GitHub
- [x] **5 new pipelines (2026-04-12)** — retail, flink-ai, etl-edi, tradebot, api-jobs
- [x] **7 pipelines at 100%** — invest, etl-edi, flink-ai, tradebot, saas, streaming + crypto (19/20)
- [x] **Pipeline Registry ConfigMap** — all scripts + skills use dynamic discovery
- [x] Pipeline creation tooling — `.def` → `generate-manifest.sh` → `new-pipeline.sh`
- [x] Bulk onboarding — 760+ companies across 4 instances (zero dupes)
- [x] Showroom deployed — CRD watch + Redis sub, 809 apps synced
- [x] CF token renewed to 2026-11-30
