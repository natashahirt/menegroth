---
id: plan-ec9a5d12
type: plan
project: menegroth
parent_id: deci-202e97fd
title: 'Codebase audit: mechanical greps and scripted citation check against the corpus'
node_label: Grep + citation audit
tags: audit,citations,corpus,threading,cache,bugs
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-41c7c377
created_at: '2026-11-03T18:06:11.272396+00:00'
updated_at: '2026-11-03T18:06:11.272396+00:00'
has_child_rationale: Six silent bugs found in two days around flat-plate FEA and punching
  (2026-11-02/03); nothing in the test suite catches this class.
---
Why: while fixing the flat-plate FEA remesh (deci-202e97fd) we hit, in one narrow area: a cache key missing the column footprint; per-thread buffers built at precompile time (segfault); a docstring step never implemented (design_shear_studs fixed n_studs = 3, so the 11.11.5.4 outer check fails and columns grow 0.5 in/pass); the same geometry written twice inconsistently (stud outer section uses c1/2 for edge/corner, punching_geometry_edge uses c1 + d/2); a computed value ignored (c1_req in :reinforce_first); a wrong clause label (8 sqrt(f'c) cited as 11.11.3.2, actually 11.11.5.1). Tests pass because they cover the happy path, and the pipeline turns failures into fallbacks.

Scope: StructuralSizer/src, StructuralSynthesizer/src, external/Asap/src. Output: one report (logs/ or memory note) listing each finding with file:line, class, and severity (unsafe / wrong-but-conservative / cosmetic). Do not fix in the same pass unless trivial; triage with the user first.

Part 1 - mechanical greps (rg, read each hit):
1. Package-level mutable state built at precompile time: `rg -n "^const .*(\[|Dict|Ref).*" --type julia` then read hits for anything filled per thread, holding C pointers, or caching computed results. Specifically `rg -n "threadid\(\)|nthreads\(\)|maxthreadid" --type julia`. Correct pattern: declare empty, fill in __init__, size to maxthreadid (Asap/src/threading.jl, _init_thread_pools!). The Gurobi env pool (StructuralSizer/src/optimize/solvers/discrete/backends.jl) is already correct: Dict keyed by tid, locked, reset in __init__. Also flag `@inbounds` on any threadid-indexed access.
2. Caches and memos: `rg -n "cache|memo|Memo|Cache" --type julia -g '!test'` and list every cache with (a) what it keys on, (b) every input that changes its value. Flag any input missing from the key (the FEA mesh-key bug was column size). Include the SizingMemo, NLP memo, beam-path cache, shared column cache, EFMModelCache, FEAModelCache, _punch_geom_cache, _geom_cache kwargs.
3. Computed-but-unused values: run JET.jl (`report_package`) or the Julia LanguageServer unused-variable lint over StructuralSizer and StructuralSynthesizer; manually review hits inside design / sizing functions (e.g. a required size computed then a fixed increment applied).
4. Docstring steps vs code: `rg -l "Design Steps|# Steps|Steps:" --type julia` (4 files in StructuralSizer at last count) plus functions whose docstrings enumerate procedure steps; for each numbered step confirm code implements it.
5. Duplicate implementations of the same quantity: rg for b0 / critical section geometry (`b1 =`, `b0 =`), Jc, gamma_v (`γv`, `gamma_v`), effective_depth, phi selection, Ec. For each concept list all definitions; flag disagreements (e.g. edge/corner conventions). Proposed outcome: one shared function per concept or a consistency test.
6. Silent fallbacks: rg for `@warn` inside sizing/design loops and for `catch` blocks that return a default; list which ones mean the design is not what was asked for (non-convergence, method fallback, stud failure -> growth).

Part 2 - scripted citation audit (write scripts/runners/audit_citations.jl):
- Extract every comment line citing a code clause: regex for `(ACI|AISC|CSA|fib|ASCE)[^\n]*§\s*[0-9][0-9.]*` and `Eq\.?\s*\(?[0-9]+-[0-9]+` (~1,944 lines with a § reference at last count). Capture file, line, standard, edition, clause, equation id, any numeric literal on the same or next code line, and any `corpus: <source_id>, page N` tag.
- For each, call the corpus (menegroth-corpus MCP get_clause, or the same lookup the MCP server wraps via corpus/text) for (family, edition, clause). Flag: clause not found; edition missing or ambiguous (e.g. 'per ACI 318' with no year); page tag disagrees with page_range; numeric value on the code line not present in the clause text window (e.g. 8 vs 6 sqrt(f'c)); citation to a clause whose text is about a different topic (keyword overlap check with the comment, low threshold, human review).
- Also flag code-derived literals with no citation: numeric factors (0.75, 0.9, 0.65, 2.0, 4.0, 8.0 times sqrt(fc), etc.) in StructuralSizer/src/codes and slabs/foundations without a nearby citation or ENGINEERING JUDGMENT tag.
- Follow corpus.mdc: MCP tools first, direct reads of corpus/text only as fallback; do not edit Julia from MCP hits without the corpus_promote review gate.
- Output a CSV/markdown table sorted by severity; a human (or agent with user) triages before any fix.

Related pending work from the same session: design_shear_studs fix (iterate stud lines; outer section stress with moment per ACI 421.1R-99 Eq. 3.2 at the outer section, Step 4 + Ch.7 example; edge/corner geometry via codes/aci/punching/general_geometry.jl; citation fix), check design_closed_stirrups for fixed extent, :reinforce_first should grow to c1_req, shared fixed-demand punching resolver.
