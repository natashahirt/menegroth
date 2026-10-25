---
id: chec-0a1cd5b3
type: checkpoint
project: menegroth
parent_id: todo-7dfc3edf
title: Phase 2 checks unshored composite beams under the SEI/ASCE 37-02 pre-cure load
node_label: Phase 2 pre-cure load committed
tags: composite,construction,asce-37,aisc-360
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/StructuralSizer.jl@d8c8c01, StructuralSizer/src/members/codes/aisc/checker.jl@d8c8c01,
  StructuralSizer/src/members/codes/aisc/composite/construction.jl@d8c8c01, StructuralSizer/src/members/codes/aisc/composite/per_station.jl@d8c8c01,
  StructuralSizer/src/members/codes/aisc/composite/types.jl@d8c8c01, StructuralSizer/test/steel_member/composite/test_composite_beam.jl@d8c8c01,
  StructuralSizer/test/steel_member/composite/test_composite_per_station.jl@d8c8c01,
  StructuralSizer/test/steel_member/test_phi_v_provision.jl@d8c8c01
session_id: sess-a9cd99a0
created_at: '2026-10-25T21:22:53.438615+00:00'
updated_at: '2026-10-25T21:22:53.438615+00:00'
has_child_rationale: Pins the Phase 2 construction-stage code. Supersedes the unpinned
  checkpoint chec-3262f25a.
invalidates: chec-3262f25a
---
Commit of the Phase 2 pre-cure check. Unshored composite beams are checked as bare steel under SEI/ASCE 37-02 §2.2.3 Eqs. 2-2 and 2-3 (corpus: sei-asce-37-02, PDF p. 16). C_P defaults to Table 2 medium duty, 50 psf (§4.8.1.1, PDF p. 29). Fresh concrete is C_VML at finished thickness (Commentary C4.2, PDF p. 22). Results name 37-02 as older than the ASCE/SEI 37-14 cited by AISC 360-22 Commentary §I3.1b (PDF p. 500). The final envelope is not the construction demand. Shored beams skip the check.

Judgment, flagged in code: M = wL^2/8 and V = wL/2 because the sizer does not see end releases; occupancy live load is not 0.5L unless passed; C_H is omitted; a deck flute is counted solid; unshored total deflection still scales the single FEM deflection by Ix.

Unrelated dirty work and the 37-02 manifest line in corpus/manifests/sources.yml stay out of this commit.
