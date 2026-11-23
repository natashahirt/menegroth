---
id: note-4f7a4ec6
type: note
project: menegroth
parent_id: chec-84bfdaa7
title: 'Net-section tension (§D2 rupture) in axial sizer: already by-design deferred
  to connection design via Ae_ratio=0.75'
node_label: 'Net-section tension (§D2 rupture) in axial sizer: '
tags: axial-member,tension,chapter-d,rupture,net-section,resolved
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ddbef912
created_at: '2026-11-23T18:13:09.617676+00:00'
updated_at: '2026-11-23T18:13:09.617676+00:00'
has_child_rationale: Resolves the second open question from the step-3 agent using
  the existing tension.jl contract
---
The step-3 agent asked whether connection-dependent net-section effects are out of scope for the member sizer. They ARE, by existing design — this is already handled, not an open gap:

`StructuralSizer/src/members/codes/aisc/generic/tension.jl` `get_Pn_tension`/`get_ϕPn_tension` size §D2 rupture with `Ae_ratio=0.75` (Ae/Ag), a documented conservative default (its ENGINEERING JUDGMENT note: An/U depend on bolt-hole pattern + shear-lag Table D3.1, unknown before connection design; `Ae/Ag=0.75` is conservative for typical W connections where U≈0.85–0.90, An/Ag≈0.85–0.90 → Ae/Ag≈0.72–0.81; members are usually yield-controlled in this regime; 'must be overridden once connection geometry is fixed'). `size_axial_members` inherits this unchanged through `size_columns`.

So: net area `An` and shear-lag `U` remain the responsibility of a later connection-design layer, which re-checks §D2 rupture with the actual geometry. No change to the member sizer needed. If/when the connection layer lands, give the sizer a way to pass a per-member `Ae_ratio` override instead of the 0.75 default.
