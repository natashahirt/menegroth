---
id: chec-8b9b7f71
type: checkpoint
project: menegroth
parent_id: chec-afc81f66
title: Asr is the steel at one section inside the effective width
node_label: Asr is the steel at one section inside the effecti
tags: composite,phase-5,asr,hogging,aisc
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ba6dfb3a
created_at: '2026-10-26T17:53:30.796486+00:00'
updated_at: '2026-10-26T17:53:30.796486+00:00'
---
Phase 5 Asr slice has landed and is not committed. Phase 5 is not closed.

asr_at_section counts longitudinal slab reinforcement at one negative section inside the beam effective width. AISC 360-22 §I3.2b(c), corpus aisc-360-22, PDF p. 170. Commentary p. 507 defines that area as the developed reinforcement within the effective width. The function counts area only. It does not check development length.

The caller names :ext_neg or :int_neg. The other location is not added. Each band carries y0, y1, strip_width, and a StripReinforcement list. As_provided at that location is spread uniformly across strip_width, because the strip result stores a total and a spacing, not bar coordinates. Only the overlap of the band with [-b_left, b_right] counts. Fysr is a required argument. Grade 60 is not assumed. Band edges are the caller's placement: the slab result does not store where a strip sits relative to the beam.

extract_parallel_Asr is unchanged. It still sums both strips and both negative locations and assumes Grade 60. It is not the path to use.

CompositeContext still holds one Asr for the section the caller checked. The building payload does not fill it from a FlatPlatePanelResult.

Tests: 187 pass in test_composite_beam.jl. A 4 in² column strip, 8 ft wide, with 2 ft of effective width on each side, returns 2 in² at the exterior section and does not add the interior 6 in² or the middle strip. Widening the right side 2 ft into the middle strip adds 0.5 in².
