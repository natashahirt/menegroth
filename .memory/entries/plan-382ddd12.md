---
id: plan-382ddd12
type: plan
project: menegroth
parent_id: plan-7b305650
title: 'PLAN: shared material-generic moment-carrying-column architecture (RC + steel
  + timber), dual system, BuildingUnit demand source'
node_label: 'PLAN: shared material-generic moment-carrying-colu'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/types/demands.jl@7ea70a0, StructuralSizer/src/members/codes/aci/columns/slenderness.jl@7ea70a0,
  StructuralSizer/src/members/codes/aisc/generic/moment_amplification.jl@7ea70a0,
  StructuralSynthesizer/src/analyze/lateral/approaches/types.jl@7ea70a0, StructuralSynthesizer/src/analyze/members/members/demands.jl@7ea70a0
session_id: sess-81a81139
created_at: '2026-11-23T02:45:45.278788+00:00'
updated_at: '2026-11-23T02:45:45.278788+00:00'
---
User goal: size & analyze steel-frame (and RC, later timber) high-rises with a concrete core, including moment-carrying columns (dual systems). User chose: target=DUAL (general moment-carrying columns; gravity-only is the Mlt=0 special case) and demand_source=REUSE WALL-STAGE SINGLE COMBINED MODEL (BuildingUnit: core+frames in one solve, force follows stiffness), separating Mlt (lateral-translation) from Mnt (no-translation) and feeding columns via the W2 member-recheck (consistent with the inherit-the-wall-stage decision shipped in chec-b26b4cbf).

KEY INSIGHT: ACI 318-11 §10.10.7 and AISC 360-16 App. 8 are the SAME approximate 2nd-order method; both halves already exist in StructuralSizer.
- Design moment: RC Mns+δs·Ms  ≡  steel B1·Mnt+B2·Mlt
- Story sway amp: RC δs=1/(1-Q), Q=ΣPuΔo/(Vus·lc)  ≡  steel B2=1/(1-αΣPu/ΣPe,story), Pe,story=RM·H·L/ΔH
- Member P-δ: RC δns=Cm/(1-Pu/0.75Pc)  ≡  steel B1=Cm/(1-αPr/Pe1)
- Cm=0.6-0.4(M1/M2): IDENTICAL
- Story inputs: SwayStoryProperties(ΣPu,Vus,Δo,lc)  ≡  B2StoryProperties(Pstory,H,L,ΔH): same raw data; compute_story_properties! already computes them.
Both material amplifiers (magnify_moment_sway_complete in slenderness.jl; amplify_moments/B1/B2 in aisc/generic/moment_amplification.jl) ALREADY TAKE the nt/lt split as input. The demand structs just don't carry it yet.

SHARED 3-LAYER DESIGN:
1. Demand split (material-agnostic): column demand carries (Pnt,Plt) + per-axis (Mnt,Mlt). Existing RCColumnDemand/MemberDemand fields = the nt (no-translation/gravity) part; ADD lateral-translation fields defaulting to 0 (Mlt=0 → exact current behavior).
2. Shared StoryStability record (ΣPu, story shear H/Vus, 1st-order sway drift ΔH/Δo, story height L/lc) computed once from the solved model; ACI reads Q, AISC reads B2.
3. Material amplifier trait: design_column_moments(code, split_demand, story, geometry) → RC dispatch to magnify_moment_sway_complete, steel to B1·Mnt+B2·Mlt, timber(NDS) later. Wire into each checker's sway path, GATED (additive: Mlt=0 & nonsway → untouched).
Plugs into existing lateral-approaches framework: assign_lateral_demands (DemandAssignment hook, currently unimplemented) populates Mlt/Plt from the wall-stage solve.

WHAT WORKS TODAY: steel columns/beams size (SteelColumnOptions, steel_column_catalog, member_iteration.jl); concrete core lateral (wall stage: wind+ELF, drift, θ>θmax throws, special walls SDC D-F); mixed shell-wall+frame model; flat-plate slenderness crash fixed.
GAPS: (1) lateral never reaches columns (column_force_envelopes gravity-pattern only; assign_lateral_demands unimplemented) — THE crux; (2) demand has no nt/lt split; (3) members size before lateral solve (W2 recheck is the hook); (4) no steel-MF/braced + concrete-core dual LateralSystem type (InteractiveShearWallFrameSystem is concrete-only row F); OutriggerSystem 'Not implemented'; (5) no timber/NDS member code; (6) steel gravity-frame deformation compatibility SDC D-F (steel analog of gravity_induced.jl).

STAGES:
A. Shared demand split: add Plt + per-axis Mlt to RCColumnDemand & MemberDemand, zero-default (no-op). Verify byte-identical (member-stage 299 + steel tests).
B. Shared StoryStability: unify SwayStoryProperties/B2StoryProperties inputs; expose Q and B2 from one record.
C. Material amplifier trait design_column_moments; wire RC + steel checker sway paths, gated/additive.
D. assign_lateral_demands(BuildingUnit): separate Mlt/Plt from the wall-stage combined solve; populate column demands in the W2 recheck. THE integration.
E. Dual LateralSystem type (steel MF/braced + concrete core) + Table 12.2-1 dual rows (R/Cd/Ω0); §12.2.3.1 two-stage / dual-system checks.
F. (future) timber NDS; outriggers; perf at 40+ stories.

Start: Stage A (additive no-op), then C skeleton, verify, commit; D is the big one.
