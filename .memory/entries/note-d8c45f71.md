---
id: note-d8c45f71
type: note
project: menegroth
parent_id: plan-c8115994
title: Grade wall bases are held only at grid support vertices
node_label: Wall base unsupported between vertices
tags: walls,foundations,supports,core-office,boundary-condition
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/asap/asap/wall_mesh.jl@494a714, scripts/runners/core_office_geometry.jl@494a714
session_id: sess-daedc16a
created_at: '2026-11-07T03:41:12.856806+00:00'
updated_at: '2026-11-07T03:41:12.856806+00:00'
---
The wall mesh adds no supports (wall_mesh.jl docstring). A grade wall is held only at the frame support vertices it shares. gen_medium_office makes the `:support` group from its grid points only, so in the core office the grade vertices that core_office_geometry adds — the lobby splits at (8, 10.5) and (16, 10.5), and the tees at x = 10.4 and x = 12.8 — are not supports. Between support vertices the wall base nodes are free.

Effect on the gravity-only wall stage (core_office_wall_jump.jl):
- The ground-story lobby-wall segments (8–10.4, y = 10.5) and (12.8–16, y = 10.5) hang from the walls above. Top tension about 48–59 kN, bottom about −5 kN; the difference is close to the segment's factored self-weight.
- The 2.5 m west and east ground segments (x = 8 and x = 16, y = 8–10.5) and the north segment (8–10.4, y = 16) carry about 0.94–1.04 MN of in-plane shear under 1.2D + 1.6L. That is deep-beam transfer to the corner supports, and it fails §11.5.4.3 at 6 in (ratio up to 1.108).

Both failures come from the missing base restraint, not from wall thickness. deci-67cf61cb already says the core mat needs the base restrained first. The ordinary-wall-stage test offices also leave base nodes free between grid vertices.

After the jump fix (tension does not trigger; Table 11.3.1.1 and slenderness jump in one step; a refused scale does not walk an inch), the core office goes 4 in → 6 in in one remesh and stops. Unit tests 30/30; test_core_shaft.jl 1357/1357 with the roof-vertex seed.
