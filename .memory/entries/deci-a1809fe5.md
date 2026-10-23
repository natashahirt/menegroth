---
id: deci-a1809fe5
type: decision
project: menegroth
parent_id: todo-3b10ee83
title: 'Core foundation seam: rigid mat restrains the wall base; reactions go to the
  existing mat'
node_label: core on the mat
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9c9eabd9
created_at: '2026-10-23T14:22:59.210319+00:00'
updated_at: '2026-10-23T14:22:59.210319+00:00'
has_child_rationale: User confirmed the core is founded on the building mat, not a
  new wall-foundation phase
---
Confirmed by the user. A tower core is not given its own foundation type. It lands on the building mat (often a piled mat, thicker under the core). The same mat carries the columns. The core delivers axial load, shear, and overturning into that mat.

No Phase 7.2. Mats, piles, and overturning/uplift/sliding stay in the foundations plan (G1 deep foundations, G4 geotech and global stability).

The wall plan adds one seam, on the vertical slice after Phase 7:
- When the core bears on a mat idealized as rigid, restrain the wall base the way that mat restrains it. That fixity belongs to the foundation. The wall mesher still adds no supports of its own.
- Pass the wall base reactions (axial, shear, and moment) to the existing mat and pile design.

A flexible mat (soil and mat modeled together) stays a Phase G problem. Basement floors that brace the core on the way down to the mat wait until a building has a basement. Strip footings and grade beams are the low-rise case, not this tower core.
