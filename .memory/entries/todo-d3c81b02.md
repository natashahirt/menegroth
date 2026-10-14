---
id: todo-d3c81b02
type: todo
project: menegroth
parent_id: plan-b2670c25
title: 'Pre-ribbed-floor cleanup: fix potentially unconservative leftovers'
node_label: 'Pre-ribbed-floor cleanup: fix potentially unconser'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-df7830b3
created_at: '2026-10-14T18:38:42.112209+00:00'
updated_at: '2026-10-14T18:38:42.112209+00:00'
---
The user approved fixing these before ribbed-floor work, after a verify-first pass confirms each is still present:
1. ACI 318-11 §13.7.6.3 0.75L partial-pattern live load is never generated (only full + checkerboard).
2. Edge-column punching uses uniaxial max(|Mux|,|Muy|); interior and corner add both axes.
3. _asap_signed_My_envelopes: hogging/sagging sign is only calibrated for horizontal members; sloped rafters (Psi = 3pi/2) swap sag/hog.
4. No tension + hogging AISC 360-16 §H1.2 check; size_beams/columns never forward Pu_t.
5. (unverified) Strip-footing Step 5 uses one c_across_max for every band, which under-sizes Mu at smaller columns.
6. (unverified) Rolled web Cv1 may be missing an AISC 360-16 §G2.1(b) branch. Check the corpus first: Eq. G2-5 is the kv equation there, so the finding may be wrong.
