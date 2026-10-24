---
id: deci-009b31dd
type: decision
project: menegroth
parent_id: deci-a764434e
title: Concrete T-beams use the steel per-station flange width
node_label: ACI per-station bf
tags: composite,aci,t-beam,effective-width
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aci/beams/t_flexure.jl@00befe9, StructuralSizer/src/StructuralSizer.jl@00befe9,
  StructuralSizer/test/runtests.jl@00befe9, StructuralSizer/test/concrete_beam/test_tbeam_per_station.jl@00befe9,
  StructuralSynthesizer/src/analyze/members/utils.jl@00befe9
session_id: sess-2a142693
created_at: '2026-10-24T00:01:32.995428+00:00'
updated_at: '2026-10-24T00:01:32.995428+00:00'
has_child_rationale: User asked concrete T-beams to follow the steel per-station tributary
  approach
---
ACI 318-11 §8.12 T-beam flange width now uses the same per-side tributary profiles and governing-station search as the steel composite check. For each beam, bf is the width at the sagging station that maximizes M⁺/bf (flange_width_at_station / governing_flange_width). Constant per-side extent d = sw/2 reduces to effective_flange_width. A group shares one section, so the group bf is the narrowest of those governing widths. No sagging moment returns the midspan width. Caps stay the house §8.12.2 / §8.12.3 mapping (per-side ln/8 and 8·hf, or ln/12 and 6·hf when the other side is absent). d(s) remains the stand-in for half the clear distance to the next web; bw/2 is not subtracted. The moment-weighted tributary average is not used.
