---
name: conductor
description: Orchestrate parallel agent sessions through a sprint. Coordinates task claiming, dependency resolution, and artifact handoff between independent agents. Triggers on /conductor, /sprint, /parallel.
concurrency: exclusive
depends_on: []
summary: "Multi-agent sprint orchestrator. Atomic file ops for phase claiming and dependency resolution."
estimated_tokens: 500
---

# /conductor — Multi-Agent Sprint Orchestrator

Coordinate multiple agent sessions working on the same project. Each agent claims a task, executes it, produces an artifact, and the next agent picks up where it left off.

**No daemon. No service. No IPC.** Just atomic file operations on `.nanostack/conductor/`.

## How it works

```
Agent A (claude)          Filesystem              Agent B (codex)
     │                        │                        │
     ├─ claim "plan" ────────►│                        │
     │                  [plan.lock = A]                 │
     │                        │◄──── claim "plan" ─────┤
     │                        │  REJECTED (locked)      │
     │                        │                        │
     ├─ complete "plan" ─────►│                        │
     │                  [plan.done + artifact]          │
     │                        │                        │
     │                        │◄──── claim "review" ───┤
     │                  [review.lock = B]               │
     │                        │  OK (plan.done exists)  │
```

## Sprint Definition

A sprint is a sequence of phases with dependencies:

```json
{
  "sprint_id": "abc123",
  "project": "/path/to/repo",
  "phases": [
    { "name": "think",    "depends_on": [] },
    { "name": "plan",     "depends_on": ["think"] },
    { "name": "build",    "depends_on": ["plan"] },
    { "name": "review",   "depends_on": ["build"] },
    { "name": "qa",       "depends_on": ["build"] },
    { "name": "security", "depends_on": ["build"] },
    { "name": "ship",     "depends_on": ["review", "qa", "security"] }
  ]
}
```

Note: `review`, `qa`, and `security` can run **in parallel** — they all depend on `build`, not on each other. `ship` waits for all three.

## Commands

### Start a sprint

```bash
conductor/bin/sprint.sh start [--phases "think,plan,build,review,qa,security,ship"]
```

Creates `.nanostack/conductor/<sprint_id>/` with the phase graph. Default is the full workflow.

### Claim a phase

```bash
conductor/bin/sprint.sh claim <phase> [--agent <name>]
```

Atomic claim using `mkdir` (POSIX atomic on same filesystem). Fails if:
- Phase is already claimed by another agent
- Dependencies are not complete
- Sprint doesn't exist

### Complete a phase

```bash
conductor/bin/sprint.sh complete <phase> [--artifact <path>]
```

Marks phase done. Links the artifact if provided. Unlocks downstream phases.

### Check status

```bash
conductor/bin/sprint.sh status
```

Outputs the current sprint state — which phases are pending, claimed, done, and by whom.

### Abort

```bash
conductor/bin/sprint.sh abort [phase]
```

Release a claim without completing. Use when an agent encounters a blocker.

### Batch (auto-parallelize)

```bash
conductor/bin/sprint.sh batch
```

Reads `concurrency` metadata from each skill's SKILL.md frontmatter and outputs execution batches. Consecutive `read` phases with met dependencies are grouped into parallel batches. `write` phases run one at a time. `exclusive` phases run alone.

**Concurrency classification:**

| Value | Meaning | Example |
|-------|---------|---------|
| `read` | Read-only, safe to parallelize | review, qa, security |
| `write` | Mutates files, run serial | compound |
| `exclusive` | Needs exclusive access (git ops) | ship, guard |

**Example output:**

```json
{"batch":1,"type":"read","phases":["think"]}
{"batch":2,"type":"read","phases":["plan"]}
{"batch":3,"type":"write","phases":["build"]}
{"batch":4,"type":"read","phases":["review","qa","security"]}
{"batch":5,"type":"exclusive","phases":["ship"]}
```

Batch 4 shows review, qa, and security running in parallel — they share `concurrency: read` and all depend only on `build`.

## Filesystem Protocol

```
.nanostack/conductor/
└── <sprint_id>/
    ├── sprint.json              # Sprint definition + metadata
    ├── think/
    │   ├── lock                 # Contains: {"agent":"claude","claimed_at":"...","pid":1234}
    │   ├── done                 # Exists = phase complete. Contains: {"completed_at":"...","artifact":"..."}
    │   └── artifact.json → ...  # Symlink to the actual artifact in .nanostack/think/
    ├── plan/
    │   ├── lock
    │   └── ...
    ├── review/                  # Can start once build/done exists
    ├── qa/                      # Can start once build/done exists (parallel with review)
    ├── security/                # Can start once build/done exists (parallel with review)
    └── ship/                    # Can start once review/done AND qa/done AND security/done exist
```

### Atomicity

- **Claim:** `mkdir <phase>/lock.d` (atomic on POSIX). If it succeeds, you own it. Write agent metadata, then `mv lock.d lock`.
- **Complete:** Write `done` file, remove `lock`.
- **Abort:** Remove `lock` directory.
- **No polling:** Agents check status only when they need to claim. No background loops.

## Security

- **Agent isolation:** Each agent only writes to phases it has claimed. It reads (never writes) other phases' artifacts.
- **Audit trail:** Every claim and completion is timestamped with agent identity and PID.
- **Stale lock detection:** If a lock is older than 1 hour and the PID is dead, it's considered stale and can be reclaimed.
- **No credential sharing:** Agents use their own credentials. The conductor never touches secrets.
- **Artifact integrity:** Completed phases are read-only. An agent cannot modify another agent's artifact after completion.

## Usage Patterns

### Single developer, sequential (most common)

One agent, one sprint. Same as today — the conductor just adds visibility:

```
You:  /conductor start
You:  /think → /nano → build → /review → /qa → /security → /ship
      [each phase auto-claims and auto-completes]
```

### Single developer, parallel review

One build, then fan out review + qa + security in parallel:

```
Terminal 1:  /conductor start
Terminal 1:  /think → /nano → build
Terminal 1:  /review

Terminal 2:  /qa              # claims qa (build.done exists)

Terminal 3:  /security        # claims security (build.done exists)

Terminal 1:  /ship            # waits until review + qa + security all done
```

### Team, distributed

Multiple developers, each running their own agent:

```
Dev A (claude):   /think → /nano
Dev B (codex):    build (claims after plan.done)
Dev A (claude):   /review (claims after build.done)
Dev C (opencode):     /security (claims after build.done, parallel with review)
Dev A (claude):   /ship (claims after review.done + security.done)
```

## Phase Protocol

Every phase transition follows this protocol. The agent executes these steps at every boundary — they are mandatory, not optional.

### Pre-phase (before starting a new phase)

1. Check for existing session: `bin/session.sh resume`
   - If resumable and user confirms, restore context via `bin/restore-context.sh`
   - If no session exists, create one: `bin/session.sh init <type>`
2. Validate upstream dependencies: `bin/validate-dependencies.sh <phase>`
   - If MISSING, stop and report which dependencies are not met
3. Update session: `bin/session.sh phase-start <phase>`

### Post-phase (after completing a phase)

1. Save artifact with `context_checkpoint` via `bin/save-artifact.sh`
   - The `context_checkpoint` must include: `summary`, `key_files`, `decisions_made`, `open_questions`
   - No artifact is saved without `context_checkpoint` populated
2. Update session: `bin/session.sh phase-complete <phase>`
3. If context is running low, the agent reads the checkpoint summary instead of replaying full conversation

### Session resume (on crash recovery)

1. `bin/session.sh resume` detects the last session state
2. `bin/restore-context.sh` reads all completed phase checkpoints
3. Skip completed phases, restart the in-progress phase from scratch

## Gotchas

- **The conductor is optional.** Single-agent sprints work without it. The conductor adds value only when multiple agents or sessions are involved.
- **Build is manual.** The conductor doesn't execute code — it tracks who is doing what. The human or agent does the actual work.
- **Don't over-parallelize.** review + qa + security in parallel is the sweet spot. Parallelizing think + plan is pointless — they're sequential by nature.
- **Stale locks happen.** If an agent crashes mid-phase, the lock stays. After 1 hour with a dead PID, any agent can reclaim.
- **The sprint is project-scoped.** One sprint per project at a time. Starting a new sprint archives the previous one.
