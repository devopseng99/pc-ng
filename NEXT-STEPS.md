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

### 16. ~~SDK Agent Intake — ADLC Evolution~~ — v2.2.0 RELEASED
- OpenFeature flags, agent replay, intake templates, multi-cluster, audit logging all IMPLEMENTED
- v2.2.0: External chart search, pod resilience (5 iterations), browser verify, Bitnami legacy defaults
- OpenHands deployed successfully via v2.2.0 ($3.00, 22 min, 6/6 pods, community chart discovered)
- Remaining: compound versioning (prompt+model+schema tuple), expand-and-contract migrations

### 17. ~~ADLC Remaining Phases (5-7)~~ — DONE
- **Phase 5:** OpenFeature flags — IMPLEMENTED (openfeature.py, `--flags`, `_flags.yaml`, deterministic A/B bucketing)
- **Phase 6:** intake-hud.sh — IMPLEMENTED (real-time terminal HUD, `--watch`, `--pipeline`, `--json`)
- **Phase 7:** Multi-cluster — IMPLEMENTED (cluster.py, `--cluster`, `clusters.yaml`, CRD `spec.targetCluster`)
- Full plan: `docs/ADLC-PLAN.md`

### 18. ~~Agent-Intake-Controller~~ — v1.3.0 LIVE (real builds)
- Plugin system: 5 lifecycle phases, 4 built-in plugins, CRD hooks[] field
- CRD garbage collection: kopf daemon, configurable retention, monthly archive ConfigMaps
- **v1.3.0** (2026-05-05): `build_runner.py` wired — controller spawns `claude -p` subprocess, generates real code
- Tested: Go API service generated (Dockerfile, Helm chart, K8s manifests, health probes, graceful shutdown)
- **Constraint:** In-cluster pod lacks claude CLI; run locally until registry restored for image rebuild
- Next: fix async status propagation (buildPid, buildCostUsd not reaching CRD); integrate with Langfuse tracing
- 10 test CRs ready in `pc-ng/files/cr-*.yaml` (validated against real schema)

### 20. ~~ai-hedge-fund Full-Stack Frontend~~ — DONE
- Full-stack same-origin deployment live at `https://ai-hedge-fund.istayintek.com` (v1.1.0)
- Multi-stage Dockerfile: node builds React SPA → Python serves static + API on port 8501
- Zero CORS — `VITE_API_URL=""` makes all API calls relative (same origin)

### 19. ADLC Outstanding Items
- [x] Phase 2.5: Builder bumped to v1.2.0-r1 (multi-cluster, flags, 112 tests)
- [x] Phase 3B.5: ai-hedge-fund full-stack SPA deployed (v1.1.0)
- [~] Phase 3A.4: LangfuseTracer module wired into builder.py + intake.py, .env.langfuse created — **need to verify traces in UI**
- [ ] Phase 3B.6: Verify ai-hedge-fund with real API keys
- [~] Phase 4.2: Post-build hook wired (langfuse_trace.py shared module) — **need env vars injected into running pods**
- [ ] Phase 4.3: Verify JSONL converter → Langfuse trace visible at https://cto.istayintek.com

### 22. ~~SDK Agent Intake — Playwright Browser Validation~~ — v2.3.0 RELEASED
- `browser-verify` skill created (universal, capability layer) — wraps Playwright MCP via kubectl exec
- Task 17d: Playwright deep verification integrated into scaffold skill
- `--browser-verify` CLI flag + `BROWSER_VERIFY` env var for opt-in
- JSON eval report: checks, screenshots, timing, pass/fail
- Validated against OpenHands: 7/7 checks PASS, screenshot captured
- **Remaining:** GitHub App setup for OpenHands (to get past identity provider setup screen → coding workspace)

### 23. OpenHands Auth — GitHub Login Fixed (2026-05-07)
- 6-stage fix chain: admin user, CF bypass, token issuer, LiteLLM skip, offline token loop, /login redirect loop
- Persistent patches via ConfigMap `openhands-auth-patches` (3 runtime patches survive pod restarts)
- `KC_PROXY_HEADERS=xforwarded`, `offline_access` in default client scopes, `LOCAL_DEPLOYMENT=true`
- **Remaining:** Verify login works end-to-end in browser; persist env changes to overrides.yaml; update overrides.yaml with all env vars

### 24. SDK Agent Intake — Browser Eval Enhancement (PROPOSED)
- Current browser-verify validates basic rendering (title, elements, screenshots)
- **Need:** Full eval report output from Playwright validation of UI + specific functionalities
- Expand eval report: login flow verification, form submission, API call tracing, error state testing
- Integrate with sdk-agent-intake as post-deploy validation stage (not just basic health check)
- Consider: headless browser eval as a reusable skill pattern for any SPA deployment

### 21. Orcha-Master — Integration & Evolution
- [x] v1.0.0 built and pushed to devopseng99/orcha-master (2026-05-04)
- [x] v1.1.0 released (2026-05-04): `orcha exec` direct execution mode — spawns claude subprocesses, parallel/sequential, timeout/kill, stream-json cost parsing, 57 tests
- [x] Real-world integration test: multi-repo queue validated (conflict detection, filtering, partition-key sequencing)
- [ ] Hook into pc-ng-v2 dispatcher: replace ad-hoc supervisor→dispatcher with orcha queue format
- [ ] v1.2.0: Depends-on graph resolution (topological sort, not just partition-key sequencing)
- [ ] v1.2.0: Cost tracking post-execution (aggregate per-task costs into reports + budget ledger)
- [ ] GitHub Actions integration: trigger orcha dispatch from CI on label/comment

---

## COMPLETED

- [x] **OpenHands Auth Fixed** (2026-05-07) — 6-stage fix chain for GitHub OAuth login. Keycloak admin, CF bypass, token issuer, LiteLLM skip, offline token loop, /login redirect loop. Persistent patches via ConfigMap. `openhands.istayintek.com` login flow completes end-to-end.
- [x] **SDK Agent Intake v2.3.0** (2026-05-06) — Playwright browser verification (Task 17d), `--browser-verify` CLI flag, kubectl exec MCP transport, JSON eval reports with screenshots. OpenHands: 7/7 checks PASS. `devopseng99/sdk-agent-intake` tag v2.3.0.
- [x] **browser-verify skill** (2026-05-06) — Universal Playwright MCP skill in `devopseng99/claude-skills`. kubectl exec transport, 15 tools, eval report format. Added to `container-ops` profile (now 3 skills).
- [x] **SDK Agent Intake v2.2.0** (2026-05-05) — External chart search (GitHub org + Artifact Hub), pod failure resilience (5 iterations, never BLOCKED early), browser verification, Bitnami legacy defaults. Validated with OpenHands: $3.00, 22 min, 6/6 pods, community chart discovered. `devopseng99/sdk-agent-intake` branch PIT-003.
- [x] **OpenHands deployed** (2026-05-05) — Full-stack AI coding platform at `openhands.istayintek.com`. Community chart from `All-Hands-AI/OpenHands-Cloud`, keycloak/litellm/runtime-api disabled. 6 pods running, CF tunnel routed.
- [x] **Agent-Intake-Controller v1.3.0** (2026-05-05) — Real builds via claude subprocess. `build_runner.py` async manager, prompt construction from CRD spec, timer-based polling, phase detection from stream output. Tested end-to-end: CR → Go API service generated. `devopseng99/agent-intake-controller`.
- [x] **Orcha-Master v1.1.0** (2026-05-04) — Added `orcha exec` direct execution (subprocess spawning, parallel/sequential, timeout/kill, stream-json parsing). 57 tests. Integration test validated. `devopseng99/orcha-master`.
- [x] **Orcha-Master v1.0.0** (2026-05-04) — Parallel agent orchestrator. YAML work queues → classifier → dispatcher → Claude Code agents. Budget enforcement, circuit breakers, conflict-aware batching, rich CLI. 35 files, 2183 lines, 37 tests. `devopseng99/orcha-master`.
- [x] **pc-ng-v2 v1.0.0** (2026-05-04) — Autonomous agent control plane pushed to `devopseng99/pc-ng-v2` (private). Supervisor, dispatcher, build-fix, autoloop, monitor.sh, notify.sh, systemd timer.
- [x] **Production monitoring** (2026-05-04) — monitor.sh (CRD state check), notify.sh (Slack webhook), systemd user timer (30min), autoloop notifications.
- [x] **ADLC v2.0.0 — 14 features** (2026-05-04) — OpenFeature flags, agent replay, intake templates (10), CRD garbage collection, intake-hud.sh, cost-report.sh, multi-cluster, 112 builder tests, self-healing pipeline, webhook triggers, showroom portfolio, audit logging, multi-tenant skill registry. 5,640 lines across 6 repos.
- [x] **Agent-Intake-Controller plugin system** (2026-05-04) — 5 lifecycle phases, 4 built-in plugins (secret-provisioner, http-health, tunnel-router, startup-command), CRD hooks[] field, external plugin loading via PLUGIN_DIR.
- [x] **ai-hedge-fund full-stack live** (2026-05-04) — React SPA + FastAPI API on same origin at ai-hedge-fund.istayintek.com. v1.1.0: multi-stage Dockerfile, zero CORS, 40+ endpoints, 19 AI analysts. Swagger at /docs, React UI at /.
- [x] **ADLC Phases 0-7 complete** (2026-05-04) — All phases implemented. Foundation, builder, CRD controller, Langfuse, ai-hedge-fund, JSONL converter, OpenFeature, HUD, multi-cluster.
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
- [x] **OpenHands auth rate-limit fix + E2E tests** (2026-05-07) — 7th auth issue: RateLimitException caused cookie deletion → 401 loop. Fixed with separate 429 handling. Created smoke-test-auth.py + e2e-auth-playwright.py. All K8s manifests exported to overrides repo. All 6 core auth tests pass (login page, OAuth redirect, curl×3 levels, token refresh).
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
