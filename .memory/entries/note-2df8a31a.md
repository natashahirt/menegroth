---
id: note-2df8a31a
type: note
project: menegroth
parent_id: plan-e442a545
title: Stud positions are placed and tested
node_label: Stud placement landed
tags: composite,studs,tested
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0bd9f32f
created_at: '2026-11-06T22:37:46.437830+00:00'
updated_at: '2026-11-06T22:37:46.437830+00:00'
has_child_rationale: The placement plan is implemented and the composite beam and
  synthesizer tests passed.
---
place_shear_anchors writes stations and flange offsets for each sagging region's design_shear_anchors layout. They are stored on the composite mesh and serialized as stud_positions and stud_diameter on the frame element. Stud mass and carbon join the beam steel takeoff.

Verified: StructuralSizer steel_member/composite/test_composite_beam.jl, 337 passed. StructuralSynthesizer core/test_section_rebar_serialization.jl and analyze/test_composite_context.jl, 294 passed, fresh process.
