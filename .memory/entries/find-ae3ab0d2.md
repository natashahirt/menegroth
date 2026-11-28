---
id: find-ae3ab0d2
type: finding
project: menegroth
parent_id: find-667f5187
title: 'e0c0 chirality SEED localized: a tiny ~0.01-0.05% reflection-ODD asymmetry
  in the extracted beam DEMANDS (present from the first analysis, call=3, before sections
  install) is amplified by a capacity THRESHOLD at the first sizing (bf36 vs bf12
  from near-equal demands) into the full diagonal split. Not a tie-break; the demands
  genuinely differ slightly'
node_label: 'e0c0 chirality SEED localized: a tiny ~0.01-0.05% '
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/demands.jl@dad3f75
session_id: sess-4d9a7041
created_at: '2026-11-24T14:48:17.783608+00:00'
updated_at: '2026-11-24T14:48:17.783608+00:00'
---
Instrumented per-call hub-girder demand+section dump (SS_TRACE_HUB_DEMANDS=1, _trace_hub_demands in demands.jl, 376 lines, logs/e0c0_hub_demand_trace.out). The C2 diagonal pair {NE,SW} stays identical-section throughout (collinear-shared, bf36 line); {NW,SE} is the other line (bf12). So the split is the two DIAGONALS diverging. Timeline of the x-mirror pair NE vs NW (should be equal on the non-chiral plan):
  call=3 (sec=none): NE Mu+=126120.392 vs NW Mu+=126185.922  -> diff 65.5 (0.05%)
  call=4 (sec=none): NE Mu+=276806.633 vs NW 276786.041, Vu 166996.154 vs 166991.511 -> diff ~20 / ~5 (~0.01%) ESSENTIALLY SYMMETRIC
  call=5 (FIRST sections): NE Vu=200375 sec=T12x24-bf36 ; NW Vu=170111 sec=T12x24-bf12  -> sections SPLIT hard (wide vs narrow flange) and demands then diverge 15% because stiffness now differs.

MECHANISM: between call=4 (near-identical demands, ~0.01% apart) and call=5, the first sizing assigned DIFFERENT sections (bf36 vs bf12) to NE vs NW. Because the call-4 demands are NOT exactly equal (a ~0.01-0.05% reflection-odd asymmetry seeded at the very first analysis), and a catalog capacity THRESHOLD sits in that demand range, the tiny asymmetry tips NE just above the bf12 capacity (needs bf36) and NW just below (bf12 passes). From then on the section->stiffness->demand feedback amplifies the split to the converged ~35% gap.

KEY: this is NOT an equal-cost MIP tie (hence the optimize_discrete tie-break fix was a no-op) and NOT an analysis bug for a GIVEN field (mirror-field test still bit-exact covariant). The seed is the tiny demand asymmetry present BEFORE any sections exist (uniform/default sections, call=3). Its origin is still open: (a) Threads.@threads nondeterministic reduction in member_group_demands / feasibility screening, or (b) a sub-permille geometric/mesh/tributary x-odd asymmetry (plan vertices not mirror-exact to machine precision; mesh matched only to 1e-3 m in the mirror test). Sign of the asymmetry flips between call 3 and 4 (NE<NW then NE>NW), mildly favoring the threading hypothesis.

NEXT DECISIVE CHEAP TEST: re-run instrumented with JULIA_NUM_THREADS=1. If call=3/4 demands become bit-exact symmetric (NE==NW==SW==SE), the seed is threading nondeterminism -> fix = deterministic/ordered reduction (or single-thread) in the demand path. If still ~0.01% asymmetric, the seed is geometry/mesh/tributary -> fix = snap plan vertices to mirror-exact or symmetrize mirror-equivalent member-group demands before sizing.

FIX FAMILIES either way: (1) eliminate the seed (deterministic reduction / exact-symmetric mesh); or (2) defensive symmetrization: detect geometrically mirror-equivalent member groups and unify their demands (max/average) before the MIP so identical-by-symmetry members size identically regardless of sub-permille noise.
