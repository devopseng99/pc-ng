---
name: pc-new-pipeline
description: Create a new pipeline end-to-end — generate app ideas, manifest JSON, CRDs, register in workers, and optionally start building. Use when user says "create a new pipeline", "add N apps for X", or "new use-case pipeline".
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
user-invocable: true
---

# Create New Pipeline

Full pipeline creation flow: idea generation → definition file → `new-pipeline.sh` (plan or auto-apply).

## Arguments

The user provides a description of what kind of apps to create. Parse out:
- **Theme/category** — e.g. "fintech payments", "health & fitness", "real estate"
- **Count** — number of apps (default 20)
- **Target instance** — which PC instance (default pc-v4)
- **Action** — "plan" (default) or "auto-apply" (if user says "kick it off", "start building", etc.)

## Steps

### Step 1: Get next available ID range

```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/generate-manifest.sh --next-id
```

### Step 2: Check existing pipelines

```bash
kubectl get pb -n paperclip-v3 -o json | python3 -c "
import json,sys
pipelines = set(i['spec']['pipeline'] for i in json.load(sys.stdin)['items'])
print('Existing pipelines:', ', '.join(sorted(pipelines)))
"
```

### Step 3: Generate app ideas

Based on the user's description, generate N diverse app concepts. Write a `.def` file.

Each app block is separated by a blank line:
```
name: PulseTrack Fitness
prefix: PTF
type: Gym Workout Tracker
category: Health & Fitness
description: AI-powered workout tracker with rep counting...
features: AI rep counter, progressive overload, workout templates, Apple Health sync, rest timer, PR tracking
design_bg: #0F172A
design_primary: #10B981
design_vibe: Dark athletic minimal
budget: 600
```

Guidelines for quality:
- Names should sound like REAL startups (not generic)
- Descriptions should mention specific technologies (Stripe, Twilio, etc.)
- Features should be concrete (not "user management" but "RBAC with team invites")
- Spread across 3-4 sub-categories within the theme
- Each app should feel distinct
- Prefixes must be 3 uppercase letters, unique across ALL existing pipelines
- If prefix omitted, auto-generated from name initials
- If repo omitted, auto-derived from name (lowercase-hyphenated)
- If email omitted, auto-derived from repo

Save to: `/var/lib/rancher/ansible/db/pc-ng/pipeline/defs/{pipeline_name}.def`

### Step 4: Run new-pipeline.sh

**For plan (default):**
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/new-pipeline.sh \
  --from-def pipeline/defs/{pipeline}.def \
  --pipeline {pipeline} \
  --category "{Category}" \
  --concurrency 1 \
  --action plan
```

**For auto-apply (when user says start/kick off/apply):**
```bash
bash /var/lib/rancher/ansible/db/pc-ng/pipeline/scripts/new-pipeline.sh \
  --from-def pipeline/defs/{pipeline}.def \
  --pipeline {pipeline} \
  --category "{Category}" \
  --concurrency 1 \
  --action auto-apply
```

The script handles everything:
1. Generates manifest JSON from .def file
2. Registers pipeline in ConfigMap registry (all scripts auto-resolve from there)
3. Validates pipeline name against CRD pattern regex
4. Creates workspace symlink
5. Generates CRDs (idempotent)
6. Starts workers (auto-apply only)

### Step 5: Show result

After plan: show the auto-apply command the user can run.
After auto-apply: show monitoring commands.

## Important

- ALWAYS run plan first if the user hasn't explicitly said to auto-apply
- ALWAYS check `--next-id` first to avoid ID collisions
- ALWAYS verify prefix uniqueness against existing CRDs
- The script registers new pipelines in the `pipeline-registry` ConfigMap — all scripts auto-resolve from there
- CRD uses pattern regex (`^[a-z][a-z0-9-]{0,29}$`), not a hardcoded enum — no CRD YAML edits needed
- Workers have built-in dedup: check company by NAME, store companyId in CRD status, skip Deployed/Deploying
- Do NOT start workers unless the user explicitly asks (use plan mode by default)
