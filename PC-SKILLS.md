# Paperclip Pipeline — Skills Reference

All skills live in `.claude/skills/` and are invoked with `/skill-name [arguments]`.

---

## /pc-status

**Purpose:** Full pipeline health check — CRD phases, workers, circuit breaker, showroom, cluster resources.

**Arguments:** None

**Examples:**
```
/pc-status
```

**What it shows:**
- CRD counts by phase (Deployed, Deploying, Building, Pending, Failed, NoBuildScript)
- Per-pipeline breakdown (19 pipelines, phases per pipeline)
- Worker status (running/stopped, PID, current build, log tails)
- Circuit breaker state per pipeline (closed/open/half-open)
- Emergency halt status
- Showroom sync (total synced, SSE clients, DB health)
- Company counts per PC instance (pc, pc-v2, pc-v4, pc-v5)

**When to use:** Anytime you want a snapshot of the entire pipeline system.

---

## /pc-start

**Purpose:** Start pipeline workers. Clears emergency halt and circuit breaker first.

**Arguments:**
| Flag | Description | Default |
|------|-------------|---------|
| `--pipeline NAME` | Start only this pipeline's worker | v1 + tech |
| `--concurrency N` | Max parallel builds | 2 |
| `--auto-build` | Auto-trigger Phase B after Phase A pushes code | off |
| `--with-supervisor` | Also start the pipeline supervisor | off |
| `--with-deploy` | Supervisor auto-deploys (requires --with-supervisor) | off |

**Examples:**
```
# Start invest-bots worker at concurrency 1
/pc-start --pipeline invest-bots --concurrency 1

# Start retail pipeline with auto Phase B chaining
/pc-start --pipeline retail --concurrency 1 --auto-build

# Start default workers (v1 + tech) with supervisor
/pc-start --concurrency 2 --with-supervisor

# Full autonomous mode — Phase A + auto Phase B + supervisor
/pc-start --pipeline soa --concurrency 1 --auto-build --with-supervisor --with-deploy
```

**What it does:**
1. Removes `/tmp/pc-autopilot/.emergency-halt`
2. Resets all circuit breaker state files to `closed`
3. Starts `workers-start.sh` with specified flags
4. Optionally starts `pipeline-supervisor.sh`
5. Runs `workers-status.sh` to verify

**Important:** Concurrency >4 causes Claude API 429 rate limit failures. Use 4 max for a single pipeline, 2 for multi-pipeline.

---

## /pc-halt

**Purpose:** Emergency stop — kills ALL pipeline workers, supervisor, batch deploy, and Claude processes immediately.

**Arguments:** None

**Examples:**
```
# Something going wrong? Stop everything now
/pc-halt
```

**What it does:**
1. Runs `emergency-halt.sh` — kills all worker PIDs, supervisor, batch-deploy, Claude subprocesses
2. Creates `/tmp/pc-autopilot/.emergency-halt` file (prevents auto-restart)
3. Verifies nothing is still running

**To resume:** Use `/pc-start` (it clears the halt file).

---

## /pc-build

**Purpose:** Trigger Phase B — clone repos from GitHub, run `npm build`, deploy static files to shared nginx pod. This is the canonical build/deploy skill.

**Arguments:**
| Flag | Description | Default |
|------|-------------|---------|
| `--pipeline NAME` | Build only apps from this pipeline | all Deploying |
| `--crd NAME` | Build a single app by CRD name | — |
| `--concurrency N` | Parallel builds | 1 (max: 4) |
| `--retry-failed` | Retry previously failed builds | off |
| `--dry-run` | Preview without building | off |
| `--limit N` | Build only first N apps | all |

**Examples:**
```
# Build all 15 invest-bots apps (Phase A complete, all Deploying)
/pc-build --pipeline invest-bots --concurrency 4

# Build a single app
/pc-build --crd pb-60301-qet

# Preview what would be built
/pc-build --dry-run

# Build all Deploying apps across all pipelines
/pc-build --concurrency 4

# Retry failed builds
/pc-build --retry-failed --pipeline soa --concurrency 2

# Build first 5 apps only
/pc-build --pipeline v1 --limit 5 --concurrency 2
```

**What it does:**
1. Shows the build queue (Deploying CRDs, grouped by pipeline)
2. Runs `build-and-deploy.sh` from the pc repo (clones repo → detects framework → npm build → kubectl cp to nginx → patches CRD to Deployed)
3. Shows updated phase counts

**Script location:** `/var/lib/rancher/ansible/db/pc/builder/build-and-deploy.sh`

---

## /pc-deploy

**Purpose:** Alias for `/pc-build`. Identical behavior.

**Examples:**
```
# These are equivalent:
/pc-deploy --pipeline invest-bots --concurrency 4
/pc-build --pipeline invest-bots --concurrency 4
```

---

## /pc-build-fix

**Purpose:** Fix failed Phase B builds using Claude Code to make targeted code patches instead of full Phase A regeneration (which costs 5+ min and heavy API usage).

**Arguments:**
| Flag | Description | Default |
|------|-------------|---------|
| `--crd NAME` | Fix a single app | — |
| `--pipeline NAME` | Fix all failed apps in a pipeline | — |
| `--all-failed` | Fix all failed apps | off |
| `--max-fixes N` | Max fix attempts per app | 3 |

**Examples:**
```
# Fix a specific failed app
/pc-build-fix --crd pb-60301-qet --max-fixes 3

# Fix all failed SOA apps (18 failures, turbo-astro build errors)
/pc-build-fix --pipeline soa

# Fix all 85 failed apps across all pipelines
/pc-build-fix --all-failed

# Limit fix attempts to 2 per app
/pc-build-fix --all-failed --max-fixes 2
```

**What it does per app:**
1. Reads npm build error from log
2. Clones the repo
3. Feeds error to Claude Code (`claude -p` with `--dangerously-skip-permissions`)
4. Claude makes a minimal targeted fix
5. Pushes fix to GitHub
6. Resets CRD to Deploying
7. Retries `build-and-deploy.sh`
8. Repeats up to `--max-fixes` times if still failing

**Script location:** `/var/lib/rancher/ansible/db/pc/builder/build-fix-loop.sh`

**Known issue:** while-read subshell bug breaks counters — run standalone, not chained.

---

## /pc-reset

**Purpose:** Reset Failed CRDs back to Pending so workers can retry them. Optionally rotates logs.

**Arguments:**
| Flag | Description | Default |
|------|-------------|---------|
| `--all-failed` | Reset all Failed CRDs | yes (if no --app-id) |
| `--app-id N` | Reset a specific app ID | — |
| `--rotate-logs` | Archive old logs before reset | off |

**Examples:**
```
# Reset all 85 failed apps to Pending
/pc-reset --all-failed

# Reset a specific app
/pc-reset --app-id 60301

# Reset with clean log slate
/pc-reset --all-failed --rotate-logs
```

**What it does:**
1. Archives logs to `/tmp/pc-autopilot/logs-archive-{timestamp}/` (if `--rotate-logs`)
2. Shows all Failed CRDs with error messages
3. Patches each Failed CRD: `status.phase=Pending`, `status.errorMessage=""`
4. Resets all circuit breaker state files to `closed`
5. Shows updated phase counts

**After reset:** Run `/pc-start` to start workers that will pick up the newly Pending CRDs.

---

## /pc-new-pipeline

**Purpose:** Create a brand new pipeline end-to-end — generate app ideas, write `.def` file, create manifest JSON, register in ConfigMap, generate CRDs, optionally start workers.

**Arguments:** Natural language description of the app theme + optional flags.
| Element | Description | Default |
|---------|-------------|---------|
| Theme | Description of what kind of apps | required |
| Count | Number of apps | 20 |
| Instance | Target PC instance | pc-v4 |
| Action | `plan` or `auto-apply` | plan |

**Examples:**
```
# Plan 20 health & fitness apps (dry run)
/pc-new-pipeline 20 health and fitness apps — gym trackers, nutrition, meditation, wearable sync

# Create 15 fintech apps and start building immediately
/pc-new-pipeline 15 fintech payment processing apps with Stripe, Plaid, crypto wallets, auto-apply

# Create 10 real estate apps targeting pc-v4
/pc-new-pipeline 10 real estate apps — property management, MLS search, mortgage calculators

# Kick off 15 AI trading bots
/pc-new-pipeline 15 investment trading bots with stock/crypto/ETF recommendations, RSS feeds, RBAC, audit logging, auto-apply
```

**What it does:**
1. Gets next available app ID range (`generate-manifest.sh --next-id`)
2. Checks existing pipelines for name/prefix collisions
3. Generates diverse app concepts as a `.def` file (startup-style names, concrete features, distinct designs)
4. Runs `new-pipeline.sh` which:
   - Converts `.def` → manifest JSON
   - Registers pipeline in `pipeline-registry` ConfigMap
   - Creates workspace symlink
   - Generates CRDs (idempotent)
   - Starts workers (auto-apply only)

**Files created:**
- `pipeline/defs/{pipeline}.def` — App definitions
- `pipeline/manifests/{pipeline}.json` — Generated manifest
- CRDs in `paperclip-v3` namespace

**Important:**
- Always runs `plan` first unless user explicitly says "auto-apply", "kick it off", "start building"
- Prefixes must be unique 3-letter codes across ALL existing pipelines
- CRD uses pattern regex — no CRD YAML edits needed for new pipeline names

---

## /pc-provision

**Purpose:** Provision (or teardown) a complete Paperclip instance — Helm install, bootstrap admin user + API key, CF tunnel route, DNS CNAME, validation.

**Arguments:**
| Flag | Description | Default |
|------|-------------|---------|
| `NAME` | Instance name (e.g. `pc-v8`) | required |
| `--teardown` | Remove the instance entirely | off |
| `--node NODE` | Target worker node | mgplcb05 |
| `--email EMAIL` | Admin email | hrsd0001@gmail.com |
| `--dry-run` | Show plan without executing | off |

**Examples:**
```
# Provision a new instance
/pc-provision pc-v8

# Provision on a specific node
/pc-provision pc-v8 --node mgplcb03

# Dry run — see what would happen
/pc-provision pc-v8 --dry-run

# Tear down an instance completely
/pc-provision pc-v6 --teardown
```

**What it does (provision):**
1. Pre-flight: verifies Helm chart, checks if instance exists, validates CF token
2. Runs `provision-pc.sh` which handles:
   - Namespace creation
   - Persistent volume setup on target node
   - Helm install with generated overrides
   - Bootstrap: admin user sign-up + API key generation + K8s secrets
   - CF tunnel route (inserted BEFORE wildcard via CF API)
   - DNS CNAME creation
3. Validates: pod health, external URL, API key works

**What it does (teardown):**
1. Runs `provision-pc.sh --teardown`
2. Removes: Helm release, tunnel route, DNS record, namespace, PVs
3. Verifies removal

**Name derivation:**
- `pc-v8` → Release: `pc-v8`, Namespace: `paperclip-v8`, URL: `https://pc-v8.istayintek.com`

**Critical notes:**
- CF tunnel route goes to REMOTE API config (not just local ConfigMap)
- Routes must be inserted BEFORE the `*.istayintek.com` wildcard entry
- Bootstrap password is generated ONCE and used for both sign-up and K8s secret

---

## Quick Reference

| Task | Command |
|------|---------|
| Check everything | `/pc-status` |
| Build 15 invest-bots apps | `/pc-build --pipeline invest-bots --concurrency 4` |
| Fix all failed builds | `/pc-build-fix --all-failed` |
| Reset failures for retry | `/pc-reset --all-failed` |
| Start a worker | `/pc-start --pipeline soa --concurrency 1` |
| Full autonomous pipeline | `/pc-start --pipeline retail --concurrency 1 --auto-build --with-supervisor` |
| Stop everything | `/pc-halt` |
| Create 20 new apps | `/pc-new-pipeline 20 health fitness apps` |
| Provision new instance | `/pc-provision pc-v8` |
| Tear down instance | `/pc-provision pc-v6 --teardown` |

---

## Workflow Cheat Sheet

### New pipeline from scratch
```
/pc-new-pipeline 15 cybersecurity apps — SIEM, vulnerability scanners, pen test tools, auto-apply
# Wait for Phase A to complete (check with /pc-status)
/pc-build --pipeline cyber --concurrency 4
# Fix any failures
/pc-build-fix --pipeline cyber
```

### Recover from mass failures
```
/pc-status                          # See what's broken
/pc-reset --all-failed --rotate-logs  # Reset to Pending, clean logs
/pc-start --pipeline soa --concurrency 1  # Restart workers
# Or fix builds directly without full regen:
/pc-build-fix --pipeline soa --max-fixes 3
```

### End-to-end autonomous
```
/pc-start --pipeline retail --concurrency 1 --auto-build --with-supervisor --with-deploy
# Apps go: Pending → Building → Deploying → Deployed with zero manual steps
# Monitor with /pc-status
```
