---
id: note-dd0b46c6
type: note
project: menegroth
parent_id: plan-5d8af001
title: 'Run 3 checker wave (Option B): critic P0 slab-order determinism + reviewer
  P1 trace; smaller P1/P2s'
node_label: 'Run 3 checker wave (Option B): critic P0 slab-orde'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-162874c5
created_at: '2026-07-14T11:55:14.718331+00:00'
updated_at: '2026-07-14T11:55:14.718331+00:00'
---
Blind checker panel on the Run-3 Option-B fine-per-slab-node + level-barrier work (run as direct subagents due to a cross-run scripts/runners lease block). design_building 15-invariant gate + per-member signature were green, but the checkers found deeper issues the gates miss:

P0 (critic, safety-critical, exact-first): Flat-plate slab sizing (size_flat_plate!, pipeline.jl:869-874, _update_column_sizes! pipeline.jl:48-49) reads LIVE shared supporting-column c1/c2 (DDM clear span ln=l1-c1, punching perimeter, deflection). Columns are grown MONOTONICALLY across slabs, so a slab's own captured result depends on WHICH SIBLING grew the shared column first -> slab processing ORDER affects design output. The fine graph orders slabs by slab_parallel_batches (conflict coloring); single-threaded coarse size_slabs! (sizing.jl:101-108) iterates eachindex. For a multi-bay FlatPlateOptions(grouping=:individual) flat plate (columns shared across batches) these differ -> different slab.result thickness/rebar -> NOT byte-identical to legacy single-threaded design_building. The decomposition gate FALSE-PASSES: its fixtures are column-independent (:by_floor disjoint columns single batch; vault writes no columns). ALSO: the existing coarse pipeline is ALREADY thread-count non-deterministic (sizing.jl:93-99 multithreaded batch order vs 101-108 single-thread eachindex) for these configs -> Run 3 exposed a pre-existing latent non-determinism; exact-first is ill-defined for :individual column-sharing flat plates until a canonical order is pinned.

P1 (reviewer): design_building(...; tc=TraceCollector()) solver_trace changed - fine slab closures emit per-node size_slab! events instead of legacy stage_1_slabs + size_slabs! envelope (capture_design appends to design.solver_trace). Fix: preserve the coarse trace envelope around per-slab nodes, OR explicitly exempt solver_trace from exact-first + update contract/tests.

P1 (critic): restore_slab_node_writes! (snapshot.jl:268) + _adopt_larger_column! (snapshot.jl:299) are DEAD (only unreachable scheduler.jl:344 call site) AND UNTESTED, despite 4 comments claiming 'unit-tested directly' (snapshot.jl:53, scheduler.jl:344, test:682, runner:781). Fix: add the direct unit tests (mixed clean/dirty level, shared-column max-merge, aliasing) OR correct the false comments.

P2s: (a) _adopt_larger_column! sets 'grew' only on dimensional increase -> skips section/shape/volumes adoption when c1/c2 tie but rebar differs (latent for Option A mixed level). (b) _col_cache: coarse shares one cache across slabs (sizing.jl:82-85), fine passes _col_cache=nothing per slab -> byte-identity assumes cache is read-only post precompute_capacities!; verify/document. (c) inter-batch sync count (N vs coarse 1) result-neutral only while slab sizing reads tributary Pu/geometry not el.forces + sync rewrites idempotently.

NEXT: one fix cycle handles reviewer P1 (trace envelope) + critic P1 (comments/tests) + P2s + ADD the multi-bay :individual flat-plate exact-first fixture that exposes the P0. The P0 ORDER/determinism resolution is a user decision (changes design outputs in some thread configs) - surfaced separately.
