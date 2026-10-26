---
id: chec-c963ee3a
type: checkpoint
project: menegroth
parent_id: plan-a0000002
title: 'Asap speed: profiled design_building; Asap only matters on flat-plate FEA;
  scatter map + in-place refactor landed (uncommitted)'
node_label: 'Asap speed: profiled design_building; Asap only ma'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a2743bae
created_at: '2026-10-26T15:49:51.347933+00:00'
updated_at: '2026-10-26T15:49:51.347933+00:00'
---
Profile (scripts/runners/profile_design_building_asap.jl, 8 threads, 159x108 ft 8x5-bay medium office):
- DDM / default / steel cases: ~3.75 s warm design_building, Asap <1% (MIP column sizing ~63%, DDM eq13.7 transfer ~18%). Cold first call 145 s (compile) + 12 s package load -> sweeps are dominated by process start + compile, not Asap.
- Flat plate FEA: 567 s warm, ~91% in Asap. One slab mesh = 62k ShellTri3, 186k free DOFs, nnz(S)=7.8M (target_edge = clamp(span/20,0.15,0.75) m + column refinement). Split: _update_S_values! 38% (S[i,j] += binary search per entry), Shell meshing 34% (DelaunayTriangulation refine!; DT 1.6.6/1.7.0 has O(N) has_ghost_vertices scan inside is_boundary_node iteration), populate_loads 8%, solve 6%.

Landed in external/Asap (uncommitted, interleaved with a concurrent agent editing analysis.jl/meshing.jl):
1. _ScatterMap built in create_S! (_set_S!/_build_scatter_map); _update_S_values! does nzval[idx[p]] += K (guarded by S identity + nnz + COO length; falls back to indexed path). 10-13x on that kernel, bit-identical.
2. update!(values_only=true) marks the factor stale (_factorization_stale) instead of nulling; _get_factorization refactors in place with cholesky!(F, K) when _factor_pattern_key (objectid(S), nnz, freeDOFs) matches. No new pointer-holding fields, so snapshot deepcopy contract unchanged.
3. ShellTri3 global_K!: block-diagonal T' K_ab T in place instead of dense R'*K*R.
4. reactions!: (S*u)[fixed] instead of S[fixed,:]*u (bit-identical, avoids row extraction per solve).
Verified: scripts/runners/check_asap_fast_update.jl (shell + frame fast path == fresh build, 0 error). Single-slab FEA bench (scripts/runners/bench_asap_fea_slab.jl): update+re-solve 6.8 s -> ~3.7 s/iteration (noisy, machine shared). Asap Pkg.test: 1845 pass / 1 fail / 23 error, all pre-existing (ShellModel/TrussModel solve! pass @view to CHOLMOD \; test API drift).

Open decisions for user: FEA mesh density (62k elems/slab is the dominant scale factor), coordinating with the concurrent Asap-editing agent before commit, sysimage/one-process strategy for sweeps (scripts/api/build_sysimage.jl exists), DDM path needs sizing (not Asap) work.
