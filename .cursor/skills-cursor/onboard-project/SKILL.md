# Onboard to Project

Thorough onboarding sequence for a fresh agent joining an existing project. Goes beyond the `sessionStart` hook's quick recall to provide a full situational briefing.

## When to Use

- Starting work on a project you haven't touched in this session
- The user says "onboard", "catch me up", "what's the state of X"
- The `sessionStart` hook's quick recall reveals a complex tree that needs synthesis

## Sequence

### 1. Load the Research Tree

Start with the structural scaffold (cheap even on large trees), then drill into the
phase where work is happening:

```
recall(project="<active-project-name>", view="outline")   # subproject → phase scaffold
recall(project="<active-project-name>", entry_id="<active-phase-id>")  # full nested subtree
```

`recall` returns a nested `tree` (children are pre-nested — no need to reconstruct from
`parent_id`), a `summary` (counts by type/status), and `open_phases` (work containers
with no concluding checkpoint). For very large subtrees, pass `depth=N` to collapse deep
branches (each node still reports `descendant_count` / `descendant_types`). Note:
- `open_phases` — where work is unfinished; usually where to resume
- Which phases exist and their status (look for concluding checkpoints)
- The most recent entries (by `created_at`) — this is where work left off
- Any open todos
- Any entries with `open_threads > 0`

### 2. Load Relevant Skills

```
skill(action="search", query="<current workstream keyword>")
skill(action="search")   # empty query lists the whole library
```

Check if there are stored procedures or patterns relevant to the task at hand.

### 3. Get Codebase Overview

```
codebase()
```

Understand the structural layout: modules, key classes, entry points.

### 4. Synthesize Current State

Present a brief (3-5 bullet) summary:
- **Last activity**: What was the most recent entry? What phase is active?
- **Open threads**: How many unresolved threads exist? What are they about?
- **Key decisions**: What architectural choices are locked in?
- **Active experiments**: Anything in progress or awaiting results?
- **Todos**: Outstanding reminders from the user

### 5. Identify Next Steps

Based on the tree state, suggest 2-3 concrete next actions. Prioritize:
1. Open todos (user explicitly asked for these)
2. Unfinished experiments
3. Open threads on recent decisions
4. Items from the current phase plan that haven't been started

## Output Format

Present findings conversationally — don't dump raw JSON. Highlight what's actionable and what context the user needs to resume work effectively.
