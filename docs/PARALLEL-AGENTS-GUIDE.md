# Parallel Agent Orchestration — Patterns & Guide

> How we built 14 features in ~13 minutes using 6 autonomous agents working simultaneously.

## Table of Contents

1. [Why Parallel Agents](#why-parallel-agents)
2. [Core Mechanics](#core-mechanics)
3. [7 Orchestration Patterns](#7-orchestration-patterns)
4. [Building an Orcha-Master Module](#building-an-orcha-master-module)
5. [Real-World Example: ADLC v2.0.0](#real-world-example-adlc-v200)
6. [Gotchas & Failure Modes](#gotchas--failure-modes)

---

## Why Parallel Agents

Serial execution of 14 features would take ~50 minutes of wall time and consume one long context window. Parallel execution:

| Metric | Serial | Parallel (6 agents) |
|--------|--------|---------------------|
| Wall time | ~50 min | ~13 min (longest agent) |
| Context pressure | 1 massive window | 6 small, focused windows |
| Conflict risk | Zero | Zero (if repo-partitioned) |
| Failure blast radius | Everything stops | 1 agent fails, 5 continue |

The key insight: **agents that work on non-overlapping files can run simultaneously with zero coordination overhead**.

---

## Core Mechanics

### The Agent Tool

Inside Claude Code, the `Agent` tool spawns subagents:

```
Agent({
  description: "Short label for the task",
  prompt: "Full self-contained brief — this agent has NO memory of your conversation",
  subagent_type: "general-purpose",  // or "Explore", "Plan"
  run_in_background: true,           // concurrent execution
  name: "my-agent",                  // addressable via SendMessage
  mode: "auto",                      // permission handling
  isolation: "worktree"              // optional: isolated git copy
})
```

### Subagent Types

| Type | Model | Can Write Files | Best For |
|------|-------|-----------------|----------|
| `Explore` | Haiku (fast) | No | Code search, file discovery, quick lookups |
| `general-purpose` | Inherits | Yes | Multi-step implementation tasks |
| `Plan` | Inherits | No | Architecture research during plan mode |

### Background Execution

When `run_in_background: true`:
- Agent runs concurrently — you keep working
- Permissions are pre-approved at launch
- You get a notification when it completes
- The result (summary) is injected back into your conversation

### Isolation Modes

| Mode | Files | Git | Use When |
|------|-------|-----|----------|
| None (default) | Shared | Shared | Agents touch different files |
| `worktree` | Isolated copy | Separate branch | Multiple agents edit same files |

---

## 7 Orchestration Patterns

### Pattern 1: Survey → Dispatch (what we used for ADLC v2.0.0)

**Shape:** One research agent gathers context, then N implementation agents execute in parallel.

```
┌─────────────────────┐
│  Survey Agent        │  (foreground — blocks until done)
│  Explore type        │
│  Reads all repos     │
│  Reports structure   │
└──────────┬──────────┘
           │  context gathered
           ▼
┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
│Agent1│ │Agent2│ │Agent3│ │Agent4│ │Agent5│  (all background)
│Repo A│ │Repo B│ │Repo C│ │Repo D│ │Repo E│
└──────┘ └──────┘ └──────┘ └──────┘ └──────┘
```

**When to use:** Large feature batches where implementation is independent but you need shared understanding of the codebase first.

**Key rule:** The survey agent runs in the **foreground** (you need its results before dispatching). The implementation agents run in the **background** (they're independent of each other).

```
// Step 1: Survey (foreground)
Agent({
  description: "Codebase survey",
  subagent_type: "Explore",
  prompt: "Read all repos and report structure, entry points, schemas..."
})

// Step 2: Dispatch (all background, in ONE message with multiple Agent calls)
Agent({
  description: "Build feature A",
  prompt: "...full brief with file paths from survey...",
  run_in_background: true,
  name: "feature-a"
})
Agent({
  description: "Build feature B",
  prompt: "...full brief...",
  run_in_background: true,
  name: "feature-b"
})
```

**Critical:** Send all background agents in a **single message** with multiple tool calls. This is what triggers true parallel execution. Sequential messages = sequential execution.

---

### Pattern 2: Repo-Partitioned Workers

**Shape:** Each agent owns one repo exclusively. No file conflicts possible.

```
┌─────────────────────────────────────────────┐
│              Orchestrator (you)              │
├──────────┬──────────┬──────────┬────────────┤
│ Agent 1  │ Agent 2  │ Agent 3  │ Agent 4    │
│ repo-a/  │ repo-b/  │ repo-c/  │ repo-d/    │
│ commit+  │ commit+  │ commit+  │ commit+    │
│ push     │ push     │ push     │ push       │
└──────────┴──────────┴──────────┴────────────┘
```

**When to use:** Multi-repo projects (microservices, monorepo with independent packages).

**Rule of thumb:** If two agents might touch the same file, DON'T put them in the same partition. Either merge them into one agent or use worktree isolation.

**Example from ADLC v2.0.0:**
- Agent 1: sdk-agent-intake (openfeature, replay)
- Agent 2: sdk-agent-intake (templates) + agent-intake-controller (GC) ← safe because different files
- Agent 3: pc-ng (HUD, cost scripts)
- Agent 4: pc-ng (self-heal, webhooks) ← different scripts than Agent 3
- Agent 5: builder (tests, cluster) + controller (CRD)
- Agent 6: pc-showroom + claude-skills

---

### Pattern 3: Competing Hypotheses

**Shape:** N agents investigate the same problem from different angles. Best theory wins.

```
┌───────────────────────────────┐
│    Problem: App crashes        │
├─────────┬─────────┬───────────┤
│ Agent 1 │ Agent 2 │ Agent 3   │
│ "Memory │ "Race   │ "Timeout  │
│  leak"  │ cond."  │ in auth"  │
├─────────┼─────────┼───────────┤
│ Evidence│ Evidence│ Evidence  │
└────┬────┴────┬────┴─────┬─────┘
     └─────────┼──────────┘
               ▼
     Orchestrator picks winner
```

**When to use:** Debugging complex issues where the root cause is unclear. Each agent starts with a different hypothesis and collects evidence. The one with the strongest evidence wins.

```
// All in one message
Agent({
  description: "Investigate memory leak theory",
  subagent_type: "Explore",
  prompt: "The app crashes after 1000 requests. Theory: memory leak in connection pool.
           Search for: unclosed connections, growing buffers, missing cleanup in finally blocks.
           Report evidence for AND against this theory.",
  run_in_background: true
})
Agent({
  description: "Investigate race condition theory",
  subagent_type: "Explore",
  prompt: "The app crashes after 1000 requests. Theory: race condition in session store.
           Search for: shared mutable state, missing locks, concurrent map access.
           Report evidence for AND against this theory.",
  run_in_background: true
})
```

---

### Pattern 4: Pipeline (Sequential Handoff)

**Shape:** Agent A's output feeds Agent B's input. Like a Unix pipe.

```
Agent A          Agent B          Agent C
(Research)  →   (Implement)  →   (Test)
  Explore        general          general
  Read-only      Writes code      Runs tests
```

**When to use:** Tasks with strict dependencies where each stage needs the previous stage's output.

**Implementation:** Run Agent A in the foreground. Read its result. Use that to construct Agent B's prompt. Run Agent B in the foreground. Repeat.

```
// Stage 1: Research (foreground)
result_a = Agent({
  description: "Find all API endpoints",
  subagent_type: "Explore",
  prompt: "List every HTTP endpoint in src/api/ with method, path, handler function..."
})

// Stage 2: Implement (foreground, uses result_a in prompt)
result_b = Agent({
  description: "Generate OpenAPI spec",
  prompt: f"Given these endpoints: {result_a}\n\nGenerate an OpenAPI 3.0 spec file..."
})

// Stage 3: Validate (foreground)
Agent({
  description: "Validate OpenAPI spec",
  prompt: f"Run openapi-spec-validator against the generated spec..."
})
```

---

### Pattern 5: Map-Reduce

**Shape:** Split a large task into N identical subtasks, run in parallel, merge results.

```
        ┌── Agent: files 1-100
Input ──┼── Agent: files 101-200  ──→ Merge
        └── Agent: files 201-300
```

**When to use:** Bulk analysis (audit 300 files, validate 50 configs, test 20 endpoints).

```
// Split
file_groups = chunk(all_files, 100)

// Map (all in one message)
for i, group in enumerate(file_groups):
    Agent({
      description: f"Audit files batch {i+1}",
      prompt: f"Check these files for security issues:\n{group}\nReport: file, line, issue, severity",
      run_in_background: true,
      name: f"auditor-{i+1}"
    })

// Reduce (after all complete)
// Merge results from all agents into unified report
```

---

### Pattern 6: Worktree Branches (Parallel PRs)

**Shape:** Each agent works in an isolated git worktree, producing a separate branch.

```
main ─────────────────────────
  ├── worktree-1/  (Agent A: feature-auth)
  ├── worktree-2/  (Agent B: feature-cache)
  └── worktree-3/  (Agent C: refactor-db)
```

**When to use:** Multiple agents need to edit the SAME files (e.g., refactoring `main.py` in different ways).

```
Agent({
  description: "Add auth middleware",
  isolation: "worktree",
  prompt: "Add JWT auth middleware to main.py...",
  run_in_background: true
})
Agent({
  description: "Add caching layer",
  isolation: "worktree",
  prompt: "Add Redis caching to main.py...",
  run_in_background: true
})
```

Each agent gets its own git branch. After both complete, you review and merge (or cherry-pick) the changes.

---

### Pattern 7: Orcha-Master (Persistent Orchestrator)

**Shape:** A long-lived orchestrator agent that manages a queue of work, spawning and monitoring worker agents.

```
┌──────────────────────────────────────────┐
│         Orcha-Master (persistent)        │
│  - Reads work queue (YAML/JSON/CRD)     │
│  - Classifies tasks                     │
│  - Dispatches to specialized agents     │
│  - Tracks completion + costs            │
│  - Retries failures                     │
│  - Reports results                      │
├──────────────┬───────────────────────────┤
│ Worker Pool  │  Capacity: N concurrent   │
│  ┌────┐      │                           │
│  │ W1 │ busy │  Task: build feature X    │
│  ├────┤      │                           │
│  │ W2 │ busy │  Task: fix bug Y          │
│  ├────┤      │                           │
│  │ W3 │ idle │  (waiting for work)       │
│  └────┘      │                           │
└──────────────┴───────────────────────────┘
```

**This is the pattern to build as a standalone project.** See next section.

---

## Building an Orcha-Master Module

### Architecture

```
orcha-master/
├── orcha.py              # Main orchestrator CLI
├── queue.py              # Work queue (YAML/JSON files or K8s CRDs)
├── classifier.py         # Route tasks to the right agent type
├── dispatcher.py         # Spawn agents with correct prompts
├── tracker.py            # Track completion, costs, retries
├── reporter.py           # Generate status reports
├── agents/               # Agent definitions
│   ├── builder.md        # Code generation agent
│   ├── reviewer.md       # Code review agent
│   ├── deployer.md       # K8s deployment agent
│   ├── tester.md         # Test execution agent
│   └── researcher.md     # Codebase analysis agent
├── templates/            # Prompt templates per task type
│   ├── build-feature.md
│   ├── fix-bug.md
│   ├── review-pr.md
│   └── deploy-service.md
├── config.yaml           # Concurrency, budgets, retry policy
└── tests/
    └── test_dispatcher.py
```

### Core Loop (orcha.py)

```python
"""
Orcha-Master: Persistent orchestrator for parallel Claude Code agents.

Usage:
  python orcha.py run queue.yaml          # Process a work queue
  python orcha.py run queue.yaml --max-concurrent 4
  python orcha.py run queue.yaml --budget 50.00
  python orcha.py status                  # Show active/completed/failed
  python orcha.py retry --failed          # Retry all failed tasks
  python orcha.py report --format table   # Summary report
"""

import yaml
import asyncio
from dataclasses import dataclass
from pathlib import Path

@dataclass
class Task:
    id: str
    type: str           # "build-feature", "fix-bug", "review-pr", "deploy"
    target: str         # repo path or file path
    description: str    # what to do
    priority: int       # 1-10
    budget_usd: float   # max cost for this task
    status: str = "pending"  # pending, running, completed, failed, retrying
    agent_id: str = ""
    cost_usd: float = 0.0
    retries: int = 0

class OrchaManager:
    def __init__(self, config_path: str = "config.yaml"):
        self.config = yaml.safe_load(Path(config_path).read_text())
        self.max_concurrent = self.config.get("max_concurrent", 4)
        self.max_retries = self.config.get("max_retries", 2)
        self.budget_usd = self.config.get("budget_usd", 100.0)
        self.tasks: list[Task] = []
        self.running: dict[str, Task] = {}

    def load_queue(self, queue_path: str):
        """Load tasks from YAML queue file."""
        raw = yaml.safe_load(Path(queue_path).read_text())
        for item in raw.get("tasks", []):
            self.tasks.append(Task(**item))
        self.tasks.sort(key=lambda t: t.priority, reverse=True)

    def classify(self, task: Task) -> dict:
        """Route task to correct agent type and prompt template."""
        routing = {
            "build-feature": {
                "agent": "agents/builder.md",
                "template": "templates/build-feature.md",
                "subagent_type": "general-purpose",
            },
            "fix-bug": {
                "agent": "agents/builder.md",
                "template": "templates/fix-bug.md",
                "subagent_type": "general-purpose",
            },
            "review-pr": {
                "agent": "agents/reviewer.md",
                "template": "templates/review-pr.md",
                "subagent_type": "Explore",
            },
            "deploy": {
                "agent": "agents/deployer.md",
                "template": "templates/deploy-service.md",
                "subagent_type": "general-purpose",
            },
        }
        return routing.get(task.type, routing["build-feature"])

    def build_prompt(self, task: Task, route: dict) -> str:
        """Construct full agent prompt from template + task details."""
        template = Path(route["template"]).read_text()
        return template.format(
            task_id=task.id,
            target=task.target,
            description=task.description,
            budget=task.budget_usd,
        )

    async def dispatch(self, task: Task):
        """Spawn an agent for a task."""
        route = self.classify(task)
        prompt = self.build_prompt(task, route)
        task.status = "running"
        self.running[task.id] = task

        # In Claude Code context, this would be:
        # Agent({
        #   description: f"{task.type}: {task.id}",
        #   subagent_type: route["subagent_type"],
        #   prompt: prompt,
        #   run_in_background: True,
        #   name: task.id
        # })

    async def run(self):
        """Main orchestration loop."""
        pending = [t for t in self.tasks if t.status == "pending"]

        while pending or self.running:
            # Fill worker slots
            while pending and len(self.running) < self.max_concurrent:
                task = pending.pop(0)
                if self.budget_remaining() < task.budget_usd:
                    task.status = "skipped"
                    continue
                await self.dispatch(task)

            # Wait for completions (in Claude Code, this is automatic via notifications)
            await self.wait_for_completion()

            # Handle retries
            for task_id, task in list(self.running.items()):
                if task.status == "failed" and task.retries < self.max_retries:
                    task.retries += 1
                    task.status = "retrying"
                    await self.dispatch(task)

            pending = [t for t in self.tasks if t.status == "pending"]

    def budget_remaining(self) -> float:
        spent = sum(t.cost_usd for t in self.tasks)
        return self.budget_usd - spent
```

### Work Queue Format (queue.yaml)

```yaml
tasks:
  - id: "feat-openfeature"
    type: "build-feature"
    target: "/var/lib/rancher/ansible/db/sdk-agent-intake"
    description: "Add OpenFeature flag evaluator with YAML-based targeting rules"
    priority: 8
    budget_usd: 5.00

  - id: "feat-self-heal"
    type: "build-feature"
    target: "/var/lib/rancher/ansible/db/pc-ng"
    description: "Build self-healing pipeline daemon that classifies and fixes Failed CRDs"
    priority: 9
    budget_usd: 5.00

  - id: "review-auth"
    type: "review-pr"
    target: "devopseng99/ai-hedge-fund#12"
    description: "Security review of authentication endpoints"
    priority: 7
    budget_usd: 2.00

  - id: "deploy-showroom"
    type: "deploy"
    target: "/var/lib/rancher/ansible/db/pc-showroom"
    description: "Build and deploy showroom v1.1.0 with portfolio API"
    priority: 6
    budget_usd: 3.00
```

### Config (config.yaml)

```yaml
max_concurrent: 4
max_retries: 2
budget_usd: 100.00
retry_delay_seconds: 30

routing:
  build-feature:
    subagent_type: general-purpose
    mode: auto
    timeout_minutes: 30
  fix-bug:
    subagent_type: general-purpose
    mode: auto
    timeout_minutes: 15
  review-pr:
    subagent_type: Explore
    mode: plan
    timeout_minutes: 10
  deploy:
    subagent_type: general-purpose
    mode: auto
    timeout_minutes: 20

safety:
  emergency_halt_file: /tmp/orcha/.emergency-halt
  circuit_breaker_threshold: 3   # consecutive failures before pause
  cooldown_seconds: 300          # pause after breaker trips
```

### Prompt Template (templates/build-feature.md)

```markdown
# Task: {task_id}

## Objective
{description}

## Target Repository
{target}

## Budget
Maximum spend: ${budget}

## Instructions
1. Read the existing codebase to understand structure and patterns
2. Implement the feature following existing code style
3. Write tests if the repo has a test directory
4. Commit with a descriptive message: "feat: {description}"
5. Do NOT push — the orchestrator handles that

## Constraints
- Do not modify files outside the target repository
- Do not install new dependencies without justification
- Do not break existing functionality
- If you hit a blocker, commit what you have and report the blocker
```

---

## Real-World Example: ADLC v2.0.0

This is exactly how we built 14 features in one session:

### Step 1: Survey (foreground, ~2 min)

```
Agent({
  description: "Codebase survey",
  subagent_type: "Explore",
  prompt: "Read all 6 repos: sdk-agent-intake, builder, controller, showroom, pc-ng, claude-skills.
           Report: entry points, CLI flags, config schemas, integration points.
           I need this to brief 6 implementation agents."
})
```

**Output:** Detailed map of every repo's structure, 200+ lines of context.

### Step 2: Dispatch 6 agents (all background, ~13 min)

All dispatched in a **single message** with 6 `Agent()` calls:

| Agent | Repos | Features | Lines |
|-------|-------|----------|-------|
| openfeature-replay | intake, builder | OpenFeature flags, agent replay | ~800 |
| templates-gc | intake, controller | 10 templates, CRD garbage collection | ~900 |
| hud-costs | pc-ng | intake-hud.sh, cost-report.sh | ~600 |
| selfheal-webhooks | pc-ng | self-heal daemon, webhook server | ~700 |
| multicluster-tests | intake, builder, controller | cluster.py, 112 tests | ~1800 |
| showroom-audit-registry | showroom, intake, skills | portfolio, audit log, multi-tenant | ~800 |

### Step 3: Verify + Release (~3 min)

After all 6 completed:
- `git log` in each repo to verify commits
- `git status` to check for stray changes
- Tag and push all repos
- Create group release

### Total: ~18 minutes for 14 features, ~5,640 lines, 6 repos.

---

## Gotchas & Failure Modes

### 1. The Overlapping Files Trap

**Problem:** Two agents edit the same file → last writer wins, first writer's changes are lost.

**Solution:** Partition by file, not by feature. If Feature A and Feature B both need to modify `main.py`, put them in the same agent.

### 2. The Stale Context Trap

**Problem:** Agent prompt references a file path that doesn't exist, or a function that was renamed.

**Solution:** Always run a survey agent first to get current file paths and function names. Never assume paths from memory.

### 3. The Implicit Dependency Trap

**Problem:** Agent B depends on Agent A's output (e.g., Agent B imports a module Agent A is creating), but both run in parallel.

**Solution:** Either merge into one sequential agent, or have Agent B create its own stub/interface and wire up after both complete.

### 4. The Over-Dispatch Trap

**Problem:** 10 agents running means 10x token cost. Most sessions have a budget.

**Solution:** 4-6 parallel agents is the sweet spot. Beyond that, diminishing returns and increased coordination overhead.

### 5. The Vague Prompt Trap

**Problem:** Agent receives "implement the feature" with no file paths, schema examples, or integration points. It guesses wrong.

**Solution:** Every agent prompt must be fully self-contained. Include:
- Exact file paths to read and modify
- Schema/format examples
- Integration points with other systems
- Commit message to use
- What NOT to do

### 6. The Missing Verification Trap

**Problem:** Agent reports "done" but actually introduced a bug, left a syntax error, or forgot a file.

**Solution:** Always verify after completion:
- `git log` — did the commit land?
- `git diff` — are the changes what you expected?
- Run tests if they exist
- Read key files to confirm structure

### 7. The Context Window Trap

**Problem:** Your main conversation grows enormous tracking 6+ agent results, and compaction kicks in.

**Solution:** Keep agent result summaries brief. Don't dump full file contents into the main context. If you need details, spawn another Explore agent to read specific files.
