---
id: anno-f39aff9f
type: annotation
project: menegroth
parent_id: deci-51acee72
title: 'Coordinator write-lease contention: ghost lease + re-scoping vs concurrent
  framing run'
node_label: Lease contention lesson
tags: coordinator,write-lease,contention,ghost-lease,disjoint-writes
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-af346179
created_at: '2026-07-23T16:48:49.566981+00:00'
updated_at: '2026-07-23T16:48:49.566981+00:00'
has_child_rationale: Tooling lesson affecting future coordinator runs
---
Coordinator write-lease friction during this run:

1. **Ghost/stranded lease.** A stranded write-lease (`run-0fba5afc`) was held but not present in the coordinator state file. Cleared via `manage_paths(action="release")`.
2. **Re-scoped engineer `writes` twice** to keep them disjoint from an active *concurrent* framing run that held `analyze/framing` + `scripts/runners`.

**Lesson:** declare narrow, disjoint `writes` for implementer tasks, and keep new test files under the package test dir (`StructuralSynthesizer/test/...`) rather than `scripts/runners` when that path is contended by another live run.
