# Paperclip Pipeline — Next Steps

## URGENT (2026-04-12)

### 1. Run Build-Fix Loop on 68 Failed Apps
- 68 apps failed Phase B (npm build errors) — code on GitHub but builds broken
- Script: `/var/lib/rancher/ansible/db/pc/builder/build-fix-loop.sh --all-failed --max-fixes 3`
- Skill: `/pc-build-fix --all-failed`
- Worst pipelines: soa (18/20 Failed), api-jobs (8/20), tech (17), v1 (16)
- SOA 90% failure rate suggests prompt/architecture issue, not just build config

### 2. Fix build-fix-loop.sh Batch Processing
- First run only processed 1/68 apps (ZRC) before auto script ended
- `while read` subshell means FIXED/STILL_FAILED counters don't propagate
- Need: sequential loop without pipe subshell, or process apps from a temp file
- Consider: `--concurrency` flag for parallel fix attempts (careful with Claude API quota)

### 3. Handle 23 NoBuildScript Apps
- wasm: 4, tech: 8, v1: 3, ai: 3, cf: 4, mcp: 1
- These have skeleton repos with no package.json or build scripts
- Need: codegen prompt improvements or manual scaffolding
- Lower priority than Failed apps (which have real code that almost works)

### 4. Deploy Target Consolidation Decision
- 95 apps deployed to BOTH nginx AND CF Pages (both active, potentially serving different content)
- 75 old K8s per-app deploys in paperclip namespace (all replicas=0, disabled)
- 29 orphan K8s deploys with no CRD match — safe to delete
- Decision needed: (a) keep CF Pages as edge CDN, (b) disable and consolidate to nginx, (c) migrate to CF Pages
- Check if CF Pages content is stale (all created 2026-03-27/28, may not reflect latest codegen)
- Populate `spec.framework` field by inspecting each repo's package.json

### 5. Commit All Pending Changes
- New skills: `/pc-build`, `/pc-build-fix`
- Updated skills: `/pc-deploy`, `/pc-start`
- Updated scripts: `phase-a-codegen.sh` (--auto-build), `workers-start.sh` (--auto-build)
- New script: `build-fix-loop.sh` (in pc repo)
- Updated CRD schema: added deployTarget, hosting, platform, framework, status.deployTargets[]
- Pipeline defs, manifests, registry updates

---

## SHORT TERM

### 6. SOA Pipeline Rework
- 18/20 Failed (90%) — worst pipeline by far
- Root cause: SOA architecture apps (microservices, event-driven) don't fit single-page static export model
- Options: (a) rework prompts for SPA dashboard pattern, (b) accept SOA as incompatible, (c) hybrid approach
- Only 2/20 SOA apps deployed successfully — study what made them different

### 7. API-Jobs Pipeline Triage
- 8/20 Failed (40%) — second worst
- These are batch queue / streaming apps — may have complex dependency chains
- Run build-fix-loop first, then assess remaining failures

### 8. Showroom Verification
- 629 Deployed apps should all be live at `{slug}.istayintek.com`
- Showroom synced (721 apps), but verify new deploys render correctly
- Check the 77 newly deployed apps from this Phase B run

---

## MEDIUM TERM

### 9. Codegen Quality Improvements
- 68 Failed + 23 NoBuildScript = 91 apps needing attention (12.6%)
- Per-pipeline prompt tuning for problem categories (soa, api-jobs)
- Consider framework detection improvements in codegen

### 10. Cleanup Old K8s Deploys
- 75 deployments in paperclip namespace (all replicas=0, disabled)
- 29 are orphans (no CRD match) — safe to delete
- 46 have CRD matches — CRDs now track them as `k8s-pod=disabled` in `status.deployTargets[]`
- Run: `kubectl delete deploy -n paperclip <name>` for orphans, then for CRD-matched ones after confirming nginx serves them

### 11. Pipeline Monitoring Hardening
- Phase B auto script (`phase-b-auto.sh`) proved the pattern works
- Formalize as `pipeline-supervisor.sh` with: auto Phase B, auto fix-loop, progress alerts
- Emergency halt integration

### 12. CF Token Automation
- Current token expires 2026-11-30 (`~/cf-token--expires-nov-30-2026`)
- Consider: store token in K8s secret, auto-rotate via CronJob

---

## COMPLETED

- [x] **Deploy target audit** (2026-04-12) — discovered 3 layers: nginx (629), CF Pages (97), K8s pods (75 disabled). CRD schema updated with deployTarget, hosting, platform, framework, deployTargets[]. All 721 CRDs patched.
- [x] **Phase B first full run** (2026-04-12) — 629/721 Deployed (87.2%), 77 newly deployed
- [x] **Phase B automation implemented** — `/pc-build`, `/pc-build-fix`, `--auto-build` flag, `build-fix-loop.sh`
- [x] **`/pc-deploy` fixed** — was wrapping obsolete `batch-deploy-k8s.sh`, now uses correct `build-and-deploy.sh`
- [x] **All Pending cleared** — 0 Pending, 0 Building (all Phase A complete)
- [x] **Capacity constraint resolved** — Nginx wildcard vhost model, NOT per-pod. 1 pod serves all 721+ apps
- [x] **Phase A — all 17 pipelines complete** (2026-04-12) — all apps have code on GitHub
- [x] **5 new pipelines (2026-04-12)** — retail, flink-ai, etl-edi, tradebot, api-jobs
- [x] **3 new pipelines 100% deployed** — etl-edi (15/15), flink-ai (15/15), tradebot (15/15)
- [x] **pc-v4 onboarding** — 306 companies, 15 pipelines
- [x] **Pipeline Registry ConfigMap** — all scripts + skills use dynamic discovery
- [x] **CRD pattern regex** — no CRD schema edit needed for new pipelines
- [x] **Refactored 6 scripts + 4 skills** — fully dynamic pipeline resolution
- [x] Pipeline creation tooling — `.def` → `generate-manifest.sh` → `new-pipeline.sh`
- [x] `/pc-new-pipeline` skill — tested with 7 pipeline creations
- [x] Bulk onboarding — 745 companies across 4 instances (zero dupes)
- [x] Showroom deployed — CRD watch + Redis sub, 721 apps synced
- [x] CF token renewed to 2026-11-30
