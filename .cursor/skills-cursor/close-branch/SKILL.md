# Close Research Branch

Skill for archiving a completed research branch cleanly, extracting learnings, and moving forward.

## When to Use

- The user says "we're done with X", "close this out", "archive this branch"
- A decision entry conclusively resolves a line of inquiry
- All experiments under a plan have been evaluated
- A phase is complete and needs a concluding checkpoint

## Sequence

### 1. Load the Branch

```
recall(project="<active-project-name>", entry_id="<branch_root_id>")
```

Identify all entries in the subtree: decisions, experiments, notes, annotations.

### 2. Summarize Findings

Create a concluding checkpoint that captures:
- What was attempted (the original plan/hypothesis)
- What worked and what didn't (experiment results)
- Final conclusion (the decisive outcome)
- Any surprises or gotchas discovered

```
record(
  project="<active-project-name>",
  type="checkpoint",
  title="<Phase/Branch> complete — <one-line summary>",
  body="<structured summary>",
  parent_id="<branch_root_id>",
  tags="checkpoint,complete,<phase-tag>"
)
```

### 3. Extract Reusable Learnings

For any procedures, patterns, or gotchas that would help future agents:

```
skill(
  action="save",
  name="<descriptive-name>",
  category="<relevant-category>",
  content="<step-by-step procedure or pattern description>",
  tags="<comma-separated tags>"
)
```

Good candidates for skills:
- Workarounds for tool/API limitations
- Multi-step procedures that were non-obvious
- Patterns that proved effective

### 4. Mark Discarded Experiments (Optional)

If any experiments in the branch were superseded or abandoned:

```
discard(entry_id="<id>", reason="Superseded by <decision-id>")
```

### 5. Link Related Work (Optional)

If this branch's conclusions inform other branches:

```
relate(action="link", entry_a="<this_summary>", entry_b="<related_entry>", rationale="<why they connect>")
```

### 6. Confirm Closure

Tell the user:
- The branch is archived with a concluding checkpoint
- N skills were extracted (if any)
- What the suggested next phase/branch is

## Rules

- Never discard entries that contain unique information — only mark truly superseded ones
- Always create the concluding checkpoint before extracting skills (the checkpoint anchors the context)
- If the branch has sub-branches with their own open threads, close those first (bottom-up)
