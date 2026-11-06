---
id: deci-e9ea33af
type: decision
project: menegroth
parent_id: plan-35f67705
title: Beamless two-way becomes a flat plate; a broken beam grid throws
node_label: Two-way support classification
tags: two-way,flat-plate,walls,beams,aci-318-11,initialization
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e9baeba5
created_at: '2026-11-06T04:05:25.019545+00:00'
updated_at: '2026-11-06T04:05:25.019545+00:00'
has_child_rationale: Closes the open question in deci-f3a4d0fd about a beamless two-way
  floor.
---
User decision 2026-11-05, after the recommendation was accepted.

For a `:two_way` slab, classify each panel from the skeleton edge groups before sizing:

- No beams, supports are columns, or columns and walls (a core): design as `:flat_plate` and warn. ACI 318-11 §9.5.3.1 (page 133) sends a slab with no interior beams to §9.5.3.2 / Table 9.5(c). A wall is a line support the flat-plate path already designs (moment, one-way shear, bar development). It does not create a beam-supported slab. Thickness at a wall edge stays the exterior-without-edge-beams column, ℓn/30, because Table 9.5(c) footnote § (page 134) reserves the thinner column for an edge beam with αf ≥ 0.8 and does not name a wall.
- A panel whose every edge is a wall, with no column in it: stay `:two_way`. It spans wall to wall. §9.5.3.3(c) (page 134) applies because a wall is stiffer than αfm = 2, so the thickness is Eq. (9-13), not less than 3.5 in. Do not invent an αf; select case (c) by classification.
- Beams exist, but an interior edge between two panels has neither a beam nor a wall: throw. A wall fills that edge.
- Beams exist and a building-edge beam is missing: allow it, and make the slab at least 10% thicker per §9.5.3.3(d) (page 134). A wall on that edge fills it, so the increase is not applied. Reading the missing beam as a failure of the αf ≥ 0.8 alternative, rather than as leaving §9.5.3.3 entirely, is the agreed application of (d).
- A beamless `:one_way` slab still throws. One-way reinforcement on columns alone is not redesigned as a flat plate.

Still open, not this change: rib flange from the topping (§8.12.2), topping span equal to the rib spacing, `uniform_geometry` on ConcreteBeamOptions, and standard pan catalogs.
