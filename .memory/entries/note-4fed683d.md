---
id: note-4fed683d
type: note
project: menegroth
parent_id: menegroth
title: 'C root cause CONFIRMED (b): composite search under-sizes group 7; upward ratchet
  (max 6) can''t climb to the feasible deep section'
node_label: 'C root cause CONFIRMED (b): composite search under'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c4a02984
created_at: '2026-11-28T05:33:04.961497+00:00'
updated_at: '2026-11-28T05:33:04.961497+00:00'
---
PROOF: scripts/runners/diag_steel_deck_deep.jl forces a deep-only custom_catalog (W21-W36, 52 sections) on the steel_deck beams. nova/e1c1 then FINISHES ('RESULT: design finished — group 7 solved with a deep section => (b)'). With the default catalog it throws 'No feasible sections for group 7'. So a deep composite section DOES develop group 7's 1731 kN·m / 5 m demand with the studs that fit; it is NOT a genuine stud/strength limit (not part of A).

MECHANISM (size_beams.jl ~855-957): composite sizing runs pass1 free search (optimistic/full-composite estimate) -> installs a too-shallow W18X35 on group 7 -> confirmation (lock pass, per-station real ~6-stud layout) REJECTS it (flexure_pos 3.64, shear_anchors Inf). Recovery: _composite_ratchet_floors (size_beams.jl:1218) floors every group at its installed section and re-searches, forcing strictly-heavier next pick, but is capped at COMPOSITE_RATCHET_MAX=6 (line 1208). Climbing from W18X35 by minimal weight increments cannot reach the feasible deep section within 6 searches, so _composite_ratchet_floors returns nothing and the 'No feasible sections for group 7' from optimize_discrete (over the _composite_lock_catalog = installed sections) is rethrown.

Underlying driver: the pass-1/solved search's composite capacity estimate is MORE optimistic than the per-station confirmation (likely envelope Mux and/or variable_inertia vs the stud-limited per-station field), so the search keeps picking sections the confirmation rejects.

FIX OPTIONS: (1) cheap/low-risk: raise COMPOSITE_RATCHET_MAX (cannot produce unsafe designs; each candidate still passes confirmation; only costs more MIP re-solves) — but the weight-wise climb may need many steps and might stall. (2) principled: reconcile the search capacity with the confirmation (use the per-station stud-limited capacity in the search) so the first solved search picks a confirmable section. (3) targeted: when the ratchet rejects, floor group 7 by DEPTH jump to the shallowest section whose per-station confirmation passes, instead of minimal weight increments. Each needs a ~20 min e1c1 validation run. Working WORKAROUND today: deep-only custom_catalog. Supersedes note-e876d482's open (a)/(b) question — answer is (b).
