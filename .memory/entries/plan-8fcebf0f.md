---
id: plan-8fcebf0f
type: plan
project: menegroth
parent_id: plan-6fa91d7d
title: 'Joined ordinary walls (L, T, C, box cores): check each leg on its own mesh
  cut'
node_label: Joined walls per-leg
tags: walls,joined,core,flange,ordinary,phase7,plan
status: active
open_threads: 5
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/wall_cuts.jl@c841c83, StructuralSynthesizer/src/analyze/lateral/wall_combinations.jl@1b29a66,
  StructuralSynthesizer/src/analyze/lateral/wall_ordinary_check.jl@1b29a66, StructuralSynthesizer/src/analyze/lateral/ordinary_wall_stage.jl@1b29a66,
  StructuralSynthesizer/src/analyze/asap/asap/wall_mesh.jl@c841c83
session_id: sess-9bd5aa01
created_at: '2026-11-04T15:59:40.688276+00:00'
updated_at: '2026-11-04T20:22:29.425144+00:00'
has_child_rationale: Removes refuse_joined_wall_design for ordinary walls before Phase
  8 openings
---
Confirmed by user 2026-11-04.

**Approach (ENGINEERING JUDGMENT, labelled in code).** ACI 318-19 Ch. 11 has no ordinary-wall effective flange width; the only flange width is §18.10.5.2 for special walls (corpus aci-318-19, PDF p. 325). Each leg of a joined assembly is checked as its own rectangular pier against the cut forces the shell mesh assigns it. Composite action appears as leg axial force. The assembly is used for equilibrium only.

**Decisions**
- Leg strength length = clear length: centerline length minus half the other wall's thickness at each joined end (corner concrete counted once).
- T-junction (wall end landing on another wall's interior, same story): split the through-wall at the junction automatically so the mesh shares nodes and the assembly groups them. Today such a web is tied only through the diaphragm.
- Out-of-plane shear and moment in each leg's cut: reported on the leg record only; out-of-plane design is a later slice.
- Vertical shear through the corner joint: checked in this slice by shear friction (§22.9), corpus first. Demand = vertical force through the shared corner nodes over a story; capacity from horizontal bars crossing the joint.

**Steps**
1. T-junction detection + automatic split.
2. Per-leg (N, V, M) from pier_wall_action; store out-of-plane components; gate that leg cuts sum to the assembly cut.
3. Per-leg existing checks (§11.5.4 shear, §11.6.2 min reinf, §22.4 axial-flexure, §11.5.3 bearing) with clear lw and stacked hw; remove refuse_joined_wall_design from stage, combinations, ordinary check; records carry assembly id.
4. Joint vertical shear by shear friction.
5. Each leg keeps its own ρ; corner zone reported at the larger.
6. Tests: L wall loaded along one leg; symmetric T along web; box core in torsion; T-junction detection; joint shear failure recorded.

**Out of scope:** special-wall flange width and composite P–M (with §18.10, Phase 9); openings (Phase 8, next).
