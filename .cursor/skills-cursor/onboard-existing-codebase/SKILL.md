# Onboard an Existing Codebase (brownfield)

Bootstrap memory for a mature repo that has no research tree yet, by
reconstructing how the codebase was built from its git history. The result is a
back-dated, approximate timeline of eras, workstreams, and milestones so
`recall` has something useful on day one — instead of an empty tree that only
becomes valuable after months of lived recording.

This is lower-fidelity than memory captured live as work happened. Be honest
about that: reconstructed entries are a best-effort approximation, and they are
tagged `reconstructed` so future readers know.

## When to Use

- A fresh `angelo` install on an existing/mature codebase (git history but no `.memory/`)
- `session(action='pickup')` / `recall` reveal no project, and the repo clearly predates memory
- The user says "onboard this repo", "reconstruct history", "bootstrap memory for this project"

For a repo that already has a research tree, use the `onboard-project` skill instead.

## Sequence

### 1. Create the project root

```
create_project(name="<repo-name>", description="<one-line what this repo is>")
```

If a project already exists, stop — this repo is already bootstrapped; use `onboard-project`.

### 2. Understand the current shape

```
codebase()                       # structural census: modules, classes, entry points
```

Read the top-level `README`, and any `docs/`, `ARCHITECTURE`, or ADR files. This
grounds the synthesis in what the code *is* today, not just how it changed.

### 3. Gather the history digest

```
history(action="digest", granularity="auto", max_eras=12)
```

Returns a chunked, deterministic summary of how the repo evolved: eras (from
release tags when present, else calendar time), per-era churn (top directories),
representative commit messages, contributors, and milestones (initial commit,
large changes, notable merges). memory-mcp's own commits are excluded.

- If it reports `truncated: true`, raise `max_commits` (or narrow with `scope`) to reach earlier history.
- To drill into one era before writing decisions for it: `history(action="digest", era="<label>", include_messages=true)`.

### 4. Synthesize a proposed tree

Turn the digest into a tree that mirrors what lived memory would have produced:

- **Subprojects** (`type: plan`, parent `""`): long-lived workstreams inferred from the directories that churn across many eras (e.g. a `dashboard/`, an `engine/`).
- **Phases** (`type: plan`, child of a subproject): the eras themselves. Set `created_at` to the era's `end_date`.
- **Checkpoints / decisions** (child of a phase): milestones. Set `created_at` to the milestone commit's date, and pin the file(s) it touched to that commit with `files: "path@<sha>"`.

Keep it coarse and high-signal — a skeleton of how the repo was built, not a
commit-by-commit replay. Prefer a handful of meaningful entries per era.

### 5. Preview, then persist

Always dry-run first, show the user the proposed tree, and adjust before committing:

```
history(action="reconstruct", project="<repo-name>", entries_json="<JSON array>", dry_run=true)
# review the write_order, then:
history(action="reconstruct", project="<repo-name>", entries_json="<JSON array>")
```

Each entry object supports: `ref` (temp id for wiring), `parent` (a `ref`, an
existing id, or `""` for root), `type`, `title`, `body`, `tags`, `created_at`
(ISO-8601 historical date), and `files` (use `path@sha` to pin to a commit).
Every entry is auto-tagged `reconstructed` / `git-history`. The tool refuses to
run on a tree that already holds non-reconstructed entries unless `force=true`.

### 6. Record a baseline checkpoint

Capture the *current* state as of onboarding — the reconstruction's anchor in
the present:

```
record(project="<repo-name>", type="checkpoint",
       title="Baseline: architecture as of onboarding",
       body="<current modules, entry points, and what's active>",
       tags="reconstructed,baseline",
       files="<key files>")
```

### 7. Summarize

Tell the user, conversationally: how many eras/entries were reconstructed, the
major workstreams found, the key milestones, and an explicit caveat that this is
a git-derived approximation. Suggest that from here, memory should be captured
live as work happens.

## Notes

- Reconstruction is agent/user-initiated, never automatic — history is
  interpreted, and the user should see and approve the tree.
- Back-dating is real: entries carry their historical `created_at`, so the
  timeline, `open_phases` ordering, and recency ranking all reflect the past.
