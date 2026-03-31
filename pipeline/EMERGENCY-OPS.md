# Pipeline Emergency Operations & Manual Override

## STOP EVERYTHING (one command)

```bash
pipeline/scripts/emergency-halt.sh
```

This kills: workers, supervisor, batch deploy, and all Claude processes.
Creates `/tmp/pc-autopilot/.emergency-halt` file which prevents any restarts.

To resume after halt:
```bash
pipeline/scripts/emergency-halt.sh --resume
pipeline/scripts/workers-start.sh
```

---

## Quick Reference — What's Running & How to Stop It

| Process | PID File | Stop Command | What It Does |
|---------|----------|-------------|--------------|
| **v1 worker** | `.workers/v1.pid` | `workers-start.sh --stop` | Phase A codegen for apps 201-400 |
| **tech worker** | `.workers/tech.pid` | `workers-start.sh --stop` | Phase A codegen for apps 401-600 |
| **supervisor** | `.workers/supervisor.pid` | `kill $(cat .workers/supervisor.pid)` | 30s monitor loop, auto-retry, auto-deploy |
| **batch deploy** | *(no pidfile)* | `pkill -f batch-deploy-k8s` | Phase B K8s deploy of ready apps |
| **Claude sessions** | *(child of workers)* | `pkill -f 'claude.*--dangerously-skip'` | Active AI code generation |
| **monitor loop** | *(no pidfile)* | `pkill -f monitor-loop` | Background status logger |

All PID files are under `/tmp/pc-autopilot/.workers/`.

## Check What's Running

```bash
# Quick status of everything
pipeline/scripts/emergency-halt.sh --status

# Detailed worker + CRD status
pipeline/scripts/workers-status.sh

# Live dashboard (auto-refresh)
pipeline/scripts/workers-dashboard.sh

# Just Claude processes
pgrep -fa 'claude.*--dangerously-skip'

# Just pipeline scripts
pgrep -fa 'phase-a\|batch-deploy\|supervisor\|workers'
```

## Safe Kill Order (manual)

If you need to stop things manually, follow this order to avoid orphaned processes:

```bash
# 1. Create halt file FIRST (prevents restarts)
touch /tmp/pc-autopilot/.emergency-halt

# 2. Stop workers (they manage Claude child processes)
pipeline/scripts/workers-start.sh --stop

# 3. Stop supervisor (it would restart workers)
kill $(cat /tmp/pc-autopilot/.workers/supervisor.pid) 2>/dev/null

# 4. Stop batch deploy
pkill -f batch-deploy-k8s

# 5. Wait for active Claude sessions to finish (or kill them)
#    WAIT (graceful):
sleep 30 && pgrep -fa 'claude.*--dangerously-skip'
#    KILL (immediate):
pkill -f 'claude.*--dangerously-skip'
```

**DO NOT** `kill -9` Claude processes unless SIGTERM doesn't work after 10s.
SIGTERM lets Claude finish the current file write; SIGKILL can leave half-written files.

## Circuit Breaker

The circuit breaker auto-halts new builds when failure rate spikes.

```bash
# Check breaker state
cat /tmp/pc-autopilot/.circuit-breaker-state
# Values: closed (normal) | open (tripped) | half-open (testing)

# Manually trip (stop new builds, let active ones finish)
echo "open" > /tmp/pc-autopilot/.circuit-breaker-state

# Manually reset
echo "closed" > /tmp/pc-autopilot/.circuit-breaker-state

# View recent build results (pass/fail log)
tail -20 /tmp/pc-autopilot/.circuit-breaker-results
```

**Breaker triggers:**
- 3 consecutive failures
- 40%+ failure rate in last 10 builds
- Usage cap detected in build output

**Breaker vs Emergency Halt:**
- Breaker: pauses new builds, waits for cooldown, auto-recovers
- Emergency halt: kills everything immediately, requires manual resume

## Script Reference

### Active Pipeline Scripts

| Script | Purpose | Run As |
|--------|---------|--------|
| `phase-a-codegen.sh` | Code generation via Claude Code | Background (via workers-start.sh) |
| `batch-deploy-k8s.sh` | Deploy built apps to K8s | Foreground or via supervisor |
| `deploy-k8s-static.sh` | Single app deploy (clone, build, nginx, CF tunnel) | Called by batch-deploy |
| `workers-start.sh` | Start/stop background codegen workers | Manual |
| `workers-status.sh` | One-shot status check | Manual |
| `workers-dashboard.sh` | Auto-refreshing dashboard | Manual (foreground) |
| `pipeline-supervisor.sh` | Autonomous monitor + error recovery loop | Background |
| `emergency-halt.sh` | Kill switch for all operations | Manual |
| `monitor-loop.sh` | Background status logger (writes to monitor.log) | Background |
| `generate-prompt.sh` | Generates Claude build prompt for an app | Called by phase-a |

### Legacy Scripts (DO NOT USE)

| Script | Why Not |
|--------|---------|
| `autopilot-build.sh` | Old single-phase pipeline, replaced by phase-a + batch-deploy |
| `launch-autopilot.sh` | Old launcher, replaced by workers-start.sh |
| `launch-tech-pipeline.sh` | Old launcher, replaced by workers-start.sh |
| `launch-codegen-v1.sh` | Thin wrapper, use workers-start.sh --pipeline v1 |
| `launch-codegen-tech.sh` | Thin wrapper, use workers-start.sh --pipeline tech |

### Support Scripts

| Script | Purpose |
|--------|---------|
| `deploy-cf.sh` | Cloudflare Pages deploy (not used in current pipeline) |
| `ingest-website.sh` | Website content ingestion for prompt generation |
| `monitor.sh` | Simple one-shot monitor (use workers-status.sh instead) |

## Key Files & Directories

```
/tmp/pc-autopilot/
  .emergency-halt                  # EXISTS = all operations halt
  .circuit-breaker-state           # closed/open/half-open
  .circuit-breaker-results         # rolling pass/fail log
  .circuit-breaker-tripped         # timestamp of last trip
  .pid-codegen-v1                  # PID guard for v1 pipeline
  .pid-codegen-tech                # PID guard for tech pipeline
  .ready-to-deploy/                # JSON files for apps ready for Phase B
  .workers/
    v1.pid / tech.pid              # worker parent PIDs
    v1.log / tech.log              # worker output logs
    supervisor.pid                 # supervisor PID
    supervisor.log                 # supervisor action log
    supervisor-console.log         # supervisor stdout/stderr
    monitor.log                    # monitor-loop output
  logs/                            # per-app build logs (PREFIX-TIMESTAMP.log)
  logs/batch-YYYYMMDD-HHMMSS/     # per-app deploy logs
  manifests/                       # symlinks to app manifests
  registry/                        # deployed.json registry
```

## Common Recovery Scenarios

### "Out of extra usage" (Claude Max cap)
```bash
# 1. Circuit breaker should auto-trip. If not:
pipeline/scripts/emergency-halt.sh
# 2. Wait until 11am CT
# 3. Resume
pipeline/scripts/emergency-halt.sh --resume
pipeline/scripts/workers-start.sh
```

### Lots of failures, wasting tokens
```bash
# Circuit breaker trips automatically at 3 consecutive or 40% failure rate.
# If you want to stop immediately:
pipeline/scripts/emergency-halt.sh
# Check what failed:
grep "FAILED\|fail" /tmp/pc-autopilot/.workers/v1.log | tail -10
grep "FAILED\|fail" /tmp/pc-autopilot/.workers/tech.log | tail -10
```

### Workers stopped but apps still pending
```bash
# Check why they stopped
tail -20 /tmp/pc-autopilot/.workers/v1.log
tail -20 /tmp/pc-autopilot/.workers/tech.log
# If breaker tripped:
cat /tmp/pc-autopilot/.circuit-breaker-state
echo "closed" > /tmp/pc-autopilot/.circuit-breaker-state
# Restart
pipeline/scripts/workers-start.sh
```

### Need to redeploy a specific app
```bash
pipeline/scripts/batch-deploy-k8s.sh --app-id 284
```

### Reset failed CRDs for retry
```bash
# Reset all Failed to Pending
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys,subprocess
for i in json.load(sys.stdin)['items']:
    if i.get('status',{}).get('phase')=='Failed':
        subprocess.run(['kubectl','patch','paperclipbuild',i['metadata']['name'],
          '-n','paperclip-v3','--type','merge','--subresource=status',
          '-p','{\"status\":{\"phase\":\"Pending\",\"errorMessage\":\"\"}}'])
"
```

### Check what HITL apps need review
```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    s = i.get('status',{})
    if s.get('phase') == 'PendingHITL':
        sp = i['spec']
        print(f'#{sp[\"appId\"]} {sp[\"prefix\"]} — {s.get(\"errorMessage\",\"?\")[:80]}')
"
```
