---
name: pc-halt
description: Emergency stop — kills all pipeline workers, supervisor, batch deploy, and Claude processes. Use when something is going wrong or user says stop/halt/kill.
allowed-tools: Bash
user-invocable: true
---

# PC-NG Emergency Halt

Stop ALL pipeline operations immediately.

## Action

Run the emergency halt script:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/emergency-halt.sh
```

Then verify everything is stopped:
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/emergency-halt.sh --status
```

Report what was stopped and current state.

**To resume after halt**, user must run `/pc-start`.
