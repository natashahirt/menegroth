---
id: todo-7dfc3edf
type: todo
project: menegroth
parent_id: deci-77a5062f
title: Real §I3.1b construction-stage check for composite steel beams
node_label: Real §I3.1b construction-stage check for composite
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/checker.jl@bcfe7d3
session_id: sess-ecae06c6
created_at: '2026-10-25T13:33:42.190426+00:00'
updated_at: '2026-10-25T13:33:42.190426+00:00'
---
Deferred from the composite production-gaps plan (Phase 2).

Today: unshored composite beams check the bare steel section against the FINAL factored envelope max(|Mux|, Mux_pos, Mux_neg) at Lb = member length, Cb = 1. ENGINEERING JUDGMENT proxy, not the §I3.1b demand.

Why deferring is acceptable for now: composite is opt-in (default false). Lb = L and Cb = 1 are conservative for bracing. With the SDI C-2017 deck-form values as the yardstick (Eq. 2.4.4: 1.6 wet concrete + 1.2 deck + 1.4 x 20 psf), final minus pre-cure per unit area is about 1.2 SDL + 1.6 LL - 0.4 w_wet - 28 psf. Typical floors (LL ~50 psf) leave the final envelope governing by ~50 psf.

Where the proxy can be unconservative: roofs and other low-live-load floors, heavy construction loads (bulk concrete placement, power screeds; SDI suggests >= 50 psf), and continuous members whose final moments are reduced by continuity that does not exist during placement.

To do:
1. Separate pre-cure load case on the bare-steel model: wet concrete + deck + steel self-weight through the same tributary polygons -> M_pre(s), V_pre.
2. Construction live load and load factors as inputs. Decide whether the SDI C-2017 §2.4 values are offered as a labeled ENGINEERING JUDGMENT preset (they are written for the deck as a form, not the beam).
3. Add ASCE/SEI 37 to the corpus (360-22 Commentary §I3.1b, PDF p. 501, points to it) and use its combinations.
4. Chapter F flexure at the construction unbraced length (input tied to slab type: attached deck braces, removable forms may not) and Chapter G shear (existing check_construction).
5. shored flag: skip the steel-alone check; unshored deflection puts pre-cure dead load on steel Ix.
6. Label the current envelope proxy as engineering judgment in explain_feasibility until this lands.
