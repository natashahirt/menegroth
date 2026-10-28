---
id: note-5d07a70a
type: note
project: menegroth
parent_id: plan-35f67705
title: Rib-network frame exists; the slab panel is undesigned
node_label: Frame in, slab out
tags: ribs,tributary,t-beam,slab,infrastructure
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1eab7bed
created_at: '2026-10-28T22:33:00.076340+00:00'
updated_at: '2026-10-28T22:33:00.076340+00:00'
has_child_rationale: User asked to record the split between the existing beam network
  and the missing slab design.
---
Confirmed 2026-10-28. An arbitrary concrete rib network can already use the shared skeleton: faces from the beam graph, tributary width along each beam (exact per-cell path for irregular panels; joist-to-girder strip only for a true rectangle), frame analysis, concrete T-beams when include_flange is on, and steel composite beams with a solid slab or a deck.

The slab panel is not designed for any floor in the concrete family. One-way and two-way only set a minimum thickness, and the design pass leaves it. Nothing classifies a general panel as one-way or two-way and then designs its bars, shear, and deflection. Parallel ribs and waffle reuse this skeleton; they add the slab design and the code limits for a regular joist grid. A courtyard is still poured, because every closed loop becomes a panel.

Next implementation is the steel deck, not this slab: beam deflection with station-varying composite stiffness.
