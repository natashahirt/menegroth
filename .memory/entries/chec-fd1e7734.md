---
id: chec-fd1e7734
type: checkpoint
project: menegroth
parent_id: deci-f98b3a20
title: '#18 implemented + verified EXACT: member-stage 299/299 + equivalence harness
  byte-identical (48 cols, 3 slabs)'
node_label: '#18 implemented + verified EXACT: member-stage 299'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-465a2ef3
created_at: '2026-11-21T03:29:50.132089+00:00'
updated_at: '2026-11-21T03:29:50.132089+00:00'
---
Implemented #18 in StructuralSynthesizer/src/workflow/column_reconciliation.jl + graph_builder.jl:
- _install_column_frame_section! now value-compares Asap.Section and returns changed::Bool (writes nothing on an unchanged column).
- _install_sized_column_frame!(...; skip_resolve_if_unchanged=false) skips _resolve_after_column_change! when no section changed and no gravity load was added (load-count delta).
- _reconcile_columns!(...; model_current=false) threads the flag; only the in-loop caller (graph_builder.jl, right after refresh_flat_plate_analysis!) passes model_current=true, gated by ENV SS_DISABLE_MEMBER_RESOLVE_SKIP for the harness. Pre-loop caller keeps always-solve.

VERIFICATION (both green):
1. core/test_flat_plate_member_stage.jl -> 299/299 PASS (bit-identical golden values with skip ON by default).
2. scripts/runners/equiv_member_resolve_skip.jl -> PASS, byte-identical sizing (48 columns + 3 slabs) between skip OFF (baseline) and skip ON (optimized) on a 3-story medium-office DDM flat plate.

CAVEAT: the harness's 1149s vs 319s run times are COMPILE-CONFOUNDED (first design pays JIT; second runs warm) and are NOT a clean speed measurement. The speed benefit (fewer building factorizations per in-loop member round) is structural; measure it cleanly via the stage profiler. Equivalence is the proven claim.

NEXT: #7 RigidLink factorization cache (the big lever: 44 of 48 building factorizations rebuild the full Cholesky each solve under rigid diaphragm links).
