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

### Pipeline Expansion to 12 Pipelines (2026-04-06)
**Decision:** Added 5 new pipelines (ecom, crypto, invest, saas, streaming) mapped to pc-v4. Total: 12 pipelines, 641 CRDs.
**Rationale:** Diversify app portfolio. E-commerce (20 apps), crypto (20 apps), investment (20 apps), SaaS hosting (10 apps), TV/movie streaming (10 apps). pc-v5 designated as external-ops (17 companies, not for pipeline builds).
**Build strategy:** Workers run concurrency 1 each. Phase B deploys skipped for now. All Phase A builds completed 2026-04-06.

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
**Status:** Phase A complete for **641/641** apps across 12 pipelines (2026-04-10). 472 apps in Deploying state ready for Phase B. 169 already Deployed.

### Phase B Capacity Constraint (2026-04-10)
**Decision:** Phase B deploy of all 472 remaining apps is blocked by cluster capacity, not software readiness.
**Analysis:**
- Each app pod: 32Mi request / 64Mi limit, 10m CPU request / 50m limit (nginx:alpine serving static content)
- 641 pods total need: ~20 Gi RAM requests, 6.4 CPU cores, 641 pod slots
- Cluster has: ~18.4 Gi free RAM, 10 allocatable cores, **220 max pods** (110 per node)
- **Pod count is the hard wall** — 641 pods vs 220 limit (3x over)
- RAM requests (20 Gi) also exceed free capacity (~18.4 Gi)
**Options ranked:**
1. Reduce pod requests to 16Mi/32Mi (halves RAM to ~10 Gi) — still blocked by pod count
2. Add a 3rd worker node (16 Gi) — solves RAM, need `--max-pods=500` on kubelet to solve pod count
3. Consolidate multiple static sites per nginx pod (vhost) — most efficient, drops to ~65 pods, but complex deploy changes
4. Deploy in batches — deploy subsets per pipeline, skip rest until scaled
**Impact:** Must resolve capacity before Phase B can complete. Option 2 + 1 is the cleanest path.
