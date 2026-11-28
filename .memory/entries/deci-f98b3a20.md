---
id: deci-f98b3a20
type: decision
project: menegroth
parent_id: plan-6be479fb
title: '#18 corrected + designed: skip the redundant member-stage install re-solve
  (exact, gated to in-loop where refresh just solved)'
node_label: '#18 corrected + designed: skip the redundant membe'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-08e7ffda
created_at: '2026-11-21T02:57:10.913088+00:00'
updated_at: '2026-11-21T02:57:10.913088+00:00'
---
CORRECTION to the earlier #18 framing: the column re-solves in check_flat_plate_columns! are ALREADY batched per settle iteration (one _resolve_after_column_change! per iteration over ALL columns, not per column). The real redundancy is elsewhere: in the member settle loop (_design_flat_plate_members!), each round does refresh_flat_plate_analysis! (which SOLVES the current state) immediately followed by _reconcile_columns! -> _install_sized_column_frame!, which re-solves UNCONDITIONALLY even when it changed no frame section (gravity loads are already idempotent via _add_gravity_loads!). That install re-solve is redundant whenever the columns are unchanged since the frame's current sections, because refresh just solved exactly those.

DESIGN (exact, safe, small blast radius):
- _install_column_frame_section! compares the computed Asap.Section to the frame element's current .section (Asap.Section is an immutable isbits struct A/E/G/Ix/Iy/J/rho/Ay/Az; _rc_column_frame_section is deterministic from col dims), overwrites + returns changed::Bool only on a real difference. Robust to WHERE upstream updated sections: if col changed but frame wasn't updated => changed=true => solve; if both current => changed=false.
- _install_sized_column_frame!(...; skip_resolve_if_unchanged=false): accumulate changed over columns; detect added gravity loads by load-count delta; when skip_resolve_if_unchanged && !changed && !added, return false WITHOUT solving (model.u from the preceding refresh is already correct).
- _reconcile_columns!(...; model_current=false) threads the flag. Only the IN-LOOP caller (graph_builder.jl:446, immediately after refresh) passes model_current=true; the PRE-LOOP caller (412) keeps always-solve behavior. Proven precondition: refresh solves current state and nothing mutates the model before install.
- Callers of _reconcile_columns! ignore its return (synced/framed unused), and _install_sized_column_frame! has a single caller => contained.

EQUIVALENCE HARNESS: gate via ENV SS_DISABLE_MEMBER_RESOLVE_SKIP (graph_builder sets model_current = !haskey(ENV,...)). Runner designs the core office with skip on vs off and diffs column sizes / slab thickness / carbon; must be identical. Plus the existing bit-identical member-stage suite (299) and design_graph equivalence (51/8 baseline).
