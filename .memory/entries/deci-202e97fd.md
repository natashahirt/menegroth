---
id: deci-202e97fd
type: decision
project: menegroth
parent_id: deci-ddb40441
title: FEA flat plate remeshes when a column grows; fenced column zones are the follow-up
node_label: Remesh on column growth
tags: fea,punching,mesh,speed,tier2
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-dbe32898
created_at: '2026-11-02T22:45:01.601437+00:00'
updated_at: '2026-11-02T22:45:01.601437+00:00'
has_child_rationale: Gate and profile run on 2026-11-02 found the medium-office FEA
  floors failing on punching.
---
Finding (2026-11-02, medium office 159x108 ft, 8x5x3, FEA flat plate):
- Floors 1 and 2 failed `FLOOR_DESIGN_NOT_CONVERGED (punching_shear)` because the profile capped punching passes at 3. The last failing column sat at ratio 1.000-1.001, so a different mesh flipped them either way. At 10 passes both converge. `DesignParameters` default is 20.
- The mesh kept from the start of a design understates punching demand by about 1-3%: columns grow 17 in -> 27 in but the stiff patches stay at 17 in. Rebuilding the mesh to follow the columns gives ratios 1.396 vs 1.382 on the first pass, needs more passes, and lands at 0.996/0.998.
- The restore-solve skip and the seeded mesher are not the cause. Old pipeline had the same stale footprint; the new installability check (`_require_installable_floor`) is what refuses a non-converged floor.
- Timing on this building: stale mesh 297 s, remesh 536 s (10 passes, busy machine).

Decision:
- `_build_or_update_fea!` recomputes `fea_mesh_key` on every analysis. A changed key resets the whole cache (`_reset_fea_cache!`, including median edge length, per-cell live fields and U_D) and rebuilds. The build stamps the key.
- Test: StructuralSizer/test/slabs/test_fea_mesh_key.jl, 'FEA remesh on column growth' (same columns reuse the model; grown column rebuilds; rebuilt result == fresh cache, exact). Run it under the StructuralSynthesizer project: `julia scripts/runners/test_quiet.jl StructuralSynthesizer ../../StructuralSizer/test/slabs/test_fea_mesh_key.jl`.
- Diagnostic runners: scripts/runners/ab_flat_fea_speed.jl, scripts/runners/ab_flat_fea_punching.jl. Logs logs/ab_punch_*_20261102.log.

Follow-up (Tier 2, gated against the full remesh): fenced zones around each column. Asap's Shell mesher triangulates and Ruppert-refines the whole slab in one pass with patch vertices as plain points, so a local change needs a fixed zone boundary per column (sized for the column cap plus critical section and margin), meshed once; a column change remeshes only its zone and splices it in. Saves mesh generation only; node numbering and the stiffness pattern still change, so assembly and factorization are redone. Gate: punching ratios and moments vs full remesh within a tolerance. Triangle re-tagging without remesh was judged too coarse (patch edge jagged at 0.15-0.3 m vs 1-10 in growth).

Also open from the same run: verify_design_graph_incremental.jl crashed on the isolated steel-beam override fixture (SingularException), likely from f869236c freeing coupled node rotations; profile time is now dominated by output_hash fingerprinting (~75%), not Asap.
