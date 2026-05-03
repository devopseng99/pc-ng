# PC-NG Skills Reference

Complete reference for all slash commands available in the pc-ng session. Updated 2026-04-22.

Skills live in `/var/lib/rancher/ansible/db/pc-ng/.claude/skills/*/SKILL.md`.

---

## Quick Reference

| Skill | Purpose | Key Flags |
|-------|---------|-----------|
| `/pc-status` | Dashboard — CRD phases, workers, circuit breaker, showroom | (none) |
| `/pc-build` | Phase B — clone, build, deploy to Nginx PV | `--pipeline`, `--concurrency N`, `--retry-failed`, `--dry-run`, `--limit N` |
| `/pc-deploy` | Alias for `/pc-build` | (same as pc-build) |
| `/pc-build-fix` | Fix failed builds with targeted code patches | `--crd NAME`, `--pipeline NAME`, `--all-failed`, `--max-fixes N` |
| `/pc-reset` | Reset CRDs to Pending for retry | `--all-failed`, `--all-stale`, `--phase PHASE`, `--pipeline NAME` |
| `/pc-start` | Start workers + clear halt/breaker | `--pipeline NAME`, `--concurrency N`, `--with-supervisor`, `--auto-build` |
| `/pc-halt` | Emergency stop — kill everything | (none) |
| `/pc-new-pipeline` | Create pipeline end-to-end | (interactive — provide description) |
| `/pc-provision` | Provision/teardown PC instance | `NAME`, `--teardown`, `--node NODE`, `--dry-run` |

---

## /pc-status

**Purpose:** Full pipeline health dashboard.

**When to use:** Anytime you want to know what's happening — deployment progress, worker health, failures, showroom sync.

**Example usage:**
```
/pc-status
```

**What it checks:**
1. Worker processes (running/stopped, which pipeline, progress)
2. Circuit breaker state per pipeline (closed/open/half-open)
3. Emergency halt flag
4. Recent worker log activity
5. Supervisor actions (if running)
6. Showroom dashboard sync (app count, SSE clients, health)
7. Per-pipeline CRD phase breakdown (all 19 pipelines)
8. Company counts per PC instance (pc, pc-v2, pc-v4, pc-v5)

**Example output:**
```
=== CRD Phase Summary ===
  654 Deployed
   85 Failed
   29 Pending
   21 Deploying
   20 NoBuildScript

=== Per-Pipeline ===
  v1       (271): 205 Deployed, 33 Failed, 29 Pending, 4 Deploying
  tech     (203): 178 Deployed, 17 Failed, 8 NoBuildScript
  soa      ( 20): 18 Failed, 2 Deployed
  ...

=== Workers ===
  No active workers

=== Circuit Breaker ===
  v1: closed
  tech: closed
  ...

=== Showroom ===
  Showroom: healthy | SSE clients: 0 | DB: ok
  Showroom apps synced: 654

=== Companies ===
  paperclip (pc): 218 companies
  paperclip-v2 (pc-v2): 204 companies
  paperclip-v4 (pc-v4): 226 companies
  paperclip-v5 (pc-v5): 17 companies
```

---

## /pc-build

**Purpose:** Phase B — clone repos from GitHub, build static sites, deploy to Nginx wildcard PV.

**When to use:** After Phase A codegen has pushed code to GitHub and CRDs are in Pending/Deploying state.

**Example usage:**
```bash
# Build all Pending/Deploying apps at concurrency 4
/pc-build --concurrency 4

# Build only a specific pipeline
/pc-build --pipeline invest-bots --concurrency 4

# Build a single app
/pc-build --crd pb-30006-bfa

# Retry all previously failed builds
/pc-build --retry-failed --concurrency 4

# Preview what would be built
/pc-build --dry-run

# Build only first 10 apps (for testing)
/pc-build --limit 10

# Retry failed in one pipeline
/pc-build --pipeline soa --retry-failed --concurrency 2

# Combine: retry failed + new pending for a pipeline, limit to 5
/pc-build --pipeline v1 --retry-failed --concurrency 4 --limit 5
```

**What it does per app:**
1. Clones `github.com/devopseng99/{repo}`
2. Detects framework (next/turbo-next/astro/turbo-astro)
3. Patches `next.config.{mjs,js,ts}` — injects `output: "export"`, `ignoreBuildErrors`, `ignoreDuringBuilds`
4. `npm install` / `pnpm install` / `yarn install` (based on lockfile)
5. `npm run build` / `pnpm build` (turbo monorepos)
6. Locates output dir (`out/`, `apps/web/out/`, `dist/`)
7. `kubectl cp output/ nginx-static-pod:/sites/{slug}/`
8. Patches CRD status to `Deployed` with `deployUrl`
9. Cleans up `/tmp` clone

**Script:** `/var/lib/rancher/ansible/db/pc/builder/build-and-deploy.sh`

**Performance:** Concurrency 4 = ~3.5 apps/min. RAM peaks at 73%, /tmp at 38%.

**Important:**
- Max concurrency is 4. At 6+ you get API 529 errors and OOM.
- Apps deploy as static files to the Nginx PV — never as individual pods.
- The script is idempotent — re-running skips already-Deployed CRDs.

---

## /pc-deploy

**Purpose:** Alias for `/pc-build`. Identical behavior.

**Example usage:**
```bash
/pc-deploy --concurrency 4
/pc-deploy --pipeline tech --retry-failed
```

---

## /pc-build-fix

**Purpose:** Fix failed builds using Claude Code to make targeted code patches instead of full Phase A regeneration.

**When to use:** When an app fails at build time with a fixable error (missing import, type error, config issue) and regenerating the entire app would be overkill.

**Example usage:**
```bash
# Fix a single app by CRD name
/pc-build-fix --crd pb-30006-bfa

# Fix all failed apps in a pipeline
/pc-build-fix --pipeline soa

# Fix all failed across everything
/pc-build-fix --all-failed

# Limit fix attempts per app (default 3)
/pc-build-fix --max-fixes 5
```

**What it does per app:**
1. Reads the CRD error message to understand the build failure
2. Clones the repo
3. Uses Claude Code to analyze the error and make targeted code fixes
4. Retries the build
5. Repeats up to `--max-fixes` times
6. If build succeeds, deploys and patches CRD to Deployed
7. If still failing after max attempts, reports as needing full regen

**Script:** `/var/lib/rancher/ansible/db/pc/builder/build-fix-loop.sh`

**When NOT to use:**
- Apps with `NoBuildScript` phase — these have no code to fix, need full regen
- Apps that are empty scaffolds (SOA pipeline) — need prompt improvement, not code patches

---

## /pc-reset

**Purpose:** Reset CRDs back to Pending so they can be retried by `/pc-build` or picked up by workers.

**When to use:** After fixing codegen prompts, after infra issues are resolved, or to retry a stale batch.

**Example usage:**
```bash
# Reset all Failed CRDs to Pending (default behavior)
/pc-reset
/pc-reset --all-failed

# Reset EVERYTHING that isn't Deployed (Failed + NoBuildScript + Deploying + RegenerationNeeded)
/pc-reset --all-stale

# Reset only NoBuildScript CRDs
/pc-reset --phase NoBuildScript

# Reset only failed apps in SOA pipeline
/pc-reset --pipeline soa --all-failed

# Reset a specific app
/pc-reset --app-id 270

# Archive old logs before resetting (clean slate)
/pc-reset --all-stale --rotate-logs

# Reset all stale in one pipeline
/pc-reset --pipeline v1 --all-stale

# Combination: reset NoBuildScript in tech pipeline with log rotation
/pc-reset --pipeline tech --phase NoBuildScript --rotate-logs
```

**What it does:**
1. (Optional) Archives old logs to timestamped directory
2. Shows all non-Deployed CRDs with error messages
3. Patches matching CRDs: `status.phase → Pending`, clears `errorMessage`
4. Resets circuit breaker state files to `closed` (per-pipeline)
5. Shows updated phase counts

**Phase targeting:**
| Flag | Phases reset |
|------|-------------|
| `--all-failed` (default) | Failed |
| `--all-stale` | Failed, NoBuildScript, RegenerationNeeded, Deploying |
| `--phase X` | Only the specified phase |

---

## /pc-start

**Purpose:** Start pipeline workers (Phase A codegen). Clears emergency halt and circuit breaker.

**When to use:** To kick off or resume the autopilot codegen pipeline after a halt or fresh start.

**Example usage:**
```bash
# Start default pipelines (v1 + tech) at concurrency 2
/pc-start

# Start a specific pipeline
/pc-start --pipeline soa --concurrency 2

# Start with higher concurrency (max 4)
/pc-start --pipeline invest-bots --concurrency 4

# Start with supervisor for auto-recovery
/pc-start --pipeline tech --concurrency 2 --with-supervisor

# Auto-build: Phase A → Phase B with no manual gap
/pc-start --pipeline soa --concurrency 2 --auto-build

# Full auto: workers + supervisor + auto-deploy
/pc-start --pipeline v1 --concurrency 2 --with-supervisor --with-deploy
```

**What it does:**
1. Removes emergency halt file
2. Resets all circuit breaker states to `closed`
3. Starts worker processes for the target pipeline(s)
4. (Optional) Starts supervisor for auto-recovery
5. Verifies with status check

**Flags explained:**
| Flag | Effect |
|------|--------|
| `--pipeline NAME` | Start workers for only this pipeline |
| `--concurrency N` | Max parallel builds (default 2, max 4) |
| `--with-supervisor` | Start supervisor that monitors + auto-restarts workers |
| `--with-deploy` | Supervisor auto-triggers Phase B after Phase A |
| `--auto-build` | Per-app: Phase A push → immediate Phase B build (no batch gap) |

**Important:**
- Never set concurrency above 4 — causes API 529 + OOM
- Workers run on the host (tmux), not in K8s pods — they need `claude` CLI, `gh` CLI, `/tmp`
- To stop workers, use `/pc-halt`

---

## /pc-halt

**Purpose:** Emergency stop. Kills all workers, supervisor, batch deploys, and Claude processes.

**When to use:** Something is going wrong — runaway builds, OOM, API errors, or you just need everything to stop immediately.

**Example usage:**
```bash
/pc-halt
```

**What it does:**
1. Creates the emergency halt file (`/tmp/pc-autopilot/.emergency-halt`)
2. Kills all worker processes
3. Kills supervisor process
4. Kills any running build-and-deploy.sh processes
5. Kills any Claude processes spawned by workers
6. Verifies everything is stopped

**To resume:** Use `/pc-start` — it clears the halt file and restarts workers.

---

## /pc-new-pipeline

**Purpose:** Create a brand new pipeline end-to-end — from app ideas to CRDs to optional worker start.

**When to use:** When you want to add a batch of apps for a new category/theme.

**Example usage:**
```bash
# Plan mode (default) — generates everything but doesn't start
/pc-new-pipeline 15 health & fitness apps — gym trackers, meal planners, meditation

# Auto-apply — generates AND starts building
/pc-new-pipeline 20 fintech payment apps — wallets, P2P, invoicing — kick it off

# Smaller batch
/pc-new-pipeline 10 real estate apps — property search, mortgage calc, tenant management
```

**What it does:**
1. Gets next available app ID range (avoids collisions)
2. Checks existing pipelines for name/prefix conflicts
3. Generates diverse app concepts as a `.def` file with:
   - Startup-quality names (not generic)
   - Specific tech mentions (Stripe, Twilio, etc.)
   - Concrete features
   - Unique 3-letter prefixes
   - Color schemes and design vibes
4. Runs `new-pipeline.sh` which:
   - Generates manifest JSON from `.def`
   - Registers pipeline in ConfigMap registry
   - Validates pipeline name against CRD regex
   - Creates workspace symlink
   - Generates CRDs (idempotent)
   - Starts workers (auto-apply only)

**Plan vs auto-apply:**
- **Plan (default):** Everything is created but workers don't start. Shows the command to run manually.
- **Auto-apply:** Creates everything AND starts workers immediately.

**Generated files:**
- Definition: `/var/lib/rancher/ansible/db/pc-ng/pipeline/defs/{pipeline}.def`
- Manifest: `/var/lib/rancher/ansible/db/pc-ng/pipeline/manifests/use-cases-{pipeline}.json`
- CRDs: `kubectl get pb -n paperclip-v3 -l pipeline={name}`

**Important:**
- CRD pipeline field uses pattern regex — no CRD schema edits needed for new names
- All scripts auto-resolve from `pipeline-registry` ConfigMap
- Plan mode is the default — always review before applying

---

## /pc-provision

**Purpose:** Provision or teardown a full Paperclip instance — Helm install, bootstrap, CF tunnel, DNS, validation.

**When to use:** Standing up a new PC instance (e.g., pc-v6, pc-v7) or tearing one down.

**Example usage:**
```bash
# Provision a new instance
/pc-provision pc-v6

# Dry run first
/pc-provision pc-v7 --dry-run

# Specify target node
/pc-provision pc-v6 --node mgplcb05

# Custom admin email
/pc-provision pc-v6 --email admin@example.com

# Teardown an instance
/pc-provision pc-v5 --teardown
```

**What it does (provision):**
1. Pre-flight: checks Helm chart, existing instance, CF token validity
2. Creates namespace, PV dirs on target node
3. Generates Helm values file (`overrides-{release}.yaml`)
4. Helm installs Paperclip into namespace
5. Waits for pods to be ready
6. Bootstraps: creates admin user, API key, K8s secrets
7. Adds CF tunnel route via API (not configmap)
8. Adds DNS record
9. Validates: pod health, external URL, API key

**What it does (teardown):**
1. Removes CF tunnel route
2. Removes DNS record
3. Helm uninstalls
4. Deletes namespace and PVs

**Outputs:**

| Field | Example |
|-------|---------|
| Release | pc-v6 |
| Namespace | paperclip-v6 |
| URL | https://pc-v6.istayintek.com |
| Admin | hrsd0001@gmail.com |
| API Key | `kubectl get secret pc-v6-board-api-key -n paperclip-v6 ...` |

**Important:**
- CF token must be valid and not expired — check `~/cf-token--expires-*`
- CF tunnel route is API-managed (not configmap)
- After provisioning, update pipeline-to-instance mapping if this instance serves pipelines
- Helm chart lives at `/var/lib/rancher/ansible/db/pc/pc-helm-charts/charts/pc/`

---

## Common Workflows

### Deploy a new batch of apps (end to end)

```bash
# 1. Create the pipeline
/pc-new-pipeline 15 healthtech apps — patient portals, telemedicine, lab results

# 2. Review the plan output, then start
/pc-start --pipeline healthtech --concurrency 2 --auto-build

# 3. Monitor progress
/pc-status

# 4. After Phase A completes, build any remaining
/pc-build --pipeline healthtech --concurrency 4

# 5. Check results
/pc-status
```

### Recover from failures

```bash
# 1. Check what failed
/pc-status

# 2. Try targeted code fixes first
/pc-build-fix --pipeline soa

# 3. Reset remaining failures for retry
/pc-reset --pipeline soa --all-stale

# 4. Rebuild
/pc-build --pipeline soa --retry-failed --concurrency 4
```

### Full retry cycle (after pc-ng regen)

```bash
# 1. Reset all stale CRDs
/pc-reset --all-stale --rotate-logs

# 2. Rebuild everything that's Pending
/pc-build --concurrency 4

# 3. Check results
/pc-status
```

### Emergency stop and resume

```bash
# Stop everything
/pc-halt

# ... investigate the issue ...

# Resume
/pc-start --pipeline tech --concurrency 2
```

### Provision a new instance and add a pipeline

```bash
# 1. Provision
/pc-provision pc-v6 --dry-run
/pc-provision pc-v6

# 2. Create pipeline targeting the new instance
/pc-new-pipeline 20 edtech apps — LMS, quiz builders, course creators

# 3. Start building
/pc-start --pipeline edtech --concurrency 2 --auto-build
```

---

## Architecture Notes

- **All apps deploy as static files to a single Nginx pod** — never as individual K8s pods (see DECISIONS.md D-014)
- **Nginx wildcard** at `*.istayintek.com` serves 568+ sites from 9 MiB RAM
- **Build script** is at `/var/lib/rancher/ansible/db/pc/builder/build-and-deploy.sh` (pc repo, not pc-ng)
- **Workers run on the host** (tmux), not in K8s — they need claude CLI, gh CLI, /tmp
- **Pipeline registry** is a ConfigMap — all scripts auto-discover pipelines from it
- **CF tunnel** is API-managed — never edit the configmap directly
- **Max concurrency is 4** — beyond that, Claude API returns 529 and host OOMs
