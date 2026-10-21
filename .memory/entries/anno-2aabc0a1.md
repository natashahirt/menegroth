---
id: anno-2aabc0a1
type: annotation
project: menegroth
parent_id: deci-4ef4e16f
title: 'Serialize heavy Julia subagents: concurrent Pkg.instantiate() SIGKILLed by
  depot/precompile contention'
node_label: Serialize Julia subagents
tags: julia, coordinator, concurrency, depot-contention, precompile, environment-limit
status: active
open_threads: 0
success: 'null'
files: scripts/runners/run_all_gates.jl@8dd4156
session_id: sess-c6b063bf
created_at: '2026-10-21T03:19:14.713492+00:00'
updated_at: '2026-10-21T03:19:14.713492+00:00'
has_child_rationale: 'Agent-initiated breadcrumb: an environment limit that forced
  the tester to skip the end-to-end gate and will affect how future coordinator runs
  schedule Julia tasks.'
---
**Limitation that forced a workaround this session.** Running multiple heavy Julia subagents concurrently causes `~/.julia` depot / precompile contention that repeatedly **SIGKILLs** top-level `Pkg.instantiate()`. With 3+ concurrent Julia agents, the Phase 0 tester could not complete the full end-to-end gate and had to fall back to a parse/load **smoke** test.

**Rule for future runs:** Julia-running tasks must be **SERIALIZED, not parallelized** — schedule them in sequential waves (or gate them behind a shared lease) so only one `Pkg.instantiate()` / precompile touches the depot at a time. This is an environment/toolchain limit, not a code fault.

**Related caveat (Phase 0 follow-up):** grasshopper `obj`/`bin` are ALREADY tracked, so the new `.gitignore` rules alone won't untrack them — a `git rm -r --cached grasshopper/Menegroth.GH/{obj,bin}` follow-up is still required.
