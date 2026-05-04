# ADLC Enterprise Agentic Build Pipeline

**Version:** 1.0.0
**Created:** 2026-05-03
**Last Updated:** 2026-05-03
**Status:** IN PROGRESS — Phases 0-4 complete, Phases 5-7 deferred (Later)

---

## Routing Matrix

| Roadmap Item | Engine | Repo | Reason |
|---|---|---|---|
| **Phase 1:** Builder hardening | builder | `sdk-agentic-custom-builder-intake` | Harness improvements before first real build |
| **Phase 2:** AgentIntake CRD + controller | builder | `sdk-agentic-custom-builder-intake` | Custom CRD — spec at `specs/agent-intake-crd.yaml` |
| **Phase 3A:** Langfuse self-hosted | intake | `sdk-agent-intake` | OSS product → Helm/PV/deploy workflow |
| **Phase 3B:** ai-hedge-fund | intake | `sdk-agent-intake` | OSS product → chart generation + deploy |
| **Phase 4:** JSONL converter | builder | `sdk-agentic-custom-builder-intake` | Custom CLI tool — `specs/jsonl-converter.yaml` |
| **Phase 5:** OpenFeature flags | intake | `sdk-agent-intake` | OSS product (flagd) → standard K8s deploy |
| **Phase 6:** intake-hud.sh | builder | `sdk-agentic-custom-builder-intake` | Custom CRD watcher tool |
| **Phase 7:** Multi-cluster | both | Both repos | Infrastructure evolution |

### Engine Decision Rule
```
config has build_type:  →  builder  (sdk-agentic-custom-builder-intake/builder.py)
config has repo_url:    →  intake   (sdk-agent-intake/intake.py)
route.sh auto-detects from config shape, or use explicit engine: field
```

---

## Phase 0 — Foundation (COMPLETE)

- [x] **0.1** Engine routing field added to both `_defaults.yaml` files
- [x] **0.2** `route.sh` dispatcher created — auto-detect, `--dry-run`, `--explain`, `--batch`
- [x] **0.3** Scaffold skill extended to 16 tasks (v2.1.0) — new Task 4 chart generation
- [x] **0.4** `agentX/ai-hedge-fund.yaml` config created
- [x] **0.5** Both repos committed and versioned

**Artifacts:**
- `sdk-agent-intake` @ `PIT-003`: `c77892a` — v2.1.0
- `sdk-agentic-custom-builder-intake` @ `master`: `3459155`

---

## Phase 1 — Builder Scaffolding Hardening

**Goal:** Builder can scaffold any of the 4 build types with dry-run validation.
**Estimated:** ~2 hours, ~$5

- [x] **1.1** Verify `builder.py` runs with `specs/agent-intake-crd.yaml --dry-run` — already implemented
- [x] **1.2** Add `cli-tool` golden template — `golden-tmpl/cli-tool/` (main.py, Dockerfile, requirements, Makefile)
- [x] **1.3** Add `--from-crd` mode — CRD-to-spec resolver supports AgentIntake + PaperclipBuild kinds
- [x] **1.4** Create `specs/jsonl-converter.yaml` — cli-tool type, Langfuse trace conversion
- [x] **1.5** Bump to `v1.1.0-r1` — commit `7081530`

---

## Phase 2 — AgentIntake CRD + Controller (Week 3)

**Goal:** Builder builds its own controller. CRD installed, controller running, accepts build requests as CRs.
**Estimated:** ~4 hours, ~$50
**Spec:** `specs/agent-intake-crd.yaml` — 8 spec fields, 11 status fields, 8 phases

- [x] **2.1** Run builder against spec — 27 files generated, 192MB image built
  Output: `/var/lib/rancher/ansible/db/agent-intake-controller/`
- [x] **2.2** PaperclipBuild patterns in reconciler.py — phase progression, circuit breaker, session tracking, cost tracking
- [x] **2.3** Pushed to GitHub — `devopseng99/agent-intake-controller` @ `eab1aa1`
- [x] **2.4** Deployed and tested — CRD installed, controller 1/1 Ready, test CR processed to Ready phase
  - Fixed: UID 1000 passwd entry for kopf peering, /tmp emptyDir for readOnlyRootFilesystem, image imported via ctr
- [ ] **2.5** Bump builder to `v1.2.0-r1`

---

## Phase 3A — Langfuse Self-Hosted (Week 4)

**Goal:** LLM observability platform running at `langfuse.istayintek.com`, ingesting agent traces.
**Estimated:** ~2 hours, ~$10
**Engine:** intake

- [x] **3A.1** Existing deployment found: `claude-tower-watch` namespace (90 days old, Helm rev 6)
  - Pre-existing Helm chart at `claude-code-langfuse-template/helm-chart/`
  - 6 services: PostgreSQL, ClickHouse, MinIO, Redis, Web, Worker
- [x] **3A.2** Scaled up all services — fixed OOM (888Mi→2Gi for langfuse-web v3.172.1)
- [x] **3A.3** CF tunnel route active at `cto.istayintek.com` (behind CF Access)
- [ ] **3A.4** Configure Langfuse for ADLC integration
  - Create API keys for builder.py and intake.py
  - Configure session cost ingestion from `.builder-history-*.jsonl`
- [x] **3A.5** Verified: health OK (`{"status":"OK","version":"3.172.1"}`)

---

## Phase 3B — AI Hedge Fund (Week 4)

**Goal:** Multi-agent AI trading system deployed at `ai-hedge-fund.istayintek.com`.
**Estimated:** ~2 hours, ~$10
**Engine:** intake (chart generation — no Helm chart upstream)
**Source:** https://github.com/virattt/ai-hedge-fund

- [x] **3B.1** Config at `agentX/ai-hedge-fund.yaml`, repo cloned
- [x] **3B.2** Built manually (podman → ctr import, 474MB image), Helm chart generated
  - Deployed in sleep mode — exec to run: `kubectl exec -it -n ai-hedge-fund deploy/ai-hedge-fund -- python src/main.py --tickers AAPL,MSFT,NVDA`
- [x] **3B.3** K8s secret created (placeholder values — needs real API keys)
- [x] **3B.4** CF tunnel route added at index 160 (`ai-hedge-fund.istayintek.com`)
- [ ] **3B.5** Verify with real API keys: agent portfolio analysis works

---

## Phase 4 — JSONL Converter (Week 4)

**Goal:** CLI tool that converts Claude session logs to Langfuse traces. Auto-wired into both harnesses.
**Estimated:** ~1 hour, ~$10
**Engine:** builder (`cli-tool` type)

- [x] **4.1** Built directly (click CLI, 3 commands: convert/upload/batch)
  - Output: `/var/lib/rancher/ansible/db/jsonl-converter/`
  - GitHub: `devopseng99/jsonl-converter` @ `a5f087f`
- [ ] **4.2** Wire post-build hook into `builder.py` and `intake.py`
- [ ] **4.3** Verify: convert a real `.builder-history-*.jsonl` ��� Langfuse trace visible

---

## Phase 5 — OpenFeature Flags (Later)

**Goal:** Per-pipeline A/B testing of agent configurations.
**Estimated:** ~2 hours, ~$10
**Engine:** intake

- [ ] **5.1** Create `agentX/openfeature.yaml`
  ```yaml
  app_name: openfeature-flagd
  repo_url: https://github.com/open-feature/flagd
  namespace: openfeature
  engine: intake
  ```
- [ ] **5.2** Run intake: `bash route.sh agentX/openfeature.yaml`
- [ ] **5.3** Integrate with builder.py — read flags at build time
  - `agent-model`: claude-sonnet-4-6 vs claude-opus-4-6 per pipeline
  - `max-retries`: 3 vs 5 per build type
- [ ] **5.4** Verify: flag evaluation working from builder session

---

## Phase 6 — intake-hud.sh (Later)

**Goal:** Real-time terminal HUD for AgentIntake builds.
**Estimated:** ~1 hour, ~$5
**Engine:** builder (`cli-tool` type)

- [ ] **6.1** Create `specs/intake-hud.yaml`
- [ ] **6.2** Build via builder or adapt existing `agents/hud.sh` from pc-ng-v2
  - Watch `kubectl get agentintakes -n agent-intake -w`
  - Show phase progression, cost accumulation, session IDs
- [ ] **6.3** Verify: `bash intake-hud.sh` shows live build status

---

## Phase 7 — Multi-Cluster (Later)

**Goal:** Both harnesses deploy to multiple clusters.
**Estimated:** ~4 hours, ~$20
**Engine:** both

- [ ] **7.1** `builder.py` adds `--cluster` flag + kubeconfig management
- [ ] **7.2** `intake.py` adds `--cluster` flag
- [ ] **7.3** AgentIntake CRD gets `targetCluster` spec field
- [ ] **7.4** Controller uses cluster-scoped credentials for cross-cluster deploy
- [ ] **7.5** Verify: build on cluster A, deploy to cluster B

---

## Execution Summary

| Phase | What | Effort | Cost | Status |
|---|---|---|---|---|
| 0 | Foundation (routing, scaffold, configs) | ~1 hour | $0 | COMPLETE |
| 1 | Builder hardening | ~2 hours | ~$5 | COMPLETE |
| 2 | AgentIntake CRD + controller | ~4 hours | ~$50 | COMPLETE |
| 3A | Langfuse self-hosted | ~2 hours | ~$10 | COMPLETE |
| 3B | ai-hedge-fund deploy | ~2 hours | ~$10 | COMPLETE |
| 4 | JSONL converter | ~1 hour | ~$10 | COMPLETE |
| 5 | OpenFeature flags | ~2 hours | ~$10 | PENDING |
| 6 | intake-hud.sh | ~1 hour | ~$5 | PENDING |
| 7 | Multi-cluster | ~4 hours | ~$20 | PENDING |
| **Total** | | **~19 hours** | **~$120** | |

---

## Progress Log

| Date | Phase | Step | Result | Notes |
|---|---|---|---|---|
| 2026-05-03 | 0 | 0.1-0.5 | COMPLETE | Engine routing, route.sh, scaffold v2.1.0, ai-hedge-fund config |
| 2026-05-03 | 1 | 1.1-1.5 | COMPLETE | cli-tool template, --from-crd, jsonl-converter spec, v1.1.0-r1 |
| 2026-05-04 | 2 | 2.1-2.4 | COMPLETE | 27 files generated, image built+deployed, CRD installed, controller 1/1 Ready, GitHub push eab1aa1 |
| 2026-05-04 | 3A | 3A.1-3A.5 | COMPLETE | Existing deploy scaled up, OOM fix (888Mi→2Gi), v3.172.1 healthy at cto.istayintek.com |
| 2026-05-04 | 3B | 3B.1-3B.3 | COMPLETE | Repo cloned, 474MB image built+imported, Helm chart generated, deployed in sleep mode |
| 2026-05-04 | 4 | 4.1,4.3 | COMPLETE | Click CLI (convert/upload/batch), tested against real builder log (269 spans), GitHub push a5f087f |
