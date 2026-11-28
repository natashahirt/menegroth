---
id: chec-1e22f19c
type: checkpoint
project: menegroth
parent_id: plan-a7ebaacc
title: Story rib depth, rib-line owner, cracked story deflection, and depth screen
  implemented
node_label: Ribbed floors implemented
tags: waffle,joists,rib-depth,deflection,aci-318-11,carbon
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/optimize/api/rib_sets.jl@e7bce87, StructuralSynthesizer/src/analyze/members/members/rib_story.jl@e7bce87,
  StructuralSynthesizer/src/analyze/members/members/rib_deflection.jl@e7bce87, StructuralSynthesizer/src/workflow/member_iteration.jl@e7bce87,
  docs/sizing-map/ribbed-floors.md@e7bce87
session_id: sess-9eaae3c6
created_at: '2026-11-19T21:32:57.575521+00:00'
updated_at: '2026-11-19T21:32:57.575521+00:00'
has_child_rationale: Implements deci-38eacad7
---
Implements deci-38eacad7 (docs/sizing-map/ribbed-floors.md).

Done:
- StructuralSizer `size_rib_set` (rib_sets.jl): one web + bottom bar size per rib set at a fixed depth, per-piece bar counts, top bars via required_top_steel, carbon objective; `rib_set_webs` filters ACI 318-11 §8.13.2/§8.13.3. `service_inertia` gives Eq. (9-8)/(9-9) Ie per element by the sign of its larger service moment. Tests: test_rib_sets.jl (21 pass).
- StructuralSynthesizer: `FramingLevel.rib_stem`/`rib_report`; `DesignParameters.rib_stem`, `rib_stems`, `rib_deflection_limit` (:sensitive l/480 default, :total l/240); `size_rib_lines!` owns story rib groups (bypasses the catalog MIP); `conform_rib_lines!`, `raise_head_face_ribs!`, `rib_depth_step` retired.
- `story_rib_deflection` (rib_deflection.jl): D, D+psiL, D+L service re-solves of the building frame with Ie ratcheting down from Ig (5 percent, 4 passes); sag from the bilinear/planar surface through the moving column tops of each Delaunay column bay (rectangles merged); l = longest c/c side; immediate live l/360, long-term lambda (xi=2, rho'=0). Tests: test_rib_deflection.jl; test_rib_grillage.jl still passes (360 total).
- `screen_rib_stems!` before and after each member loop (max 3 screens): least-carbon strength-passing stem whose deflection passes; carbon includes head concrete below topping. `report_rib_deflection!` on final sections. Runner summary prints stem, sets, deflection ratios, screen.

Next: grid/x1y1 dense waffle end-to-end run was in progress at commit time (first run of the screen path); review its stem choice, deflection ratios, and runtime. Shell-story (one-way story shell) joist levels are not screened yet.
