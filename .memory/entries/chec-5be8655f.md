---
id: chec-5be8655f
type: checkpoint
project: menegroth
parent_id: plan-382ddd12
title: 'Stages A–C done: shared moment-carrying-column foundation (demand split +
  StoryStability + design_column_moments), gates green'
node_label: 'Stages A–C done: shared moment-carrying-column fou'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/types/demands.jl@46aa882, StructuralSizer/src/members/codes/shared/story_stability.jl@46aa882,
  StructuralSizer/src/members/codes/shared/column_moments.jl@46aa882, StructuralSizer/src/members/codes/shared/_shared.jl@46aa882,
  StructuralSizer/src/members/codes/_codes.jl@46aa882, StructuralSizer/src/StructuralSizer.jl@46aa882,
  StructuralSizer/test/members/test_shared_column_moments.jl@46aa882, StructuralSizer/test/runtests.jl@46aa882
session_id: sess-d553f493
created_at: '2026-11-23T04:23:18.023624+00:00'
updated_at: '2026-11-23T04:23:18.023624+00:00'
---
Implemented the material-agnostic second-order column foundation from plan-382ddd12, all additive and no-op until wired (Stage D).

Stage A — demand split: new shared `LateralTranslation{T}` carrier (Plt + per-axis lt end moments) added as one optional `lt::Union{Nothing,LateralTranslation{T}}=nothing` field on BOTH `RCColumnDemand` and `MemberDemand` (demands.jl). `nothing` = pure gravity/no-translation → byte-identical. Keyword constructors + both inner positional constructors thread it via `_convert_lt`. No positional construction sites elsewhere (the two Sizer NLP cache-key tuples only READ fields; all Synthesizer sites use the keyword ctor).

Stage B — shared `StoryStability` record (codes/shared/story_stability.jl): one record (ΣPu,V,Δ,L,Pmf,ΣPc) feeding BOTH ACI Q (§10.10.5.2) via `SwayStoryProperties` adapter and AISC B2 (App.8 Eq.A-8-6) via `B2StoryProperties` adapter. Unit-agnostic (Q and B2 dimensionless).

Stage C — `design_column_moments` trait (codes/shared/column_moments.jl), dispatched on demand type: RC returns sway-magnified END moments M=Mns+δs·Ms (§10.10.7.1, δs axis-independent; δs from _sway_delta_s mirroring magnify_moment_sway_complete's Q→ΣPc→needs_P_delta ladder) for the checker's existing braced along-length+interaction; STEEL returns fully amplified Mr=B1·Mnt+B2·Mlt (A-8-1) + Pr=Pnt+B2·Plt (A-8-2), with B1 using first-order Pr=Pnt+Plt per AISC Commentary §App.8.2.1. No-op when lt===nothing / no story / non-sway. NOT yet wired into any production checker — pure functions.

Gates (all fresh --fresh): StructuralSizer full suite 16401 pass; Steel Members 797/797, Concrete Columns 2112/2112, Member Defaults 89/89 (incl. new test_shared_column_moments.jl validating StructurePoint 18x18 RC sway δs=1.096 and AISC App.8 B2=1.13). StructuralSynthesizer Flat-plate MEMBER STAGE 299/299 PASS (byte-identical).

Pre-existing failures are ORTHOGONAL and NOT mine: Sizer 2 vault + 3 joist-rib (caused by uncommitted prior-session slabs/sizing.jl; vault slab sizing returns nothing); Synthesizer 1 'fire coating is dead load' closure fail caused by uncommitted prior-session re-solve-skip optimization #18 (column_reconciliation.jl/graph_builder.jl, model_current default ON). My additions are unreachable from production (unwired + lt defaults nothing), so cannot cause these.

IMPORTANT for next session: working tree holds UNCOMMITTED prior-session WIP I deliberately did NOT commit — slabs/sizing.jl (+48/-8), column_reconciliation.jl (#18 re-solve skip), graph_builder.jl, design_workflow.jl (includes new untracked workflow/column_oversize.jl), postprocess/ec.jl (rib_comp_steel_ec), + untracked scripts/runners/*. Left for user review.

Next: Stage D — assign_lateral_demands(BuildingUnit) extracting Mnt from gravity cases + Mlt from wind/ELF cases, combine per ASCE 7 §2.3, populate columns in W2 recheck; wire design_column_moments into RC+steel checkers behind an off-by-default flag. Stage E — dual LateralSystem type + Table 12.2-1 rows (STOP point: needs user confirmation of R/Cd/Ω0 target rows).
