---
name: pc-start
description: Start pipeline workers and optionally supervisor. Clears halt file and circuit breaker. Arguments control concurrency and what to start.
allowed-tools: Bash
user-invocable: true
argument-hint: [--concurrency N] [--with-supervisor] [--with-deploy]
---

# PC-NG Pipeline Start

Resume pipeline operations. Clears emergency halt, resets circuit breaker, starts workers.

## Arguments

- `$ARGUMENTS` — Options like `--concurrency 2`, `--with-supervisor`, `--with-deploy`
- Default: concurrency 2, no supervisor, no auto-deploy

## Steps

1. Clear halt state and circuit breaker:
```bash
rm -f /tmp/pc-autopilot/.emergency-halt
echo "closed" > /tmp/pc-autopilot/.circuit-breaker-state
> /tmp/pc-autopilot/.circuit-breaker-results
```

2. Parse arguments from `$ARGUMENTS`:
   - Extract `--concurrency N` (default: 2)
   - Check for `--with-supervisor` flag
   - Check for `--with-deploy` flag

3. Start workers:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/workers-start.sh --concurrency <N>
```

4. If `--with-supervisor` requested, start supervisor:
```bash
nohup bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/pipeline-supervisor.sh \
  --auto-workers --interval 30 \
  > /tmp/pc-autopilot/.workers/supervisor-console.log 2>&1 &
echo "$!" > /tmp/pc-autopilot/.workers/supervisor.pid
```
Add `--auto-deploy` flag to supervisor if `--with-deploy` was also requested.

5. Verify with status check:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/emergency-halt.sh --status
```

Report: what was started, concurrency level, and current CRD counts.
