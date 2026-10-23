---
id: chec-1f998dac
type: checkpoint
project: menegroth
parent_id: plan-d0c5bff3
title: Walls assemble into the building model without invented supports
node_label: Walls assemble into the building model without inv
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/_analyze.jl@3a66ee3, StructuralSynthesizer/src/analyze/asap/utils.jl@3a66ee3,
  StructuralSynthesizer/src/analyze/lateral/wall_cache_contract.jl@3a66ee3, StructuralSynthesizer/src/api/deserialize.jl@3a66ee3,
  StructuralSynthesizer/src/api/schema.jl@3a66ee3, StructuralSynthesizer/src/building_types/structure.jl@3a66ee3,
  StructuralSynthesizer/src/core/initialize.jl@3a66ee3, StructuralSynthesizer/src/design_types.jl@3a66ee3,
  StructuralSynthesizer/src/walls_bridge.jl@3a66ee3, StructuralSynthesizer/test/core/test_wall_data_model.jl@3a66ee3,
  scripts/runners/bench_wall_lateral_baselines.jl@3a66ee3, scripts/runners/verify_wall_shell_assembly_phase5c.jl@3a66ee3,
  external/Asap@3a66ee3
session_id: sess-4412100a
created_at: '2026-10-23T02:08:29.483735+00:00'
updated_at: '2026-10-23T02:08:29.483735+00:00'
has_child_rationale: Pin the Phase 5 wall-assembly commit
---
Commit of the concrete-wall model through Phase 5 assembly. Not a design pipeline: design_building still stops until a wall thickness lives on DesignParameters and lateral checks exist.

## What landed
- Walls on the building: BuildingStructure.walls, API edge group, initialize! requires an explicit wall thickness when :walls is non-empty, pier height to the next faced story, enclosure is the existing plate box.
- Phase 4 cache contract (wall_cache_contract.jl) still refuses to run. Baseline runner kept.
- A :walls frame edge keeps its element slot with zero area, inertia, torsion, and density so it adds no stiffness or mass. Asap consistent mass no longer divides rotary inertia by area (0/0 when both are zero); rewritten as ρ·L·I. Submodule commit 0089441.
- Wall shells are ShellTri3 in the same Asap model. Nodes within 1 mm are shared; an equal nearest pair throws. The mesher adds no supports: created nodes are free, reused frame and slab nodes keep their dof. A wall that meets nothing is unattached on purpose.
- _stiffness_token hashes shell node positions in node order, plus thickness, E, ν, κ, shear_stab, and drilling_scale. Density is not hashed. loads_only stays valid only when that fingerprint is unchanged.
- Equivalence runner verify_wall_shell_assembly_phase5c.jl: under a matched stiff-shell diaphragm the building mesh matches FEMLateralEvaluator exactly. Production uses the in-plane rigid link. Which diaphragm governs drift is deci-2c1bee70 (Phase 6), not this commit.

## Left out
Footing, punching, pattern-loading, and the column I-factor warning. scripts/runners/check_wall_base_fixity.jl asserts the rejected fixed-base rule and is not committed. The whole-phase test is the next step, not in this commit.

Files: StructuralSynthesizer/src/analyze/_analyze.jl, StructuralSynthesizer/src/analyze/asap/utils.jl, StructuralSynthesizer/src/analyze/lateral/wall_cache_contract.jl, StructuralSynthesizer/src/api/deserialize.jl, StructuralSynthesizer/src/api/schema.jl, StructuralSynthesizer/src/building_types/structure.jl, StructuralSynthesizer/src/core/initialize.jl, StructuralSynthesizer/src/design_types.jl, StructuralSynthesizer/src/walls_bridge.jl, StructuralSynthesizer/test/core/test_wall_data_model.jl, scripts/runners/bench_wall_lateral_baselines.jl, scripts/runners/verify_wall_shell_assembly_phase5c.jl, external/Asap.
