---
id: note-9fb7ddd9
type: note
project: menegroth
parent_id: expe-18356ac1
title: Full-side walls flange and special shear refuses Mpr
node_label: Full-side walls flange and special shear refuses M
tags: walls,flange,18.10.3,layout
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ecc28642
created_at: '2026-11-14T05:36:43.249876+00:00'
updated_at: '2026-11-14T05:36:43.249876+00:00'
has_child_rationale: The symmetric-wall trial and why it cannot replace the corner
  layout.
---
scripts/runners/sdc_symmetric_piers.jl replaces the four opposite-corner piers with both bays on every face (40 wall edges). Category D, row A1, SDS 1.0, same office otherwise. Design threw at 660 s, before a thickness:

special shear: wall 1 is flanged and hwcs/ℓw > 1.5. Table 18.10.3.1.2 needs Mpr, and the flange bars are not in the section, so Mpr would be low and Ωv unconservative.

Opposite faces that meet at the corners are flanges. The corner layout leaves the ends unshared, so the piers stay rectangular and the 30 in result stands. A two-bay side has no grid edge at mid-face, so a centered pair that does not meet cannot be placed on this grid.
