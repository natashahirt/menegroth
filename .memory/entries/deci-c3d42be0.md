---
id: deci-c3d42be0
type: decision
project: menegroth
parent_id: deci-d8524cd1
title: Composite shell stiffness uses the shell's own sagging regions; steel still
  carries the shell hogging
node_label: Composite shell stiffness uses the shell's own sag
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/composite/stiffness.jl@0c63d90, StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@0c63d90,
  StructuralSynthesizer/src/analyze/slabs/slabs/story_shell.jl@0c63d90, StructuralSynthesizer/src/analyze/slabs/slabs/story_shell_service.jl@0c63d90,
  StructuralSynthesizer/test/analyze/test_story_shell_beams.jl@0c63d90
session_id: sess-d344815e
created_at: '2026-11-04T23:27:53.043976+00:00'
updated_at: '2026-11-04T23:27:53.043976+00:00'
invalidates: deci-3dbd3448
---
Reversed the simple-span sizing basis. Slab bars are sized from the slab's own shell moments, which do not include the beam's hogging, so dropping that hogging from the beam leaves it unreinforced. A steel beam keeps the shell Mu_neg (AISC Chapter F, bottom flange in compression) and is checked on both the frame and shell moment fields.

The region warning came from placing I_LB / I_neg on the frame model's sagging regions. The shell now places the recorded profile on its own regions from the previous pass (`composite_regions`): the combination with the greatest sagging peak, each region taking the smallest overlapping frame-region anchor strength (`composite_profile_on_regions`). The loop stops when sections hold and every beam's region boundaries move by at most region_tol (0.05). `region_mismatch` is that last movement, not the frame-vs-shell gap.

2x2 office, 40 ft bays, composite steel: converged in 2 passes, region_mismatch 0.0 on all 12 beams. Mu_neg is unchanged (W16X26 beams 12-19 kN·m, ratios 0.66-0.83) because that hogging is on combinations other than the governing sagging field, whose regions already matched the frame model. Cracked service shell still stops at 6 iterations (service_converged=false); separate from this change.

Tests: test_story_shell_beams.jl 151/151.
