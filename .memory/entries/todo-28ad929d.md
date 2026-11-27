---
id: todo-28ad929d
type: todo
project: menegroth
parent_id: plan-67a1e4f7
title: 'HELD: foundation-lateral Phase C/D (sliding, net-tension/uplift, ACI 336.2R
  20% column-load-variation rule, per-combination Winkler envelopes, ASCE 7-22 §12.13.4
  overturning) — gated on user-supplied soil inputs'
node_label: 'HELD: foundation-lateral Phase C/D (sliding, net-t'
tags: ''
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/README.md@19564e1
session_id: sess-f3306307
created_at: '2026-11-27T04:34:44.139004+00:00'
updated_at: '2026-11-27T04:34:44.139004+00:00'
---
Everything else in foundation-lateral sign-off item 4 is DONE (spread, column-strip, mat, grade-wall mat, grade-wall strip all evaluate every ASCE 7-22 §2.3/§2.4 combination incl. wind + seismic; see find-cea01648, note-df6c343c, chec-4d790ca0). What remains needs inputs the user chose to HOLD:

- Sliding resistance check (needs soil friction coefficient µ and/or passive pressure).
- Net-tension / uplift demand design (needs allowable net uplift, anchorage policy).
- ACI 336.2R 20% column-load-variation rule for combined/strip/mat.
- Per-combination flexible-section (Winkler) envelopes beyond current wiring.
- ASCE 7-22 §12.13.4 seismic overturning reduction + Ev=0 soil-interface permission.

Resume by collecting: µ (soil-concrete friction), passive pressure profile, allowable net uplift, and whether §12.13.4 reduction is permitted for the site. Then implement the sliding/uplift slice first (most safety-relevant).
