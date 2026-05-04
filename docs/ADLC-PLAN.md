# ADLC Enterprise Agentic Build Pipeline

**Version:** 1.0.0
**Created:** 2026-05-03
**Last Updated:** 2026-05-03
**Status:** IN PROGRESS — Phase 0 complete, Phase 1 starting

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

- [ ] **1.1** Verify `builder.py` runs with `specs/agent-intake-crd.yaml --dry-run`
  - If `--dry-run` not implemented, add it (skip Tasks 10-12: build/deploy/verify)
  - Confirms: spec loading, defaults merge, skill resolution, output dir creation
- [ ] **1.2** Add `cli-tool` golden template
  - Create `golden-tmpl/cli-tool/` with: `main.py.tmpl`, `Dockerfile.tmpl`, `requirements.txt.tmpl`, `Makefile.tmpl`
  - Unblocks JSONL converter (Phase 4)
- [ ] **1.3** Verify `--from-crd` mode
  - `builder.py` docstring declares it — verify it reads AgentIntake CRDs
  - Enables controller-triggered builds (the full self-bootstrapping loop)
- [ ] **1.4** Create `specs/jsonl-converter.yaml`
  - `app_name: jsonl-converter`, `build_type: cli-tool`
  - Converts Claude session JSONL to Langfuse trace format
- [ ] **1.5** Bump to `v1.1.0-r1`
  - `bash release.sh --bump minor --notes "dry-run, cli-tool template, from-crd mode"`

---

## Phase 2 — AgentIntake CRD + Controller (Week 3)

**Goal:** Builder builds its own controller. CRD installed, controller running, accepts build requests as CRs.
**Estimated:** ~4 hours, ~$50
**Spec:** `specs/agent-intake-crd.yaml` — 8 spec fields, 11 status fields, 8 phases

- [ ] **2.1** Run builder against spec
  ```bash
  cd /var/lib/rancher/ansible/db/sdk-agentic-custom-builder-intake
  python3 builder-tmpl/builder.py specs/agent-intake-crd.yaml
  ```
  12-task skill generates: CRD YAML, kopf controller, Helm chart, RBAC, Dockerfile, tests, docs
  Output: `/var/lib/rancher/ansible/db/agent-intake-controller/`
- [ ] **2.2** Wire PaperclipBuild patterns into generated `reconciler.py`
  - Phase progression: Pending → Validating → Generating → Building → Deploying → Verifying → Ready
  - Circuit breaker: per-app state files, 10 consecutive fail hard-stop, 120s cooldown
  - Error message IS the prompt: Failed phase stores descriptive error
  - Session tracking: `sessionId` in status for resume-on-failure
  - Cost tracking: `buildCostUsd` from Claude session cost.txt
- [ ] **2.3** Push to GitHub (`devopseng99/agent-intake-controller`, private)
- [ ] **2.4** Deploy and test
  ```bash
  kubectl create ns agent-intake
  helm install agent-intake-controller ./helm/agent-intake-controller -n agent-intake
  kubectl get crd agentintakes.agentintake.istayintek.com
  # Create test CR
  kubectl apply -f test-agentintake.yaml
  kubectl get agentintakes -n agent-intake -w
  ```
- [ ] **2.5** Bump builder to `v1.2.0-r1`

---

## Phase 3A — Langfuse Self-Hosted (Week 4)

**Goal:** LLM observability platform running at `langfuse.istayintek.com`, ingesting agent traces.
**Estimated:** ~2 hours, ~$10
**Engine:** intake

- [ ] **3A.1** Create `agentX/langfuse.yaml` config
  ```yaml
  app_name: langfuse
  repo_url: https://github.com/langfuse/langfuse
  namespace: langfuse
  engine: intake
  pv_size: 20Gi
  ```
- [ ] **3A.2** Run intake: `python3 sdk-tmpl/intake.py agentX/langfuse.yaml`
  - 16-task workflow: namespace, PVs, Helm deploy, ingress, health checks, DNS
- [ ] **3A.3** Add CF tunnel route (`langfuse.istayintek.com`)
- [ ] **3A.4** Configure Langfuse for ADLC integration
  - Create API keys for builder.py and intake.py
  - Configure session cost ingestion from `.builder-history-*.jsonl`
- [ ] **3A.5** Verify: `curl -s https://langfuse.istayintek.com/api/health`

---

## Phase 3B — AI Hedge Fund (Week 4)

**Goal:** Multi-agent AI trading system deployed at `ai-hedge-fund.istayintek.com`.
**Estimated:** ~2 hours, ~$10
**Engine:** intake (chart generation — no Helm chart upstream)
**Source:** https://github.com/virattt/ai-hedge-fund

- [ ] **3B.1** Config already created: `agentX/ai-hedge-fund.yaml`
  - Python (Poetry) + TypeScript, Dockerfile in `docker/`
  - No Helm chart → scaffold Task 4 generates one
  - Needs: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `FINANCIAL_DATASETS_API_KEY`
  - Ports: web (8501 Streamlit), api (8000)
- [ ] **3B.2** Run intake: `bash route.sh agentX/ai-hedge-fund.yaml`
  - Task 3 detects: `HAS_CHART=false`, `HAS_DOCKERFILE=true` (docker/)
  - Task 4 generates Helm chart from Dockerfile + docker-compose analysis
  - Task 5 builds container image with podman, imports to RKE2
  - Tasks 6-16 deploy as normal
- [ ] **3B.3** Create K8s secrets for API keys
- [ ] **3B.4** Add CF tunnel route (`ai-hedge-fund.istayintek.com`)
- [ ] **3B.5** Verify: web UI accessible, agent portfolio analysis works

---

## Phase 4 — JSONL Converter (Week 4)

**Goal:** CLI tool that converts Claude session logs to Langfuse traces. Auto-wired into both harnesses.
**Estimated:** ~1 hour, ~$10
**Engine:** builder (`cli-tool` type)

- [ ] **4.1** Run builder: `python3 builder-tmpl/builder.py specs/jsonl-converter.yaml`
  - Generates: Python CLI, Dockerfile, tests, Makefile
  - Output: `/var/lib/rancher/ansible/db/jsonl-converter/`
- [ ] **4.2** Wire post-build hook into `builder.py` and `intake.py`
  ```python
  if os.environ.get("LANGFUSE_HOST"):
      subprocess.run(["jsonl-converter", log_path, "--upload"])
  ```
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
| 1 | Builder hardening | ~2 hours | ~$5 | PENDING |
| 2 | AgentIntake CRD + controller | ~4 hours | ~$50 | PENDING |
| 3A | Langfuse self-hosted | ~2 hours | ~$10 | PENDING |
| 3B | ai-hedge-fund deploy | ~2 hours | ~$10 | PENDING |
| 4 | JSONL converter | ~1 hour | ~$10 | PENDING |
| 5 | OpenFeature flags | ~2 hours | ~$10 | PENDING |
| 6 | intake-hud.sh | ~1 hour | ~$5 | PENDING |
| 7 | Multi-cluster | ~4 hours | ~$20 | PENDING |
| **Total** | | **~19 hours** | **~$120** | |

---

## Progress Log

| Date | Phase | Step | Result | Notes |
|---|---|---|---|---|
| 2026-05-03 | 0 | 0.1-0.5 | COMPLETE | Engine routing, route.sh, scaffold v2.1.0, ai-hedge-fund config |
