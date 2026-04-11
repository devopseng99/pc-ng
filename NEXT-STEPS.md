# Paperclip Pipeline — Next Steps

## URGENT (2026-04-11)

### 1. Resolve Cluster Capacity for Phase B
Phase B deploy of 472 apps is **blocked by infrastructure**, not software:
- **Pod count**: 641 pods needed, 220 max across cluster (110/node) — **hard wall**
- **RAM**: 20 Gi requests needed, ~18.4 Gi free — tight even without pod limit
- **Options:**
  - **Add 3rd worker node** (16 Gi) + bump `--max-pods=500` on kubelet — cleanest fix
  - **Reduce pod requests** from 32Mi→16Mi (nginx static sites don't need 32Mi) — halves RAM to ~10 Gi
  - **Consolidate apps** into fewer nginx pods via vhost config — most efficient (641→~65 pods) but complex
  - **Deploy in batches** — partial deploy within current limits (~150-180 apps max)

### 2. Commit Pending Changes
- 28+ uncommitted files including pipeline registry, skills, scripts, definitions
- Should be committed to preserve registry refactoring and pipeline creation work

---

## SHORT TERM

### 3. Showroom Sync Verification
- Showroom at showroom.istayintek.com synced 641 apps (confirmed)
- New categories: SaaS Hosting & Payments, TV & Movie Streaming
- Verify new categories render properly in showroom UI

### 4. Deploy Verification
- After Phase B completes (once capacity resolved), verify all deployed apps are reachable
- Showroom auto-syncs via CRD watch — no manual push needed

---

## MEDIUM TERM

### 5. Pipeline Monitoring Hardening
- Supervisor script (`pipeline-supervisor.sh`) for auto-restart of failed workers
- Emergency halt (`emergency-halt.sh`) for kill-all scenarios
- Both scripts exist but need production testing

### 6. CF Token Automation
- Current token expires 2026-11-30 (`~/cf-token--expires-nov-30-2026`)
- Consider: store token in K8s secret, auto-rotate via CronJob

### 7. Instance Scaling Assessment
- 4 instances on 2 nodes (mgplcb03 control plane, mgplcb05 worker)
- pc-v4 now serves 10 pipelines — monitor PG size
- Total CRDs: 641, Companies: 665 across 4 instances

---

## COMPLETED

- [x] **Phase A codegen — 641/641 apps built** across 12 pipelines (100% complete as of 2026-04-10)
- [x] **2 SOA Pending resolved** — worker restart completed both remaining apps
- [x] **Pipeline Registry ConfigMap** — centralized pipeline→instance mappings, all scripts + skills use dynamic discovery
- [x] **CRD pattern regex** — replaced hardcoded pipeline enum with `^[a-z][a-z0-9-]{0,29}$`
- [x] **Refactored 6 scripts** — phase-a-codegen.sh, generate-crds.sh, bulk-onboard.sh, workers-start.sh, workers-status.sh, new-pipeline.sh all use pipeline-registry.sh
- [x] **Updated 4 skills** — pc-status, pc-reset, pc-start, pc-new-pipeline all use list_pipelines()
- [x] **Capacity analysis** — cluster can't fit 641 pods (RAM + pod count); options documented
- [x] 60 ecom/crypto/invest apps — Phase A complete
- [x] 10 SaaS apps — Phase A complete (via `/pc-new-pipeline`)
- [x] 10 streaming apps — Phase A complete (via `/pc-new-pipeline`)
- [x] CRD-first intake pattern — `generate-crds.sh` single entry, deterministic naming, triple dedup
- [x] Pipeline creation tooling — `.def` format, `generate-manifest.sh`, `new-pipeline.sh` (plan/auto-apply)
- [x] `/pc-new-pipeline` skill — AI-assisted pipeline creation, tested with saas + streaming
- [x] Onboarding gap fixed — 20 saas+streaming companies onboarded to pc-v4 (total 226)
- [x] Bulk onboarding — 665 companies across 4 instances (zero dupes)
- [x] Duplicate cleanup — 1,180 duplicates removed from pc, zero data loss
- [x] Duplicate cleanup — 60 duplicate CRDs + 60 duplicate companies from ecom/crypto/invest
- [x] pc-v2 bootstrap + external access — CF tunnel remote config route added
- [x] pc-v5 provisioned — Helm, bootstrap, tunnel, DNS, external-ops (17 companies)
- [x] Showroom deployed — CRD watch + Redis sub, 641 apps synced
- [x] PC-ENDPOINTS.md — comprehensive reference for all instances
- [x] DECISIONS.md — 15 key architectural decisions documented
- [x] Skills: /pc-status, /pc-deploy, /pc-start, /pc-halt, /pc-reset, /pc-provision, /pc-new-pipeline
- [x] CF token renewed to 2026-11-30
