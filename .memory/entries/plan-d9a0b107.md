---
id: plan-d9a0b107
type: plan
project: menegroth
parent_id: plan-cecee16b
title: 'Step 4 readiness: explicit-truss/braced-frame assembly layer — integration
  map, minimal new abstractions, 6 open design decisions'
node_label: 'Step 4 readiness: explicit-truss/braced-frame asse'
tags: truss,braced-frame,strut,assembly,asap,freefree,step-4,phase-h,phase-c,readiness,scoping
status: active
open_threads: 0
success: 'null'
files: external/Asap/src/Elements/K.jl@6140dcd, external/Asap/src/Model/postprocessing.jl@6140dcd,
  StructuralSynthesizer/src/analyze/members/members/initialize.jl@507697a, StructuralSynthesizer/src/analyze/members/members/demands.jl@7ea70a0,
  StructuralSynthesizer/src/analyze/asap/asap/load_routing.jl@6140dcd, StructuralSynthesizer/src/analyze/asap/asap/model_builder.jl@6140dcd,
  StructuralSynthesizer/src/building_types/members.jl@507697a, StructuralSizer/src/members/optimize/api/axial.jl@47f817f
session_id: sess-f794529d
created_at: '2026-11-23T18:16:28.810260+00:00'
updated_at: '2026-11-23T18:16:52.958614+00:00'
has_child_rationale: Read-only design-scoping pass for step 4 (deci-4a4f60e5); makes
  the explicit-truss layer execute-ready once steps 1-2 land. Gated on the in-flight
  lateral-demand pipeline.
related_to: todo-fcdb03a2,todo-d937bb05
---
Read-only scoping of step 4 (explicit-truss/braced-frame assembly layer). HEADLINE: almost everything exists; step 4 is mostly reuse. GATED on the other agent's steps 1-2 (lateral-demand pipeline) — do not start implementation until that lands, and do not disturb the lateral vocabulary.

## Already exists (pure reuse)
- **Asap `:freefree` = linear truss member.** `k_freefree`/`local_K(Element{FreeFree})` (external/Asap/src/Elements/K.jl) keeps only EA/L on axial DOFs 1&7, zeros bending/torsion — a two-force member, no new mechanics. Releases enum: `:fixedfixed|:freefixed|:fixedfree|:freefree|:joist` (`:joist` = OWSJ, bending pinned, GJ kept). Building uses the unified 6-DOF `Model` (mixed_model.jl); braces live as frame Elements there, NOT in the standalone `TrussModel` (do not adopt it).
- **Axial force recovery:** `post_process_elements!` (postprocessing.jl:146) fills `element.forces`; `axial_force(el)=forces[7]`; richer `Asap.ElementForceAndDisplacement(el,loads).forces.P` (constant for a two-force member). Tension-positive; synthesizer negates for `Pu_c`.
- **`Strut{T}` + `brace_type::Symbol=:both`** (building_types/members.jl) — values `:both|:tension_only|:compression_only` EXACTLY match `size_axial_members` `_axial_brace_type`. No new primitive.
- **`:braces`→`Strut`** in `initialize_members!` (chain + single-edge paths). **`member_group_demands(...; member_edge_group=:struts)`** branch ALREADY computes par_Pu_c/par_Pu_t from f.P; `build_member_groups!(member_type=:struts)` works. Takeoff already sums struts (workflow/summary.jl:240).
- **Sizer:** `StructuralSizer.size_axial_members` (api/axial.jl) — the landed step-3 engine.

## The ONE real gap + minimal new abstractions
- **Release gap (the only model-builder edit):** `_build_edge_release_map` (load_routing.jl:379) maps only BEAM edges; strut/column/wall edges default to `:fixedfixed` in `to_asap!` (model_builder.jl:420). Brace edges must resolve to **`:freefree`** for truss behavior. MUST be gated to fire only when a Truss/braced-frame owner is present, not globally.
- **`Truss` owner struct** — MemberGroup-shaped record over `struc.struts` indices (+ chord refs + joint vertex ids). Mirror `MemberGroup` for optimization grouping and the lateral-system family for ownership. NOTE `OutriggerSystem <: LateralSystem` is already reserved ('Not implemented') in analyze/lateral/approaches/types.jl. Add `struc.trusses` + link/build helper mirroring `link_wall_stack!`.
- **`size_struts!(struc, opts)`** — near-copy of `size_steel_members!`: `member_group_demands(...:struts)` → `size_axial_members(Pu_c,Pu_t,geoms,opts; brace_type=[s.brace_type...])` → apply like `_apply_column_results!` → re-`process!`. Wire into `size_members!` (size_columns.jl).

## Data flow (truss overlay, all reuse except noted): initialize_members! tags struts with Truss group_id → to_asap! builds brace edges with release=:freefree (gap) → Asap.process!/_solve_struc_model! (no new solve) → member_group_demands(:struts) recovers Pu_c/Pu_t → size_struts!→size_axial_members → apply results.

## 6 OPEN DESIGN DECISIONS (resolve before/within step-4 build)
1. **Don't disturb the lateral pipeline (risk).** A braced frame IS a lateral system, but that vocabulary (LateralSystem/DemandAssignment, assign_lateral_demands) is owned by the other agent. RECOMMEND v1 = gravity/own-group assembly (`struc.trusses`+`size_struts!`); defer any LateralSystem/OutriggerSystem registration to a later coordinated step.
2. **Gating the `:freefree` flip** so it only applies under a Truss owner, not every `:braces` edge (would change K for solves the lateral pipeline reads). Also `to_asap!` refuses a strut under `diaphragms=:flexible` (model_builder.jl:270) — confirm interaction.
3. **Pinned-joint singularity.** All-`:freefree` members at shared joints can leave singular rotational DOFs; Asap guards it (model_builder.jl ~55-100) but a truss is a likely tripwire — need ≥1 bending-stiff element or explicit stabilizing release per joint.
4. **Chords: Column vs Strut.** Braced-frame chords are vertical Columns today (moments, link_column_stack!, sway). Decide whether the Truss owner re-tags chords as pinned (suppress moment/sway) or references them read-only; affects takeoff/all_members double-counting. (Ties to the chord-default decision on deci-ff84d1d8: axial Strut default, Beam-column opt-in.)
5. **Moment leakage for struts.** member_group_demands still computes Mux/Muy; self-weight on an inclined brace yields a small transverse diagram. Confirm size_axial_members' zero-moment assumption OK, or lump brace self-weight to joints.
6. **brace_type vector ordering.** Grouping can merge struts; ensure all struts in a group share brace_type (or split groups by brace_type) so the per-member vector is well-defined.

Deferred (not critical path): nonlinear tension/comp-only Asap element (buckling brace sheds compression) near external/Asap/src/Nonlinear/nonlinear_statics.jl — purely additive; linear `:freefree` already serves `:both` with force-based knockdown at sizing time.

Source: read-only design-scoping agent a37b9672. Corpus clause inventory (joint design Ch.K/J + 341 brace limits) pending from agent 15c4a795 — fold in when it lands.
