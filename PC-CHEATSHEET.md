# PC-NG Cheat Sheet

## Context Switching

```bash
pc context use v1        # Switch to v1 pipeline (IDs 201-400, paperclip ns)
pc context use tech      # Switch to tech pipeline (IDs 401-600, paperclip-v2 ns)
pc context use all       # Aggregate — see both pipelines
pc context show          # Print current context + config
pc context list          # List contexts (* = active)
```

## Monitoring

```bash
pc status                # Pipeline overview (deployed/failed/building counts)
pc list                  # All apps in current context
pc list --status failed  # Partial match: shows build_failed, deploy_failed
pc list --status deployed --json  # JSON output for scripting
pc logs 221              # View build log for app #221
pc logs ptb --follow     # Tail log by prefix
pc inspect 221           # Detailed info (registry + CRD if available)
pc watch                 # Live stream: kubectl get pb --watch (or tail -f fallback)
pc dashboard             # Full-screen monitor (refreshes every 5s, Ctrl-C to exit)
pc doctor                # Health check: contexts, tmux, pods, CRDs, Redis
```

## Concurrency Control

```bash
pc concurrency get               # Show current concurrency
pc concurrency set 3             # Set to 3 (v1 context) — takes effect next loop
pc concurrency set 1             # Set to 1 (careful with context!)
# Direct file method (works even without pc CLI):
echo 3 > /tmp/pc-autopilot/.control/v1.concurrency
echo 1 > /tmp/pc-autopilot/.control/tech.concurrency
```

## Pause / Resume

```bash
pc pause                 # Pause current context pipeline
pc resume                # Resume it
# Direct file method:
echo true > /tmp/pc-autopilot/.control/v1.paused
echo false > /tmp/pc-autopilot/.control/v1.paused
```

## Retry Failed Builds

```bash
pc retry 221             # Mark single app for retry (sets status to pending_retry)
pc retry --all-failed    # Mark ALL failed apps in current context for retry
# Note: On pipeline restart, failed apps are automatically retried since
# is_deployed() only skips status=="deployed". No manual retry needed
# if you restart the pipeline.
```

## Kubernetes (CRDs)

```bash
kubectl get pb -n paperclip-v3                    # All builds
kubectl get pb -n paperclip-v3 -l pipeline=v1     # v1 only (84 builds)
kubectl get pb -n paperclip-v3 -l pipeline=tech   # tech only (13+ builds)
kubectl get pb -n paperclip-v3 -o wide            # Includes deploy URLs
kubectl get pb -n paperclip-v3 --sort-by=.metadata.creationTimestamp
# Watch live:
kubectl get pb -n paperclip-v3 --watch
# Single build detail:
kubectl get pb pb-221-lpe -n paperclip-v3 -o yaml
# Filter by phase:
kubectl get pb -n paperclip-v3 -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' | grep Failed
```

## tmux Sessions

```bash
tmux attach -t autopilot         # Watch v1 pipeline live (Ctrl-B D to detach)
tmux attach -t tech-autopilot    # Watch tech pipeline live
tmux list-sessions               # List all sessions
# Tail logs without attaching:
tail -f /tmp/pc-autopilot/logs/full-run-*.log   # v1 latest
tail -f /tmp/pc-autopilot/logs/tech-run-*.log   # tech latest
```

## Pipeline Restart (after patches or crashes)

```bash
# 1. Stop current pipeline (Ctrl-C in tmux, or):
tmux send-keys -t autopilot C-c
tmux send-keys -t tech-autopilot C-c

# 2. Clear stale PID files
rm -f /tmp/pc-autopilot/.pid-v1 /tmp/pc-autopilot/.pid-tech

# 3. Relaunch v1
tmux send-keys -t autopilot "/tmp/pc-autopilot/scripts/autopilot-build.sh \
  --manifest /tmp/pc-autopilot/manifests/use-cases-201-400.json \
  --all --concurrency 2 --pipeline-id v1 \
  2>&1 | tee /tmp/pc-autopilot/logs/full-run-\$(date +%Y%m%d-%H%M%S).log" Enter

# 4. Relaunch tech
tmux send-keys -t tech-autopilot "/tmp/pc-autopilot/scripts/autopilot-build.sh \
  --manifest /tmp/pc-autopilot/manifests/use-cases-401-600.json \
  --all --concurrency 1 --pipeline-id tech --skip-onboard \
  2>&1 | tee /tmp/pc-autopilot/logs/tech-run-\$(date +%Y%m%d-%H%M%S).log" Enter
```

## Redis

```bash
# Check Redis status
kubectl get pods -n paperclip-v3 -l app.kubernetes.io/name=redis
# Ping
REDIS_PASS=$(kubectl get secret redis-credentials -n paperclip-v3 -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- redis-cli -a "$REDIS_PASS" ping
# Memory
kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- redis-cli -a "$REDIS_PASS" info memory | grep used_memory_human
```

## Quick Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| Pipeline stuck | `pc status` shows 0 building | Check tmux, restart pipeline |
| Build hangs >15min | `timeout 900` should auto-kill | Verify with `ps aux \| grep claude` |
| Double pipeline | PID guard blocks it | `rm /tmp/pc-autopilot/.pid-*` then restart |
| CRDs not updating | `kubectl get pb -n paperclip-v3` | CRDs are fire-and-forget, check kubectl access |
| Redis down | `pc doctor` shows [✗] | `kubectl get pods -n paperclip-v3`, check PVC |
| Disk full | `df -h /tmp` | Clean `/tmp` stale dirs, or pause pipeline |
| App built but marked failed | Post-crash recovery checks out/index.html | Should auto-recover now with patched script |

## File Locations

```
/tmp/pc-autopilot/
├── .control/                  # Concurrency + pause control files
│   ├── v1.concurrency         # Current: 2
│   ├── v1.paused              # Current: false
│   ├── tech.concurrency       # Current: 1
│   └── tech.paused            # Current: false
├── .pid-v1                    # PID guard for v1 pipeline
├── .pid-tech                  # PID guard for tech pipeline
├── .pipeline-status           # JSON status for monitoring
├── registry/deployed.json     # App registry (flock-protected)
├── logs/                      # Build logs per app
├── manifests/                 # App manifest JSONs
└── scripts/
    ├── autopilot-build.sh     # Main pipeline script (patched)
    ├── generate-prompt.sh     # Category-aware prompt generator
    ├── deploy-cf.sh           # Cloudflare Pages deployer
    ├── launch-autopilot.sh    # tmux launcher (v1)
    └── launch-tech-pipeline.sh # tmux launcher (tech)

/var/lib/rancher/ansible/db/pc-ng/   # GitHub: devopseng99/pc-ng
├── cli/pc                     # CLI script (symlinked to /usr/local/bin/pc)
├── contexts/{v1,tech}.env     # Tenant configs
├── manifests/                 # CRD, RBAC, namespace YAML
├── redis/                     # Redis Helm overrides, PV, scripts
└── scripts/                   # install.sh, backfill-crds.sh, uninstall.sh

~/.pc/
├── context                    # Current context name (v1/tech/all)
└── contexts/{v1,tech}.env     # Active context configs
```
