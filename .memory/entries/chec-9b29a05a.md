---
id: chec-9b29a05a
type: checkpoint
project: menegroth
parent_id: deci-f53d6337
title: 'Change 1 COMPLETE (GREEN): flat-plate col_I_factor is now a Single Source
  of Truth across FEA + EFM + incremental engine — gate 49/49'
node_label: 'Change 1 COMPLETE (GREEN): flat-plate col_I_factor'
tags: flat-plate,col-i-factor,aci-318-11,ssot,incremental,julia-dispatch,change-1
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-44f9458b
created_at: '2026-10-22T05:16:21.870611+00:00'
updated_at: '2026-10-22T05:16:47.957715+00:00'
---
WHAT
----
Flat-plate column cracking-stiffness (`col_I_factor`) is now a Single Source of Truth threaded consistently across three paths:

1. **FEA**: `opts.col_I_factor` via `_col_asap_sec`.
2. **Primary + secondary EFM column-stub derivations** (StructuralSizer `flat_plate/analysis/efm.jl`): captures incoming `col_I` and scales the cracked stubs; the uncracked stub stays 1.0. `run_secondary_moment_analysis` now receives `col_I_factor=opts.col_I_factor`, eliminating the prior directional asymmetry between primary and secondary analyses.
3. **Incremental design engine** (see lifecycle below).

Scoped floor overrides inherit `params.column_I_factor` at slab sizing — `col_I_factor` is a column-type property, orthogonal to floor zones.

INCREMENTAL ENGINE LIFECYCLE
----------------------------
- `column_I_factor` is **PREPARE-AFFECTING** (it bakes flat-plate column stubs at `prepare!`) → added to `PREPARE_AFFECTING_FIELDS` in `design_graph/scheduler.jl`.
- `beam_I_factor` is consumed **only during member sizing** → added to `NODE_MEMBERS.param_slice` in `design_graph/provenance.jl`.
- DO NOT add `:column_I_factor` to `NODE_MEMBERS.param_slice`: the gate's check G asserts its dirty-frontier is EMPTY (purely prepare-affecting), and that check is itself the guard against future demotion.

NO-OP AT DEFAULTS
-----------------
`col_I_factor=0.70` columns / `0.35` beams / `0.25` flat plates reproduce prior behavior byte-exactly.

CITATION
--------
ACI 318-11 §10.10.4.1 (0.70 Ig columns, 0.35 Ig beams, 0.25 Ig flat plates). Engineering boundary crossing: the derivation sites live in StructuralSizer `efm.jl`, while the knob originates in StructuralSynthesizer `params`.

STATUS: GREEN
-------------
Authoritative gate `scripts/runners/verify_i_factor_threading.jl` passes **49/49** (checks A–D frame cracked-stiffness, E–F flat-plate cold FEA+EFM, G–H incremental invalidation), exit 0.

CHANGED FILES (UNCOMMITTED — for morning review, intentionally NOT pinned)
----------------------------------------------------------------------
- StructuralSynthesizer/src/design_types.jl
- StructuralSynthesizer/src/design_graph/scheduler.jl
- StructuralSynthesizer/src/design_graph/provenance.jl
- StructuralSynthesizer/src/core/initialize.jl
- StructuralSynthesizer/src/analyze/slabs/utils.jl
- StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm.jl
- StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline.jl
- StructuralSizer/src/slabs/codes/concrete/flat_plate/design/rule_of_thumb.jl
- scripts/runners/verify_i_factor_threading.jl

RUN: run-e5fed01c, 3 extensions used (of 3). Fix cycles: eng2 (missed secondary-EFM calls + scoped-override factor drop), eng3 (critic P0 incremental registration), eng4 (dispatch-ambiguity fix). rev4 PASS, crit4 CONCERN (P2-only).
