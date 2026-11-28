---
id: deci-d89c9f06
type: decision
project: menegroth
parent_id: plan-1d645a44
title: Beam design shear is Asap Vy, the companion of My
node_label: Beam design shear is Asap Vy, the companion of My
tags: asap,beams,shear,detailing
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/demands.jl@a238a13, StructuralSynthesizer/src/workflow/capture_results.jl@a238a13,
  StructuralSynthesizer/test/analyze/test_member_group_demands.jl@a238a13
session_id: sess-767a62c0
created_at: '2026-11-07T05:01:58.974585+00:00'
updated_at: '2026-11-07T05:01:58.974585+00:00'
---
Asap pairs My with Vy and Mz with Vz. Default beam roll Ψ = π/2 puts local y vertical, so gravity on an X or Y beam is My and Vy; Vz is about zero. member_group_demands and _populate_beam_results! were reading Vz as Vu_strong / BeamDesignResult.Vu, so captured beam shear was ~0 and stirrups were sized on that. Both now take the My/Vy pair via _strong_weak_peaks (raw element.forces slots 2/8 and 6/12 on the no-load fallback). A one-element TributaryLoad check (X span and the global-Y special case) expects end shear wL/2 on the strong axis and ~0 on the weak axis. Office diagnostic before the fix: beam 1 My = 4.27 kN·m, Vy = 4.81 kN, Vz = 0, captured Vu = 0.
