---
id: chec-84bfdaa7
type: checkpoint
project: menegroth
parent_id: deci-4a4f60e5
title: 'Step 3 landed: shared axial-member sizer size_axial_members in StructuralSizer
  (AISC Ch. E / Ch. D), 15/15 tests'
node_label: 'Step 3 landed: shared axial-member sizer size_axia'
tags: axial-member,strut,sizer,aisc,chapter-e,chapter-d,phase-h,phase-c,step-3,landed
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/optimize/api/axial.jl@47f817f, StructuralSizer/src/members/optimize/api.jl@47f817f,
  StructuralSizer/src/StructuralSizer.jl@47f817f, StructuralSizer/test/steel_member/test_axial_members.jl@47f817f,
  StructuralSizer/test/runtests.jl@47f817f
session_id: sess-ddbef912
created_at: '2026-11-23T18:12:30.312011+00:00'
updated_at: '2026-11-23T18:12:30.312011+00:00'
has_child_rationale: First serial unit of the LFRS roadmap (deci-4a4f60e5 step 3)
  complete and verified; records the engine the Strut/Truss layer will call
---
Step 3 of the LFRS sequencing (deci-4a4f60e5) and item 4 of the axial-member architecture (deci-ff84d1d8) are implemented. Built by an autonomous engineering agent with a self-review mandate (no coordinator, no separate critic/tester), then independently spot-verified by the orchestrator.

**What landed:** `size_axial_members(Pu_c, Pu_t, geometries, opts::SteelColumnOptions; brace_type=:both, ...)` in StructuralSizer. A THIN adapter — adds no capacity math. It maps `brace_type` to effective axial demand and delegates to the existing steel `size_columns` path (single `AISCChecker` + discrete-MIP/NLP solvers), so AISC 360-16 Chapter E compression (§E3/§E4/§E7) and Chapter D §D2 tension are the only limit states.

**brace_type → demand (the core logic, verified):** `:tension_only` → effective `Pu_c=0` (Ch. E not relied on; Ch. D governs); `:compression_only` → effective `Pu_t=0` (Ch. E governs); `:both` → keep both (checker takes governing). `zero(x)` preserves the caller's unit. Scalar or per-member-vector, length+value validated.

**:nlp + tension guard (verified):** the steel NLP interaction constraint is compression-only, so `:nlp` with any effective tension throws an ArgumentError pointing at `:discrete`; compression-only `:nlp` works.

**Flexure zeroed:** passes Mux=Muy=0, leaves end-moment/transverse-load at defaults; §H1 reduces to the pure axial check. Returns the unchanged `size_columns` NamedTuple.

**Wiring:** `include("api/axial.jl")` in api.jl; `size_axial_members` added to the export line in StructuralSizer.jl.

**Tests:** `StructuralSizer/test/steel_member/test_axial_members.jl`, registered in runtests.jl. 15/15 pass via `julia scripts/runners/test_quiet.jl StructuralSizer steel_member/test_axial_members.jl`. Covers Ch. E-heavier-than-Ch. D at equal magnitude/length, `:both` ≥ compression-only, `:nlp`+tension throw vs compression-only success, kip/kN equivalence, validation errors.

**Orchestrator fix post-landing:** corrected a §D2 citation page in a comment (said 'page 26'; authoritative generic/tension.jl cites p. 87) — doc-only, no math.

**Scope held:** StructuralSizer only; no StructuralSynthesizer/Asap edits; no `:braces`→`:struts` rename (deferred). Two open questions filed as child todos.

**Next serial unit:** step 4 (explicit-truss/braced-frame assembly layer) — GATED on the other agent's steps 1–2 (demand pipeline). Two read-only planners (design-scoping + corpus clause inventory) are running to make step 4 execute-ready.
