# Paperclip Pipeline — Next Steps

## URGENT (2026-05-03)

### 1. ~~Phase A for 20 NoBuildScript Apps~~ — DONE
- All 20 NoBuildScript CRDs fixed and deployed by build-fix agents (2026-05-03 20:35 CT)
- Cost: $5.82 total (~$0.29/app), ~12 min wall time
- **811/811 Deployed (100%), 19/19 pipelines at 100%**

### 2. Production Agentic Enablement
- Autoloop proved autonomous agent orchestration works (9 rounds, 63 deploys, 0 human intervention)
- Need to formalize as persistent infrastructure — see `docs/agentic-enablement-options.md`
- Key decision: cron-triggered vs event-driven vs always-on daemon

### 3. Host Resource Cleanup
- /var/lib/rancher at 91% disk (46/50GB) — full inventory in this session
- ~11GB recoverable from stale backups/installs (bk-gastown 3.6G, apps/IntelliJ 2.5G, data-flink-training 2.7G, etc.)
- Review before deleting to preserve task history

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

### 8. ~~SOA + API-Jobs Pipelines~~ — 100% DEPLOYED
- Both fully cleared by autoloop (soa 20/20, api-jobs 20/20)

### 9. Per-Pod Deploy Cleanup
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

### 13. ~~Codegen Quality Improvements~~ — RESOLVED
- All 811 apps now Deployed (0 Failed, 0 NoBuildScript)
- Build-fix agents handled all quality issues autonomously

### 14. Pipeline Monitoring Hardening — AUTOLOOP PROVEN
- `autoloop.sh` proved the full loop works autonomously (9 rounds, 87 min, 63 deploys)
- Need: cron entry or systemd timer to run autoloop on schedule
- Need: Slack/email notifications on round completion or circuit breaker trips
- Need: persistent monitoring dashboard (showroom already has SSE infra)

### 15. CF Token Automation
- Current token expires 2026-11-30 (`~/cf-token--expires-nov-30-2026`)

### 16. SDK Agent Intake — ADLC Evolution
- Repo live at `devopseng99/sdk-agent-intake` (private, 4 branches pushed)
- Current: 30+ app configs, deploy-app-scaffold skill, intake.py harness v2.0.0
- Next: compound versioning (prompt+model+schema tuple), expand-and-contract migrations
- Next: OpenFeature flags for per-pipeline agent A/B testing
- Next: Langfuse self-hosted for trace/cost/prompt observability

---

## COMPLETED

- [x] **Composable profile system** (2026-05-03) — v3.0.0. 3-layer profiles (capability/domain/composite) with `include:` and `layer:` fields. Recursive resolver with cycle detection. Multi-profile `--init`. Smart two-pass detection. 10 profiles across 3 layers.
- [x] **Skill consolidation — 3-phase** (2026-05-03) — 45→34 skills. Phase 1 (dedup), Phase 2 (universal skills with embedded gotchas), Phase 3 (test-suite replaces 5 test skills). 11 orphan dirs cleaned up.
- [x] **SDK agent intake integration** (2026-05-03) — `intake.py` has `--skill` flag + config-level `skill:` field. 3-level resolution: local→registry→prefixed. `bootstrap-project.sh --for-intake` creates symlinks + config template.
- [x] **Use-case guides** (2026-05-03) — 3 guides in `~/claude-skills/guides/`: container-build, k8s-deploy, test-suite. Common failures + use cases per universal skill.
- [x] **bootstrap-project.sh** (2026-05-03) — One-command onboarding. `--profile`, `--with-claude-md`, `--for-intake`, `--dry-run`. Generates manifests, CLAUDE.md, intake symlinks.
- [x] **Versioned skill registry** (2026-05-02→05-03) — 34 skills in `devopseng99/claude-skills` at v3.0.0. `skill-sync.sh` (~1400 lines, 17+ flags). All 6 projects synced. `skill-analyze.sh` for reports.
- [x] **pc-ng-v2 agent control plane** (2026-05-03) — Supervisor, dispatcher, build-fix agents. #N- session numbering, audit hooks, 365d retention. Dispatcher stdin-inheritance bug fixed.
- [x] **811/811 Deployed — 100% Pipeline Complete** (2026-05-03) — Build-fix agents cleared final 20 NoBuildScript CRDs. $5.82 total, ~12 min. All 19/19 pipelines at 100%.
- [x] **Autoloop clears ALL actionable CRDs** (2026-05-03) — 9 rounds, ~87 min, fully autonomous. 728→791 Deployed (+63). 0 Pending, 0 Failed, 0 Deploying. 14 pipelines at 100%.
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
