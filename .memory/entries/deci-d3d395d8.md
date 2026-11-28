---
id: deci-d3d395d8
type: decision
project: menegroth
parent_id: menegroth
title: Columns and beams inside a wall are parked in :absent by default
node_label: park wall overlaps
tags: walls,columns,beams,absent,initialize
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-bdbdfe08
created_at: '2026-11-18T20:17:22.519265+00:00'
updated_at: '2026-11-18T20:17:22.519265+00:00'
---
`park_wall_overlaps!(skel)` (StructuralSynthesizer/src/analyze/members/members/wall_overlaps.jl) runs in `initialize!` after faces and the geometry cache, before cells and members. Switch: `initialize!(...; park_wall_overlaps=true)` and `DesignParameters.park_wall_overlaps = true`; false keeps them.

Rules (user choices, 2026-11-18):
- Column: plan point within 1e-3 m of a wall centerline segment (ends and middle) and its height overlaps the wall's [z, z+pier height] by more than 1e-3 m. A column that only touches the wall's base or top stays.
- Beam (any level edge outside :columns/:braces/:walls/:absent): collinear walls whose plan lines cover its whole length, at an elevation from the wall's base line through its top line inclusive. Top line included: the slab bears on the wall (the roof beam over the top pier is parked). Partial coverage stays a beam.
- A shattered chain is parked only when every edge qualifies.

Tests: StructuralSynthesizer/test/core/test_wall_overlaps.jl (18 pass). Found pre-existing: test/core/test_wall_data_model.jl fixtures assume story-0 beams that gen_medium_office no longer makes (8 errors, 3 fails, independent of this change).
