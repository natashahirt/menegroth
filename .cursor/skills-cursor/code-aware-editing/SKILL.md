# Code-Aware Editing

Skill for the pre-edit reflex that closes the code ↔ memory loop: before touching a
symbol, learn why it exists and what breaks; after editing, let its provenance
tether advance for free by pinning files as usual.

## When to Use

- You are about to change a function, class, or module (not a trivial rename/typo)
- You need to know the blast radius of a change before committing to it
- You want the memory behind a symbol — the decision or experiment that shaped it
- You are scoping parallel work and need non-overlapping change surfaces
- As a reviewer/critic completeness check: "were all callers updated, or just the definition?"

## Sequence

### 1. Understand why it exists

```
codebase(action="context", ...)
```

Returns a rolling **tip** (the newest high-signal entry — decision / experiment /
checkpoint — touching the symbol) plus an append-only provenance **chain**, each
entry tagged `changed` (the pin edited the symbol) or `referenced` (it merely cited
the file). Pass `expand_synapse=true` to hop from the tip to related ZK canon.

### 2. See what breaks

```
codebase(action="blast", ...)
```

Returns `{impacted: [{qualified_name, file, line, distance, severity: breaks|maybe}],
tests_affected, summary, next}` — the reverse `CALLS` / `IMPORTS` neighborhood,
depth-capped and ranked. Use `callers` / `callees` / `imports` for tighter 1-hop
views, `health` to gauge whether the area is risky to touch, and `ownership` to see
who wrote it (ranked git-blame contributors, `memory-mcp` bot excluded).

### 3. Make the change, then record

Edit the code, then pin the files as you always do:

```
record(project="<active-project-name>", type="<decision|experiment|note>",
       title="<what changed>", body="<why>", parent_id="<active phase or deeper>",
       files="<changed paths>")
```

The symbol tether is **derived** from the file pin — you never maintain it by hand.
Pinning is the only action; the per-symbol tip + chain advance automatically.

## Trigger table

| The agent is asking… | Action |
|------|-----|
| "what breaks if I change X" | `codebase(action="blast")` |
| "why is this here / who decided this" | `codebase(action="context")` |
| "is this risky to touch" | `codebase(action="health")` |
| "who owns / who wrote / who to ask about X" (code owners, blame) | `codebase(action="ownership")` |
| "where is X defined / what lives here" | `codebase(action="lookup")` (default) |

## Rules

- The reflex is **advisory** — the hooks that surface it never block the edit.
  Orient **once**; once you have context/blast (or recorded a tether) for a change,
  proceed — do not re-orient in a loop on every `Edit`/`Write`.
- **Creating a new file?** It has no prior anchor, so a `context`/`blast` on the new
  path returning "anchor absent" is *expected* — it is not a sign you failed to
  orient. If the new code builds on existing symbols, orient on **those**
  dependencies instead, then `record(..., files=...)` to establish its tether.
- Follow each payload's `next` hint — the tools teach the sequence.
- Skip the reflex for trivial/mechanical edits (rename, typo, formatting) and for
  small, verified, locally-contained changes.
- Never hand-maintain tethers — pin files with `record(..., files=...)` and the
  symbol provenance updates for free.
- Julia (`.jl`) and other unsupported languages degrade to file-level anchors: the
  chain/tip still work at file grain, without `Class.method` symbols.

> **How the hooks deliver this (deterministic, never blocking).** On Claude Code the
> `PreToolUse` hook decides in code from the target path: an existing code file gets
> the orient nudge, a brand-new file gets the "anchor absent is expected" note, and
> non-code files are skipped. Cursor's pre-edit channel cannot inject advice without
> blocking, so there the reminder rides the `postToolUse` hook *after* a `Write`
> (record a tether); orient *before* editing is guidance here and in `memory.mdc`,
> not a gate.
