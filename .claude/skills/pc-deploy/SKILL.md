---
name: pc-deploy
description: Run Phase B batch deploy — deploys apps with code on GitHub to K8s. Arguments can target specific app IDs or dry-run.
allowed-tools: Bash
user-invocable: true
argument-hint: [--dry-run] [--app-id N]
---

# PC-NG Batch Deploy (Phase B)

Deploy built apps to K8s via batch-deploy-k8s.sh.

## Arguments

- `$ARGUMENTS` — Passed directly to batch-deploy-k8s.sh (e.g., `--dry-run`, `--app-id 284`)

## Steps

1. Show current deploy queue size:
```bash
ls /tmp/pc-autopilot/.ready-to-deploy/*.json 2>/dev/null | wc -l
```

2. Run batch deploy:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/batch-deploy-k8s.sh $ARGUMENTS
```

3. Show updated CRD status after deploy completes:
```bash
kubectl get pb -n paperclip-v3 --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn
```

Report: how many deployed, how many failed, how many skipped.
