---
id: deci-f3a4d0fd
type: decision
project: menegroth
parent_id: plan-35f67705
title: Floor type sets reinforcement direction; framing sets the slab's supports
node_label: Slab spans to finest framing
tags: ribs,joists,one-way,two-way,slab,framing,uniform_geometry
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7aebb121
created_at: '2026-11-06T03:38:23.922783+00:00'
updated_at: '2026-11-06T03:38:23.922783+00:00'
has_child_rationale: 'User''s model of rib floors (2026-11-05): ribs are extra bearing
  lines under a one-way or two-way slab, not a separate system.'
---
User decision 2026-11-05. `:one_way` and `:two_way` describe the slab's reinforcement directions. Framing decides where the slab bears: girders give today's beam-supported slabs, and a joist or rib level makes the slab span between ribs instead of between girders. So a rib floor is a one-way or two-way slab whose supports are the finest framing level, and the slab result is the topping between ribs.

Consequences to build:
- Slab span comes from the finest framing level, not the cell edges. The first pass can use rib center spacing and recheck with the clear spacing after the ribs are sized.
- Concrete rib flange per ACI 318-11 §8.12.2 (aci-318-11, PDF page 119), with the topping thickness and the clear distance to the next rib, not the girder slab.
- A rib stem list filtered by §8.13.2; each rib picks its own stem and bars by default, without the MIP.
- `uniform_geometry::Bool = false` on ConcreteBeamOptions: one stem width and depth per sizing pass, bars per member. Usable by girders too. A comparison runner reports per-member, uniform geometry, and uniform section (`n_max_sections = 1`).
- Rib spacing: the user's value if given, otherwise chosen from a candidate list. The corpus has only the CRSI wide-module pans (53 and 66 in wide, 14 to 24 in deep; crsi-economical-rc-2016, PDF page 15), which exceed the 30 in clear limit of §8.13.3. Standard pans of 30 in or less need a source before they are listed.

Open: the user suggested a `:one_way` or `:two_way` floor with no beams could default to a flat slab with that reinforcement axis. A slab bearing only on columns acts two-way, so one-way bars alone are not a valid design there; this needs a decision before it changes.

Trial 2026-11-05 (scripts/runners/run_concrete_rib_trial.jl): 2×2 bays, one story, 30 in ribs. design_building finished with 20 ribs and 24 girders. Ribs fell back to rectangular sizing (no adjacent slab), and the girder flange was the 6.5 in one-way slab across the bay.
