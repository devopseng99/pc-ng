---
name: pc-start
description: Start pipeline workers and optionally supervisor. Clears halt file and circuit breaker. Arguments control concurrency, pipeline, and what to start.
allowed-tools: Bash
user-invocable: true
argument-hint: [--pipeline NAME] [--concurrency N] [--with-supervisor] [--with-deploy]
---

# PC-NG Pipeline Start

Resume pipeline operations. Clears emergency halt, resets circuit breaker, starts workers.

## Arguments

- `$ARGUMENTS` — Options like `--pipeline tech`, `--concurrency 2`, `--with-supervisor`, `--with-deploy`
- `--pipeline` — Which pipeline to start: v1, tech, wasm, soa (default: starts both v1 + tech)
- `--concurrency N` — Max concurrent builds (default: 2, max recommended: 2 per pipeline)
- Default: concurrency 2, no supervisor, no auto-deploy

## Pipelines & Manifests
| Pipeline | Manifest | Category |
|---|---|---|
| v1 | use-cases-201-400.json | Original apps |
| tech | use-cases-401-600.json | Tech apps |
| wasm | wasm-sandbox-apps.json | WASM & Sandbox Runtimes |
| soa | pc-soa-v3-templates.json | Next-Gen UI Platform |

## Steps

1. Clear halt state and circuit breaker:
```bash
rm -f /tmp/pc-autopilot/.emergency-halt
echo "closed" > /tmp/pc-autopilot/.circuit-breaker-state
> /tmp/pc-autopilot/.circuit-breaker-results
```

2. Parse arguments from `$ARGUMENTS`:
   - Extract `--pipeline NAME` (if provided)
   - Extract `--concurrency N` (default: 2)
   - Check for `--with-supervisor` flag
   - Check for `--with-deploy` flag

3. Start workers:
```bash
# If --pipeline specified, start only that pipeline:
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/workers-start.sh --pipeline <NAME> --concurrency <N>

# If no --pipeline, start default (v1 + tech):
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
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/workers-status.sh 2>/dev/null
```

Report: what was started, pipeline name, concurrency level, and current CRD counts.
