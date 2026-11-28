---
id: deci-7fb63ce7
type: decision
project: menegroth
parent_id: menegroth
title: Wall overlap tests restored, and a pierced segment's shear records read its
  tuple
node_label: wall overlap test fixes
tags: walls,tests,special-shear,parking
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/wall_overlaps.jl@d37e484,
  StructuralSynthesizer/src/analyze/lateral/special_shear_stage.jl@d37e484, StructuralSynthesizer/test/core/test_wall_overlaps.jl@d37e484,
  StructuralSynthesizer/test/core/test_wall_data_model.jl@d37e484
session_id: sess-2b24c403
created_at: '2026-11-19T00:05:13.359843+00:00'
updated_at: '2026-11-19T00:05:13.359843+00:00'
---
Follow-up to deci-d3d395d8.

`park_wall_overlaps!` covered a beam with the infinite line through a wall, so a wall on one half of a grid line parked the beam on the other half, and a parallel beam read as collinear. Coverage is now the wall's own segment, and both beam ends must lie on the wall's line. Regression in test/core/test_wall_overlaps.jl.

`special_shear_records` read `.growns` and `.case`, but a pierced segment passes `(case, nothing, actions, nothing)` tuples (wall_opening_checks.jl). It now reads the first and third elements of a tuple. Both pierced-pier tests pass.

Fixtures that claim a grid beam as a wall lost the columns at the wall ends, which is what the rule does. The frame tests keep those columns with `park_wall_overlaps=false`: ordinary wall stage P-delta, the Y-weak office, the interactive row F case, and the row F resize fixture. The ELF self-weight check skips a parked column's zero section. The other wall fixtures keep the default and pass.

`gen_medium_office` no longer builds a story-0 beam grid, so the wall fixtures that claim a ground wall copy the story-1 beam plan and its faces down to grade. test/core/test_wall_data_model.jl is restored on that basis (86/86), with the parking check added to case A.
