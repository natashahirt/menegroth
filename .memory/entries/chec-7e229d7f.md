---
id: chec-7e229d7f
type: checkpoint
project: menegroth
parent_id: deci-610bd5f9
title: Close composite beam phases 3 through 5
node_label: Close composite beam phases 3 through 5
tags: composite,phase-3,phase-4,phase-5
status: active
open_threads: 0
success: 'null'
files: .memory/entries/deci-610bd5f9.md@8451627, StructuralSizer/src/StructuralSizer.jl@8451627,
  StructuralSizer/src/members/codes/aisc/checker.jl@8451627, StructuralSizer/src/members/codes/aisc/composite/construction.jl@8451627,
  StructuralSizer/src/members/codes/aisc/composite/flexure.jl@8451627, StructuralSizer/src/members/codes/aisc/composite/per_station.jl@8451627,
  StructuralSizer/src/members/codes/aisc/composite/rebar_from_slab.jl@8451627, StructuralSizer/src/members/codes/aisc/composite/stud_strength.jl@8451627,
  StructuralSizer/src/members/codes/aisc/composite/types.jl@8451627, StructuralSizer/src/optimize/core/options.jl@8451627,
  StructuralSizer/test/steel_member/composite/test_composite_beam.jl@8451627, StructuralSizer/test/steel_member/composite/test_composite_per_station.jl@8451627,
  StructuralSizer/test/steel_member/test_phi_v_provision.jl@8451627, StructuralSynthesizer/src/analyze/members/composite_context.jl@8451627,
  StructuralSynthesizer/src/analyze/members/utils.jl@8451627, StructuralSynthesizer/src/api/chat.jl@8451627,
  StructuralSynthesizer/src/api/deserialize.jl@8451627, StructuralSynthesizer/src/api/schema.jl@8451627,
  StructuralSynthesizer/src/core/size.jl@8451627, StructuralSynthesizer/test/analyze/test_composite_context.jl@8451627,
  Manifest.toml@8451627, StructuralSizer/Manifest.toml@8451627, StructuralSynthesizer/Manifest.toml@8451627,
  StructuralStudies/Manifest.toml@8451627, docs/Manifest.toml@8451627, external/Asap@8451627
session_id: sess-138f33cf
created_at: '2026-10-26T20:44:21.790346+00:00'
updated_at: '2026-10-26T20:44:21.790346+00:00'
---
Phases 3, 4, 4b, and 5 of the composite beam checker, in one commit because the same files carry all four.

Phase 3 designs the studs per candidate, allows partial composite action, and applies the ductility gates (AISC 360-22 §I8 and §I3.2d). Phase 4 requires the slab, stud, and shoring inputs and refuses composite action on the steel NLP path. Phase 4b sets the pour-stage unbraced length, reports Appendix 6 brace shear, and scales the pre-cure moment from a uniform dead-load field. Phase 5 uses Commentary Eq. C-F1-5 for hogging Cb, caps the rebar force with ΣQn_neg, and counts Asr at one section inside the effective width. A missing negative-region anchor strength stays on Chapter F.

Tests: 360 pass across the composite beam, per-station, and phi-v files. 169 pass in test_composite_context.jl.

Asap Project.toml now declares Random (submodule commit on the gitlink). The parent manifests list that dependency. The rest of the dirty Asap tree is not in this commit. Foundations, slabs, walls, seismic, and the binary-search depth fix are not in this commit.
