---
id: note-4c103bb8
type: note
project: menegroth
parent_id: plan-40b3c357
title: 'Fixed-mesh implementation spec: exact change-list + the edge-strip cap subtlety
  (widens surface beyond the 3 FEA funcs)'
node_label: 'Fixed-mesh implementation spec: exact change-list '
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/model.jl@fc5342d
session_id: sess-3371997a
created_at: '2026-11-27T04:48:08.763875+00:00'
updated_at: '2026-11-27T04:48:08.763875+00:00'
---
Traced the full FEA wiring. Precise change-list for the fixed_mesh prototype:

1. FEA struct (slabs/types/analysis_methods.jl): add fixed_mesh::Bool=false, fixed_mesh_cap::Union{Nothing,Length}=nothing (+validation). The cap is max_column_size; for the prototype the A/B harness sets it explicitly (=30in) so no opts threading is needed. Production (Phase 2) threads opts.max_column_size.

2. run_moment_analysis(::FEA) (fea/run.jl:134): pass method.fixed_mesh + resolved cap into _build_or_update_fea!. If fixed_mesh && cap===nothing, default to 36in with a one-time warn.

3. fea_mesh_key (fea/cache.jl): kwargs fixed_mesh,cap. When fixed_mesh, replace each column's (c1,c2,shape) in the key tuple with (cap,cap,:fixed) so growth stays on the update path (center xy + orientation still keyed).

4. build_slab_shell_patches (fea/model.jl): kwargs fixed_mesh,cap. When fixed_mesh, build each column patch at cap x cap (oriented) instead of c1 x c2.

5. build_slab_shell_mesh (fea/model.jl): when fixed_mesh, refine_edge = fixed fine ~0.025m (1in) INDEPENDENT of columns (Asap applies refinement_edge_length near patches, so this is the fenced fine annulus; target_edge stays coarse so DOF blow-up is local).

6. _build_fea_slab_model (fea/model.jl): after meshing, compute cache.patch_zone = [(shell_index, owning_col_index)] for every :col_patch triangle (centroid in that column's cap rect) + store each col center/orient/size. Re-tag to the SEED column size BEFORE process!/solve (so the first solve isn't the full cap footprint rigid).

7. _update_and_resolve! (fea/model.jl): when fixed_mesh, before the by-id E loop, for each (k,ci) in patch_zone set shells[k].id = centroid_in_current_col_rect(ci) ? :col_patch : :slab. Existing by-id loop then applies E_patch vs E. Node numbering + sparsity unchanged -> value-only update + symbolic-reuse refactor.

8. cache.jl FEAModelCache: add patch_zone::Vector{Tuple{Int,Int}} and col_cap_geom (center,orient,cap) ; reset with the mesh.

SUBTLETY FOUND (widens surface): _append_flat_plate_edge_strip! sizes the free-edge band from the largest column face on each straight edge (floor_slab_edges/slab_edge_offsets, building level). Edge-column growth changes the band width -> remesh even with capped patches. To actually avoid remeshes on a real design the edge-strip width must ALSO be cap-based. Options: (a) prototype on an INTERIOR-column-dominated building / fix edge columns so the band is stable, to measure the interior-column win first; (b) add a cap-based edge-band path. Recommend (a) for the first measurement, (b) in Phase 2.

Also: standard_rc_columns catalog is 8-36in; max_column_size default 30in. Fenced zone must cover cap + critical-section (d/2) margin.
