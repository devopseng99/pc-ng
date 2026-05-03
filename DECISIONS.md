# Paperclip Pipeline — Key Decisions & Rationale

## Architecture

### Multi-Instance Paperclip (2026-03-28)
**Decision:** Run 4 separate Paperclip instances instead of one shared instance.
**Rationale:** Isolate pipeline workloads — v1 (213 apps) on pc, tech (203 apps) on pc-v2, wasm/soa/ai/cf/mcp/ecom/crypto/invest (205 apps) on pc-v4, pc-v5 is external-ops (17 companies, separate purpose). Each instance has its own PG, API key, and namespace. Prevents overloading a single instance and allows independent scaling.
**Trade-off:** More operational overhead (4x secrets, 4x bootstrap), but `provision-pc.sh` automates this end-to-end.

### CRDs in Shared Namespace (2026-03-28)
**Decision:** All PaperclipBuild CRDs (641+) live in `paperclip-v3`, not per-pipeline namespaces.
**Rationale:** Single source of truth for build state. Showroom CRD syncer watches one namespace. Workers query one namespace. Simplifies aggregation and monitoring.
**Trade-off:** Must use `spec.pipeline` field to filter per-pipeline; CRD API version is `v1alpha1` (not `v1` — using wrong version causes silent mass failures).

### Company Matching by Name, Not Prefix (2026-03-31)
**Decision:** `bulk-onboard.sh` matches existing companies by NAME, never by issuePrefix.
**Rationale:** Paperclip auto-appends "A"s to prefixes to avoid collisions (SCB → SCBA → SCBAA). Prefix matching caused 1,180 duplicate companies in a single day. Name is the only stable identifier.
**Impact:** All future onboarding scripts must use name matching. `onboard-full.sh` has no idempotency — always use `bulk-onboard.sh` wrapper.

### CF Tunnel Remote Config as Source of Truth (2026-04-01)
**Decision:** Always manage tunnel routes via CF API (`PUT /cfd_tunnel/{id}/configurations`), not the local K8s ConfigMap.
**Rationale:** When both exist, remote config overrides local. pc-v2 was unreachable for hours because the route was added to ConfigMap but missing from remote config. The ConfigMap is a secondary reference only.
**Impact:** `provision-pc.sh`, `deploy-k8s-static.sh`, and `/pc-provision` skill all use the CF API.

### CRD-First Intake Pattern (2026-04-06)
**Decision:** CRDs are the single entry point for the pipeline. `generate-crds.sh` creates CRDs from manifests. Workers never create CRDs — they only consume Pending CRDs.
**Rationale:** Previous flow had 3 systems fighting over the same work (manual CRD creation, phase-a workers creating CRDs, bulk-onboard). Caused 60 duplicate CRDs and 60 duplicate companies when workers and manual steps ran in parallel.
**Pattern:**
1. `generate-crds.sh --manifest <file> --pipeline <name>` — creates CRDs with deterministic naming `pb-{appId}-{prefix-lowercase}`
2. CRD spec includes `targetInstance` and `targetNamespace` — baked in at creation, no runtime resolution needed
3. Workers read target from CRD, check company exists by NAME before onboarding, store `companyId` in CRD status
4. Workers auto-call `generate-crds.sh` on startup (idempotent — skips existing)
**Impact:** Zero duplicates on re-runs. Workers can be safely restarted mid-pipeline. `bulk-onboard.sh` becomes optional catch-up only.

### Pipeline Expansion to 17 Pipelines (2026-04-12)
**Decision:** Expanded from original 7 pipelines to 17. Total: 721 CRDs across 4 PC instances.
**Timeline:**
- 2026-04-06: +5 pipelines (ecom/20, crypto/20, invest/20, saas/10, streaming/10) → 12 pipelines, 641 CRDs
- 2026-04-12: +5 pipelines (retail/15, flink-ai/15, etl-edi/15, tradebot/15, api-jobs/20) → 17 pipelines, 721 CRDs
**Categories added (2026-04-12):**
- **retail** — Retail & E-Commerce (POS, loyalty, marketplace, headless commerce)
- **flink-ai** — Flink Realtime AI & Processing (CDC, CEP, agent orchestration, observability)
- **etl-edi** — Data Pipeline ETL & EDI (X12/EDIFACT, CDC, data vault, file transfer)
- **tradebot** — AI Trading & Investment (stock/crypto/ETF bots, research, RSS, CMS dashboards)
- **api-jobs** — API Jobs & Streaming (batch queues, streaming tail, workflow orchestration, cron scheduling)
**Rationale:** Diversify app portfolio across high-demand verticals. All new pipelines map to pc-v4. Workers run concurrency 1 each.
**Build strategy:** Phase A codegen workers run autonomously. 5 workers active for new pipelines (2026-04-12).

### pc-v5 as External-Ops (2026-04-01)
**Decision:** pc-v5 is designated "external-ops" — not for pipeline-generated apps.
**Rationale:** pc-v5 has 17 manually-onboarded companies for a separate purpose. Pipeline builds should NOT target this instance. `resolve_pc_instance()` has no mapping that routes to pc-v5.

### Reusable Pipeline Creation Tooling (2026-04-06)
**Decision:** Three-stage tooling: `.def` file (human-authored app ideas) → `generate-manifest.sh` (produces JSON) → `new-pipeline.sh` (orchestrates end-to-end with plan/auto-apply).
**Rationale:** Creating a new pipeline previously required manually editing 4+ files (manifest JSON, CRD YAML enum, workers-start.sh, workspace symlinks). Error-prone and non-repeatable. The `.def` format is minimal key-value blocks, easy to author or AI-generate. `new-pipeline.sh` handles all 8 steps including CRD enum updates and worker registration.
**Modes:**
- `--action plan` — dry run showing what would happen, prints auto-apply command
- `--action auto-apply` — executes everything including starting workers
**Skill:** `/pc-new-pipeline` wraps the flow — generates app ideas from a theme description, writes `.def`, runs `new-pipeline.sh`.

### Pipeline Registry ConfigMap (2026-04-06)
**Decision:** Centralize all pipeline→instance mappings in a K8s ConfigMap (`pipeline-registry` in `paperclip-v3`), sourced by a shared `pipeline-registry.sh` helper. Replace all hardcoded case statements and pipeline lists across scripts and skills.
**Rationale:** Pipeline names were hardcoded in 15+ locations across 8 files (phase-a-codegen.sh, generate-crds.sh, bulk-onboard.sh, workers-start.sh, workers-status.sh, new-pipeline.sh, plus 4 skills). Every new pipeline required editing all of them. The `new-pipeline.sh` sed approach for CRD enum editing was fundamentally broken (corrupted the CRD schema for both saas and streaming).
**Solution:**
1. `manifests/pipeline-registry.yaml` — version-controlled ConfigMap with JSON mapping: `{pipeline: {instance, namespace, secret, manifest}}`
2. `pipeline/scripts/pipeline-registry.sh` — shared helper with `resolve_pipeline()`, `list_pipelines()`, `register_pipeline()`, `pipeline_exists()`
3. CRD `pipeline` field uses pattern regex `^[a-z][a-z0-9-]{0,29}$` instead of hardcoded enum — no CRD schema edit needed for new pipelines
4. All scripts (`phase-a-codegen.sh`, `generate-crds.sh`, `bulk-onboard.sh`, `workers-start.sh`, `workers-status.sh`, `new-pipeline.sh`) source the registry
5. All skills (`/pc-status`, `/pc-reset`, `/pc-start`, `/pc-new-pipeline`) use `list_pipelines()` for dynamic discovery
**Adding a new pipeline:** `register_pipeline "name" "pc-v4" "paperclip-v4"` — one command, zero file edits.
**Impact:** `new-pipeline.sh` no longer needs sed/Python to edit CRD YAML, case statements, or worker registration. Fully self-service.

## Operations

### Concurrency Limits (2026-03-29)
**Decision:** Default concurrency 2 for multi-pipeline runs; 4 OK for single pipeline when others are idle.
**Rationale:** Concurrency >4 causes Claude API rate limit failures (429s). At concurrency 2, builds are reliable with <5% failure rate.

### Circuit Breaker Per-Pipeline (2026-03-30)
**Decision:** Per-pipeline circuit breaker state files instead of one shared breaker.
**Rationale:** Shared breaker meant one failing pipeline would halt all pipelines. Per-pipeline isolation (`/tmp/pc-autopilot/.circuit-breaker-state-${pipeline}`) lets healthy pipelines continue.
**Rules:** Min 3 samples before tripping; hard-stop after 10 consecutive fails; usage-cap = worker EXIT (not retry).

### Password-in-Secret Must Match Sign-Up (2026-04-01)
**Decision:** Bootstrap scripts must store the SAME password used during `POST /api/auth/sign-up/email` into K8s secrets — never regenerate.
**Rationale:** pc-v5 bootstrap generated the password twice (once for sign-up, once for secret storage), causing login failures. The sign-up endpoint hashes the password server-side; there's no way to recover or reset it without DB surgery.
**Fix pattern:** Generate password ONCE, use it for both sign-up and secret creation in the SAME shell block.

### No Data in /tmp for Production (2026-03-29)
**Decision:** All pipeline scripts version-controlled in git repo. Working state under `/tmp/pc-autopilot/` is ephemeral only.
**Rationale:** `/tmp` gets wiped on reboot. Lost 2 days of script work early on. Pod configs go to persistent volumes, not `/tmp` inside containers.

## Data Integrity

### Audit Before Bulk Delete (2026-03-31)
**Decision:** Always audit FK tables before any bulk company deletion.
**Rationale:** 46 tables reference `company_id`, most with NO ACTION (not CASCADE). Must delete children bottom-up. The 1,180 duplicate cleanup was preceded by a full audit confirming zero unique data in duplicates — 17 originals had real agent history preserved.
**Pattern:** Create temp table of IDs → audit all 46 child tables → delete children bottom-up → delete companies → verify counts.

### Phase B Deploy Queue (2026-03-31)
**Decision:** Phase A (codegen + GitHub push) must fully complete before Phase B (K8s deploy) begins for any app.
**Rationale:** Phase B clones the GitHub repo, runs `npm build`, and creates static export. If Phase A hasn't pushed code, Phase B fails silently with empty builds.
**Status:** Phase A complete for all 17 pipelines. Phase B first full run completed (2026-04-12). 629/721 Deployed (87.2%), 68 Failed (build errors), 23 NoBuildScript, 1 Deploying. 745 companies across 4 instances.

### Phase B Automation — Build, Deploy, Fix (2026-04-12)
**Decision:** Three-layer Phase B automation: `/pc-build` skill triggers `build-and-deploy.sh`, `--auto-build` flag on Phase A chains A→B with zero gap, `build-fix-loop.sh` uses Claude to patch failed builds instead of full regen.
**Skills:** `/pc-build` (canonical Phase B trigger), `/pc-deploy` (alias), `/pc-build-fix` (fix loop), `/pc-start --auto-build` (end-to-end).
**Scripts:** `build-and-deploy.sh` (pc repo, unchanged), `build-fix-loop.sh` (pc repo, new), `phase-a-codegen.sh --auto-build` (pc-ng, updated), `workers-start.sh --auto-build` (pc-ng, updated).
**Rationale:** Previous workflow required manual Phase B trigger after Phase A. Build failures required full Phase A regen (5+ min, Claude API heavy) when 90%+ of code was fine — usually a config/dep issue fixable in seconds. The fix loop reads the npm build error, asks Claude to make a targeted patch, pushes, retries (max 3 attempts).
**First run results:** 163 Deploying → 77 newly Deployed + 68 Failed. Fix loop ran on ZRC (1/68) before time limit — needs batch optimization.
**Old `/pc-deploy` was broken:** Wrapped obsolete `batch-deploy-k8s.sh` (per-pod model). Now correctly wraps `build-and-deploy.sh`.

### Phase B: Nginx Wildcard Vhost — NOT Per-Pod (2026-04-12)
**Decision:** All apps deploy as static files into a **single shared Nginx pod**, NOT as individual K8s pods. The prior capacity constraint analysis (per-pod model) is **permanently obsolete**.
**Architecture:**
- **Namespace:** `static-sites` on mgplcb05
- **Pod:** Single `nginx-static-*` (`nginx:1-alpine`) with wildcard vhost ConfigMap
- **PV:** `static-sites-pv`, 20 GiB local-storage at `/opt/k8s-pers/vol1/static-sites`
- **Traffic:** `*.istayintek.com` wildcard CNAME → CF edge → tunnel → `nginx-static.static-sites:80` → Nginx extracts subdomain from `$host` → serves `/sites/{subdomain}/index.html`
**Measured resource usage (476 sites live):**
- RAM: 43 MiB (vs ~30 GiB if per-pod — **700x less**)
- CPU: 1m (vs ~24 cores if per-pod)
- Disk: 610 MiB (avg 1.3 MiB per site)
- Pod slots: **1** (vs 476 if per-pod — would have exceeded 440 cluster max)
**Deploy script:** `/var/lib/rancher/ansible/db/pc/builder/build-and-deploy.sh` — clones repo, detects framework (next/turbo-next/astro/turbo-astro), patches config, builds, `kubectl cp` output to `/sites/{slug}/`, patches CRD → Deployed. Flags: `--concurrency 4`, `--retry-failed`, `--pipeline NAME`.
**Impact:** Cluster can host **1000+ apps** with existing resources. New pipelines of any size cost only disk space. Pod count and RAM-per-app are no longer constraints. **Never propose per-pod deploys, Helm charts per app, or Deployment/Service/Ingress manifests per app.**
**Focus:** Codegen quality (prompt improvements for turbo-astro, soa failures) and build-and-deploy script fixes (legacy-peer-deps), not infrastructure scaling.

### Deploy Target Audit — Three Layers Discovered (2026-04-12)
**Decision:** Added `deployTarget`, `hosting`, `platform`, `framework` to CRD spec and `deployTargets[]` array to CRD status to track where each app is actually deployed.
**Discovery:** Apps exist across three deploy layers, not just nginx:
1. **Nginx wildcard vhost** (`static-sites` ns) — 629 apps, single pod, `{repo}.istayintek.com`. The canonical deploy target for all pipeline apps.
2. **Cloudflare Pages** — 97 projects at `{repo}.pages.dev`. Created 2026-03-27/28 for early v1/tech pipeline apps. 95 have CRD matches, 2 are orphans (zr-nail-beauty, zuzu-beauty-salon).
3. **K8s per-app Deployments** (paperclip ns) — 75 old deploys from obsolete per-pod model, **all scaled to replicas=0** (disabled). 46 have CRD matches, 29 are orphans with no CRD.
**Multi-target:** 95 apps deployed to BOTH nginx AND CF Pages (both active). 46 have disabled K8s per-app deploys too. 2 apps (sensorgrid-hub, legacy-plan-estates) exist on all 3 targets.
**CRD schema additions:**
- `spec.deployTarget`: nginx | cf-pages | k8s-pod | multi
- `spec.hosting`: static-sites | cloudflare | paperclip-ns | multi
- `spec.platform`: static | node | wasm | worker
- `spec.framework`: next | astro | turbo-next | turbo-astro | unknown
- `status.deployTargets[]`: array of `{target, state, url, lastDeployed}` per location
**Impact:** 95 apps are serving from two active origins (nginx + CF Pages). The 75 disabled K8s deploys and 29 orphan deploys are cleanup candidates. CF Pages projects may have stale content if not updated since initial deploy. The `framework` field needs population by inspecting each repo's package.json.
**Next:** Decide whether to (a) keep CF Pages as CDN edge cache, (b) disable CF Pages deploys and consolidate to nginx-only, or (c) migrate fully to CF Pages for edge performance.

### 18th Pipeline: deep-trade (2026-04-13)
**Decision:** Created `deep-trade` pipeline — 15 AI-powered investment research dashboards with stock/crypto/ETF tri-recommendation engines.
**Apps:** IDs 60101-60115, targeting pc-v4 (paperclip-v4). All 15 feature RSS feeds, RBAC, audit logging, headless CMS, and BUY/SELL/HOLD signals across three asset classes.
**Rationale:** Diversifies investment vertical alongside existing `invest` (20 analysis apps) and `tradebot` (15 execution bots). deep-trade focuses on research dashboards with compliance and CMS — a distinct niche.
**Result:** Phase A completed in ~1h22m (concurrency 1). 15/15 code on GitHub. Phase B in progress.

### Dual-Variant App Model — Short-Name vs Long-Name Repos (2026-04-13)
**Decision:** Maintain two CRD variants for 29 pre-pipeline orphan apps: short-name repos (existing code) AND long-name repos (fresh Phase A codegen).
**Discovery:** 29 K8s deployments in `paperclip` namespace had NO matching GitHub repos when checked by their CRD repo names (`aquastroke-swimming-school`, etc.). Investigation revealed the repos existed under abbreviated names (`aquastroke-swimming`, `beanorigin-coffee`, etc.) — pre-pipeline naming used `{brand}-{short-descriptor}` while CRDs used `{brand}-{full-descriptive-name}`.
**Approach:**
- Created 29 NEW CRDs (IDs 60201-60229) with `repo` = short-name GitHub repos, set to `Deploying` for immediate Phase B
- Kept 29 ORIGINAL CRDs (IDs 60000-60028) with long-name repos at `Pending` for Phase A fresh codegen
- Same company, two isolated codebases — enables v1 (legacy) vs v2 (pipeline-generated) comparison
**Rationale:** User identified this as a valuable pattern: same app concept, two independent implementations, no git conflicts, independent build/test/deploy cycles. Useful for A/B testing, migration validation, or next-gen rewrites.
**Impact:** Total CRDs: 794 (was 765). v1 pipeline: 271 CRDs (was 242). Short-name apps deploying successfully via Phase B.

### CF Tunnel Wildcard Ordering Fix (2026-04-13)
**Decision:** `provision-pc.sh` must insert tunnel routes BEFORE the `*.istayintek.com` wildcard entry, not at `insert(-1)` (before catch-all).
**Bug:** The old code used `ingress.insert(-1, ...)` which inserts before the catch-all `http_status:404` — but AFTER the `*.istayintek.com` wildcard. Since CF tunnel ingress rules match top-to-bottom, the wildcard caught all traffic first, routing new instances to nginx-static instead of their service. Caused pc-v7 to return 500.
**Fix:** Find the wildcard position: `insert_idx = next((i for i, r in enumerate(ingress) if r.get('hostname','').startswith('*.')), len(ingress) - 1)` then `ingress.insert(insert_idx, ...)`.
**Impact:** All future `provision-pc.sh` runs will correctly insert before the wildcard. Existing entries after the wildcard (e.g., ziprun-courier) were manually reordered.

### Per-Pod Deploy Cleanup Pattern (2026-04-13)
**Decision:** When cleaning up old per-pod deploys, remove Deployment + Service + CF tunnel route, then reset CRD to `Deploying` for nginx Phase B build.
**Example:** `ziprun-courier` — had a CrashLoopBackOff per-pod deploy in `paperclip` ns, a ClusterIP service, and a dedicated CF tunnel route pointing to the per-pod service. CRD said `Deployed` but nginx had no static files (deploy target was `disabled`). Cleaned up: deleted deploy+svc, removed tunnel route, reset CRD to Deploying.
**Pattern:** For each of the remaining ~74 old per-pod deploys: (1) verify nginx has static files, (2) if yes → just delete deploy+svc+tunnel, (3) if no → also reset CRD to Deploying for Phase B.

### pc-v7 Instance Provisioned (2026-04-13)
**Decision:** Provisioned `pc-v7` (namespace `paperclip-v7`) on mgplcb05 as a new empty instance.
**Details:** Helm release deployed, CF tunnel route added (before wildcard), DNS CNAME created, bootstrap completed (admin user + API key + K8s secrets). Currently 0 companies — ready for pipeline assignment or manual use.
**URL:** https://pc-v7.istayintek.com

### Openfile Tunnel Routes (2026-04-13)
**Decision:** Added two CF tunnel entries for the OpenFile app before the wildcard:
- `openfile.istayintek.com` → `openfile-df-client.openfile.svc.cluster.local:3000`
- `openfile-api.istayintek.com` → `openfile-api.openfile.svc.cluster.local:8080`
**DNS:** CNAME records created for both, proxied through CF.

### OpenFile & Direct File APIs Live (2026-04-13)
**Decision:** Deployed both IRS tax filing apps (OpenFile + Direct File) as full-stack K8s apps on pc-v7 — NOT through the pipeline/nginx model.
**Architecture:** Spring Boot 3.3.10 API (:8080) + React df-client (:3000) + PostgreSQL 15 + Redis 7.0 + LocalStack 3.0. Per-pod deploys with own namespaces (`openfile`, `direct-file`). Helm charts in separate deploy repos.
**Key workarounds:**
1. **Factgraph disabled** — `DIRECT_FILE_LOADER_LOAD_AT_STARTUP=false` to bypass `ClassCastException: CollectionItemNode cannot be cast to BooleanNode` in fact-graph-scala. Upstream fix: IRS-Public/fact-graph PR #82 (commit `79a9529`).
2. **LocalStack for AWS** — All AWS deps (S3, SQS, SNS, KMS) mocked via LocalStack pods. Init containers pre-create 12 queues, 1 topic, 2 buckets before API starts.
3. **SNS publishing disabled** — `DIRECT_FILE_AWS_SNS_SUBMISSION_CONFIRMATION_PUBLISH_ENABLED=false` to avoid `PublisherException` at startup.
4. **Spring Boot 3.x env vars** — `SPRING_DATA_REDIS_HOST` not `SPRING_REDIS_HOST`.
5. **Startup probes** — `failureThreshold: 30, periodSeconds: 10` (5.5 min tolerance) because Spring Boot + Hibernate + AWS takes 2-5 min to start.
6. **Redis protected-mode no** — Required for cross-pod access without auth.
**URLs:** openfile.istayintek.com, openfile-api.istayintek.com, direct-file.istayintek.com, direct-file-api.istayintek.com — all returning 200.
**Impact:** Both frontends and APIs live. Tax return processing disabled until factgraph fix is merged from upstream.

### 19th Pipeline: invest-bots (2026-04-13)
**Decision:** Created `invest-bots` pipeline — 15 AI investment trading bots with tri-asset BUY/SELL/HOLD recommendation engines.
**Apps:** IDs 60301-60315, targeting pc-v4 (paperclip-v4). All 15 feature RSS feeds (80-100+ sources), RBAC with role hierarchies, audit logging (SOC2/SOX/MiFID/Basel III), headless CMS with signal publishing, real-time analytics dashboards.
**Differentiation from existing investment pipelines:**
- `invest` (20 apps) — General AI investment analysis
- `tradebot` (15 apps) — Algorithmic trading execution
- `deep-trade` (15 apps) — Research dashboards with compliance
- `invest-bots` (15 apps) — Trading bots with accuracy tracking, RSS sentiment, and specialized CMS
**Result:** Phase A completed 2026-04-13. All 15/15 code on GitHub. All 15 at Deploying — awaiting Phase B.

### Versioned Skill Registry (2026-05-02)
**Decision:** Extracted all Claude Code skills into a dedicated GitHub repo (`devopseng99/claude-skills`) with version pinning, a sync CLI, and per-project manifests.
**Problem:** Skills were flat files scoped to one project directory. No versioning, no sharing across projects, no rollback.
**Architecture:**
1. **Registry repo** (`~/claude-skills/` → `devopseng99/claude-skills`) — single source of truth, git-tagged releases
2. **`skill-sync.sh`** (~1400 lines) — CLI with 17+ flags: `--init`, `--profiles`, `--push`, `--bump`, `--rollback`, `--status`, `--adopt`, `--diff`, `--update`, `--global`, `--quiet`, etc.
3. **Per-project manifest** — `.claude/skill-manifest.yaml` declares skills + version
4. **Lock file** — records exact commit + SHA256 integrity per skill
5. **`skill-analyze.sh`** — optimization tool for overlap/cluster analysis
6. **`bootstrap-project.sh`** — one-command onboarding with `--with-claude-md` and `--for-intake`
**Impact:** 6 projects consuming from registry. Skill updates are tagged, diffable, and rollback-safe.

### Skill Consolidation — 3-Phase Optimization (2026-05-03)
**Decision:** Consolidated 45 skills to 34 via three phases.
- **Phase 1:** Deduplicated pc-deploy (→ redirect to pc-build), merged bead + convoy (→ gtcc-entities)
- **Phase 2:** Created universal `container-build` (14 podman/K8s gotchas) and `k8s-deploy` (11 Helm/CF/auth gotchas) replacing 4 project-specific skills
- **Phase 3:** Unified `test-suite` replacing 5 individual test skills (audit-score, deploy-test, filing-test, ocr-test, tax-test)
**Key principle:** Operational lessons (CF tunnel ID, podman TMPDIR, Better Auth endpoints, bootstrap password) are embedded directly in universal skills — they travel with the skill, not just in memory.
**Impact:** 34 skills, 10 profiles, all 6 projects at v2.0.0.

### Composable Profile System (2026-05-03)
**Decision:** Restructured profiles into 3 composable layers with `include:` and `layer:` support.
**Problem:** Profiles were monolithic. `v7-apps` duplicated `infra-core` skills. `az-taxoptics` mixed universal + domain skills. Every new project needing a different combo required a new flat profile.
**Layers:**
- **Capability** (reusable building blocks): infra-core (3), pipeline-ops (6), container-ops (2), testing (1)
- **Domain** (project-specific): taxoptics (11), gtcc (10), prefect (1)
- **Composite** (convenience): full = infra+pipeline, v7-apps = infra+container+v7-status, az-taxoptics = container+testing+taxoptics
**Features:**
- `include:` field in profile YAML — recursive resolution with cycle detection
- Comma-separated init: `--init --profile "infra-core,container-ops"` → merged manifest
- Smart detection: `--status` resolves include chains, greedy set-cover fallback
**Impact:** v3.0.0. New projects compose capabilities without creating new profiles. Changes to capability profiles auto-propagate to all composites.

### CF Pages Consolidation (2026-05-03)
**Decision:** Deleted 95 duplicate CF Pages projects. Kept 5: sui (standalone), pc-showroom, tech-showroom, zr-nail-beauty, zuzu-beauty-salon.
**Discovery:** CF Pages API returns max 10 results per call with broken pagination (no page/per_page params). Had to loop-delete to discover full inventory. Original 98 projects dated to 2026-03-28 — early v1/tech pipeline before nginx wildcard approach. All 95 deleted were confirmed Deployed on nginx.
**Impact:** CF Pages freed for future use. 2 non-pipeline beauty apps (zr-nail-beauty, zuzu-beauty-salon) added as CRDs to ecom pipeline targeting pc-v4.

### Headless Agent Architecture — pc-ng-v2 (2026-05-03)
**Decision:** Created `/var/lib/rancher/ansible/db/pc-ng-v2` as the autonomous agent control plane. Headless Claude sessions run numbered (#1-, #2-, etc.) for traceability.
**Architecture:**
1. **Supervisor agent** — headless Claude (`-p`) reads CRD state, decides actions, outputs task JSON. Runs every 15min via cron.
2. **Build-fix agent** — headless Claude takes CRD name + error, fixes code, pushes. Spawned by dispatcher per supervisor task.
3. **Dispatcher** — reads supervisor output, spawns numbered worker sessions.
4. **Audit hooks** — PreToolUse/PostToolUse/SessionStart/SessionEnd log to `/var/log/claude-audit/`.
5. **Session logging** — `cleanupPeriodDays: 365`, debug logging, stream-json output, OTEL-ready.
**Rationale:** Human was implicit orchestrator across 4 projects (pc-ng, pc, pc-researcher, pc-v7), carrying context manually. This shifts to "human as reviewer" — agents propose, human approves. Based on patterns from Elastic (self-correcting CI), Anthropic (Agent Teams), Google (A2A), Arthur AI (ADLC).
**Key principle:** Idempotent/ephemeral sessions — can be started, stopped, and restarted cleanly. Each session in a `#N-` prefix directory for ordered history.

### Dispatcher Stdin Fix & Worker Isolation (2026-05-03)
**Decision:** Restructured dispatcher to use `mapfile` + `nohup`/`disown`/`< /dev/null` instead of `python3 | while read` piping.
**Bug:** Background workers (`bash build-fix.sh &`) inherited stdin from the pipe, consuming lines meant for the `while IFS='|' read` loop. Only 1 of 3 tasks dispatched, and that worker died when the dispatcher exited.
**Fix:**
1. Read all tasks into a bash array via `mapfile < <(python3 ...)` — no pipe inheritance
2. Each worker spawned with `nohup ... < /dev/null >> logs/worker-${pipeline}-${action}.log 2>&1 &`
3. `disown` each worker PID so it survives parent exit
4. Per-pipeline log files for worker stdout/stderr
**Impact:** All 3 supervisor tasks dispatched correctly. Workers run independently and survive terminal disconnects.

### SDK Agent Intake Integration (2026-05-03)
**Decision:** Added `--skill` flag to `sdk-agent-intake/sdk-tmpl/intake.py` for shared registry skill resolution.
**Problem:** intake.py hardcoded a single local skill file. Knowledge in registry skills (gotchas, patterns) was duplicated.
**Resolution order:** Local `skill-registry/` → shared `~/claude-skills/skills/<name>/SKILL.md`
**Usage:** `python intake.py --skill container-build agentX/app.yaml` or `skill: k8s-deploy` in YAML config.
**Impact:** Agent SDK harness can now leverage any of the 34 registry skills.
