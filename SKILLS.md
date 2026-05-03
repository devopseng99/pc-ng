# Skill Management — pc-ng

Skills are pulled from the **versioned skill registry** at `devopseng99/claude-skills`.
Local copies live in `.claude/skills/` but are **not committed** — they're synced on demand.

## Quick Reference

| Action | Command |
|--------|---------|
| Sync skills to manifest versions | `~/claude-skills/skill-sync.sh` |
| Preview what would change | `~/claude-skills/skill-sync.sh --diff` |
| Update all to latest registry tag | `~/claude-skills/skill-sync.sh --update` |
| Update one skill only | `~/claude-skills/skill-sync.sh --update pc-provision` |
| List available vs installed | `~/claude-skills/skill-sync.sh --list` |
| Pin all to a specific version | `~/claude-skills/skill-sync.sh --version v1.2.0` |

## Files

| File | Purpose | Committed? |
|------|---------|------------|
| `.claude/skill-manifest.yaml` | Declares which skills + versions this project uses | Yes |
| `.claude/skill-lock.yaml` | Records exact commit + SHA256 per synced skill | Yes |
| `.claude/skills/.gitignore` | Prevents synced skill dirs from being committed | Yes |
| `.claude/skills/*/SKILL.md` | The actual skill files (synced from registry) | **No** |

## How It Works

```
devopseng99/claude-skills (GitHub)     pc-ng repo
┌──────────────────────────┐          ┌──────────────────────────┐
│ skills/pc-build/SKILL.md │──sync──→ │ .claude/skills/pc-build/ │
│ skills/pc-status/SKILL.md│          │ .claude/skills/pc-status/│
│ ...                      │          │ ...                      │
│ Tagged: v1.0.0, v1.2.0   │          │ skill-manifest.yaml      │
└──────────────────────────┘          │ skill-lock.yaml          │
                                      └──────────────────────────┘
```

1. `skill-manifest.yaml` declares skills + pinned version (e.g. `v1.2.0`)
2. `skill-sync.sh` clones the registry at that tag, copies skills into `.claude/skills/`
3. Lock file records the exact commit + integrity hash
4. `.gitignore` prevents skill files from being committed (only manifest + lock are tracked)

## Updating Skills

### Scenario: Registry has a new version (e.g. v1.3.0)

```bash
# 1. Preview changes
~/claude-skills/skill-sync.sh --diff

# 2. Update manifest version
# Edit .claude/skill-manifest.yaml: default_version: v1.3.0

# 3. Sync
~/claude-skills/skill-sync.sh

# 4. Commit the manifest + lock update
git add .claude/skill-manifest.yaml .claude/skill-lock.yaml
git commit -m "chore: bump skills to v1.3.0"
```

### Scenario: Quick update without editing manifest

```bash
# Pull latest tag for all skills (overrides manifest version)
~/claude-skills/skill-sync.sh --update

# Or just one skill
~/claude-skills/skill-sync.sh --update pc-provision
```

Note: `--update` syncs to the latest tag but does NOT update `skill-manifest.yaml`. To persist the version bump, edit the manifest afterward.

### Scenario: Pin one skill to a different version

```yaml
# .claude/skill-manifest.yaml
default_version: v1.2.0
skills:
  pc-provision:
    version: v1.3.0   # <-- override just this one
    vars:
      default_node: mgplcb05
  pc-status: {}        # uses default_version (v1.2.0)
```

## Editing Skills

**Never edit skills locally in `.claude/skills/`.** Changes will be overwritten on next sync.

### To modify a skill:

```bash
# 1. Edit in the registry
cd ~/claude-skills
vi skills/pc-provision/SKILL.md

# 2. Commit + tag
git add -A && git commit -m "feat: pc-provision — add X"
git tag v1.3.0
git push origin main --tags

# 3. Sync consumers
cd /var/lib/rancher/ansible/db/pc-ng
~/claude-skills/skill-sync.sh --update pc-provision

# 4. Repeat for other projects (pc-v8, etc.)
cd /var/lib/rancher/ansible/db/pc-v8
~/claude-skills/skill-sync.sh --update pc-provision
```

## Variable Overrides

Skills can have project-specific variables. These are substituted into SKILL.md during sync:

```yaml
# skill-manifest.yaml
skills:
  pc-provision:
    vars:
      default_node: mgplcb05      # {{default_node}} → mgplcb05
      default_email: hrsd0001@gmail.com
```

Variables use `{{VAR}}` or `${VAR}` syntax in SKILL.md.

## Adding a New Skill

```bash
# 1. Create in registry
cd ~/claude-skills
mkdir -p skills/my-new-skill
cat > skills/my-new-skill/SKILL.md << 'EOF'
---
name: my-new-skill
description: What it does
allowed-tools: Bash, Read
user-invocable: true
---
# My New Skill
...
EOF

cat > skills/my-new-skill/skill.yaml << 'EOF'
name: my-new-skill
version: "1.0"
category: infrastructure
description: What it does
EOF

# 2. Commit + tag
git add -A && git commit -m "feat: add my-new-skill"
git tag v1.3.0
git push origin main --tags

# 3. Add to consumer manifests
# Edit .claude/skill-manifest.yaml in each project:
#   my-new-skill: {}

# 4. Sync
~/claude-skills/skill-sync.sh
```

## Current State

**Registry:** `devopseng99/claude-skills` at v1.2.0
**This project:** 9 skills synced at v1.2.0

| Skill | Description |
|-------|-------------|
| `pc-build` | Phase B — build from GitHub, deploy to nginx |
| `pc-build-fix` | Fix failed builds with targeted Claude patches |
| `pc-deploy` | Alias for pc-build |
| `pc-halt` | Emergency stop all workers |
| `pc-new-pipeline` | Create pipeline end-to-end (ideas → CRDs) |
| `pc-provision` | Provision/teardown PC instances |
| `pc-reset` | Reset failed CRDs to Pending |
| `pc-start` | Start workers + supervisor |
| `pc-status` | Full pipeline status dashboard |

## Consumers

| Project | Path | Skills | Version |
|---------|------|--------|---------|
| pc-ng | `/var/lib/rancher/ansible/db/pc-ng` | 9 | v1.2.0 |
| pc-v8 | `/var/lib/rancher/ansible/db/pc-v8` | 7 | v1.0.0 |

## Troubleshooting

**Skills not showing in Claude session?**
- Run `~/claude-skills/skill-sync.sh` — skills must exist on disk
- Check `.claude/skills/*/SKILL.md` files exist

**Sync fails with "clone failed"?**
- Registry uses HTTPS, not SSH: `https://github.com/devopseng99/claude-skills.git`
- Verify GitHub access: `git ls-remote https://github.com/devopseng99/claude-skills.git`

**Lock file shows different version than manifest?**
- `--update` overrides manifest version temporarily
- Edit `skill-manifest.yaml` to persist the version, then re-sync

**Skill was edited locally and overwritten?**
- Local edits are always overwritten on sync. Edit in `~/claude-skills/` instead.
- If you need the local change preserved: copy it to the registry first, commit + tag, then sync.
