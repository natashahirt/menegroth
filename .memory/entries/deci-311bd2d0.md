---
id: deci-311bd2d0
type: decision
project: menegroth
parent_id: plan-a4de4826
title: Production strip_axis from support Δx/Δy; named c1 is parallel to global X
node_label: Production strip_axis from support Δx/Δy; named c1
tags: foundation-safety,strip-axis,c1,punching,production
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/foundations/utils.jl@ebe4f10, StructuralSizer/src/foundations/codes/aci/strip_footing.jl@ebe4f10
session_id: sess-8fe53411
created_at: '2026-09-23T07:09:08.479663+00:00'
updated_at: '2026-09-23T07:09:08.479663+00:00'
---
Production ACI strip sizing derives `strip_axis` from the same Δx/Δy used by `_support_positions_along_axis` and passes it through Synthesizer `_size_fnd_aci!`. Named `c1` is parallel to global X, so a Y-strip uses along-strip named `c2` and across-strip named `c1`.

Landed with this contract: Y-strip one-way shear uses along-strip c; Steps 5–6 transverse uses across/along; bearing A2 remapped as (c_along, c_across); B_min floored at c_across_max. Production punching: default `:c2` and inferred `:c1` keep max(|Mux|,|Muy|); 6-tuple geom cache; mat `:c1` swapped Ac. NLP includes transfer As (Inf infeasible).

This is a production-path convention, not a code clause. Items 1–15 oracles landed under this axis contract; ribbing remains out of scope.
