---
id: anno-de93e75f
type: annotation
project: menegroth
parent_id: chec-9b29a05a
title: 'GOTCHA: a Julia method AMBIGUITY (not an unreachable edge) broke the ENTIRE
  production flat-plate path — static review can''t catch it, a runtime gate can'
node_label: 'GOTCHA: a Julia method AMBIGUITY (not an unreachab'
tags: julia-dispatch,flat-plate,col-i-factor,gotcha,change-1
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-44f9458b
created_at: '2026-10-22T05:16:35.960911+00:00'
updated_at: '2026-10-22T05:16:35.960911+00:00'
---
REUSABLE LESSON (Julia multiple dispatch)
-----------------------------------------
Widening the specific `_apply_col_I_factor(FlatPlateOptions/FlatSlabOptions, ::Real)` methods while leaving the fallback at `(AbstractFloorOptions, ::Float64)` made the real production call `(FlatPlateOptions, Float64)` AMBIGUOUS: both methods match and neither dominates — the specific method wins on arg1, the fallback wins on arg2. Julia cannot pick a winner, so it raises a MethodError at CALL time, not at package load.

WHY TWO STATIC REVIEWS MISSED IT
--------------------------------
Because the ambiguity only errors when the method is actually *called* (not during `using`), the package loaded cleanly and BOTH static reviews (reviewer + critic) passed. Only the RUNTIME gate, which exercises the real call site, caught it (gate went 32/33 FAIL).

FIX
---
Widen the fallback to `(AbstractFloorOptions, ::Real)` so it is strictly less specific than the specific methods on both args. Dispatch becomes unambiguous; gate returned to 49/49.

LESSON: For Julia multiple-dispatch changes, a runtime gate that exercises the real call site is ESSENTIAL — static dispatch reasoning is error-prone and insufficient; load-time success proves nothing about call-time dispatch resolution.

File (UNCOMMITTED, not pinned): StructuralSynthesizer/src/design_types.jl
