---
id: find-be4cf63c
type: finding
project: menegroth
parent_id: plan-63d83cc7
title: 'STOP: the overnight program is almost entirely ALREADY DONE on integration/2026-11-18
  (sign-off queue plan-9633da9d merged). Sizing-map README is stale (describes pre-merge
  main).'
node_label: Overnight program already done; map README stale
tags: stale-map,already-done,sign-off,cladding,steel-cm,mat-336,foundations,scope
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a867d39a
created_at: '2026-11-26T16:43:03.653250+00:00'
updated_at: '2026-11-26T16:43:03.653250+00:00'
has_child_rationale: Verified every proposed slice against current code; nearly all
  are implemented. Avoids re-implementing safety-critical done work.
---
Verified each proposed overnight slice against the CURRENT integration/2026-11-18 code (not the stale sizing-map README, which describes the pre-merge `main` tree per docs/sizing-map/audit-2026-11-18/). The row-f-nlp sign-off queue (plan-9633da9d) is merged, so:

ALREADY DONE on this branch:
- WP 2.5 BEAMS: beams.jl:176 wraps `_sizing_material`→ReinforcedConcreteMaterial; rebar in obj_coeffs. (map #11 stale)
- STEEL Cm: size_columns.jl:219-222 passes signed M1x/M2x/M1y/M2y from demands (MemberDemand carries them via _fem_to_aci_endmoments); Cm=0.6−0.4(M1/M2) used. AISC 360-16 App.8 §8.2.1. (sign-off #3 stale)
- CLADDING dead load: wall_SDL → :cladding line loads in gravity, unfactored dead, service foundation, W and Px (_deposit_cladding!). ASCE 7-22 §3.1.1/§12.7.2. (note-e9a2f8ae, chec-dbb027b0, deci-3d324e9c) (sign-off #1 stale)
- LATERAL→FOUNDATIONS (spread): isolated spread footings take wind+seismic via design_ordinary_walls! foundation_lateral; each ASCE 7-22 §2.3/§2.4 combo checked. (sign-off #4 done for spread)
- MAT rigid strip statics: mat_footing.jl cites ACI 336.2R §6.1.2 Steps 3-4 + §5.2 Kr gate; implemented. (sign-off #5 stale)
- Column shrink-and-verify: already measured (expe-6dcbaa95). Column/foundation covering-MILP: in flight (plan-43330edb one-owner, plan-93430266 D-series, foundation Phase D).

GENUINELY OPEN (narrow):
1. STRIP & MAT footings still collapse load combinations into one demand (_lateral_column_demand: largest moment + separate max service P); only SPREAD footings got per-combination. [note-e9a2f8ae]
2. GRADE-WALL nodes still read the gravity reaction only (lateral never reaches grade walls).
3. FEA flat-plate remesh speedup (big FEM re-architecture; separate supervised session).
4. WP 2.5 walls/footings carbon-in-objective — but walls pick thinnest-passing (not a carbon MIP), so likely N/A for walls; footings are hot.

CONCLUSION: Running the overnight program as conceived would RE-IMPLEMENT already-merged safety-critical work — wasteful and conflict-prone. The sizing-map README.md should be de-staled (its sign-off items 1,3,4,5 and rank #11 are resolved). Recommend: (a) patch the stale map, (b) tackle only the two narrow real gaps (strip/mat per-combination demand; grade-wall lateral) with the user, or (c) the FEA remesh in a dedicated session. Did NOT write code.
