---
id: deci-b44294ba
type: decision
project: menegroth
parent_id: plan-3986c866
title: A story is one shell, and a concrete web hangs from its centroid
node_label: A story is one shell, and a concrete web hangs fro
tags: slabs,shell,beams,centroid,fea
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/sections/_sections.jl@59e0a7a, StructuralSizer/src/members/sections/concrete/rc_tbeam_section.jl@59e0a7a,
  StructuralSizer/src/members/sections/concrete/pixelframe_section.jl@59e0a7a, StructuralSizer/src/slabs/codes/concrete/panel_shell_beams.jl@59e0a7a,
  StructuralSynthesizer/src/analyze/slabs/slabs/story_shell.jl@59e0a7a
session_id: sess-632d8e4f
created_at: '2026-11-03T17:43:53.745253+00:00'
updated_at: '2026-11-03T17:43:53.745253+00:00'
has_child_rationale: The story shell is the next piece of the beams-in-shell plan,
  and the centroid is what sets the concrete offset.
---
Implemented 2026-11-03. One shell per story, callable as analyze_story_shell. Neighbouring panels share nodes. Each triangle takes the thickness of the panel that contains its centroid. Beams are frames on those nodes.

centroid_from_top is half the depth for a symmetric section, the gross T centroid for an RCTBeamSection, and the polygon centroid for a PixelFrameSection. soffit_to_centroid is that distance for a section that is already the web, and half the stem for a T-beam, because the flange is the shell.

A concrete frame uses the gross web, not the 0.35 cracked factor in to_asap_section. Its centroid is offset below the slab mid-plane on local e_f2 (negative). Where two slabs of different thickness meet, the offset uses the larger thickness. Steel sits on the shell nodes. With no studs it is the bare section. composite_service supplies I_service, b_eff, and n, and the frame inertia is that service inertia minus the slab bending. section_at(beam, station) can give each piece of a beam its own section; a fish-bellied beam stays a later project.

The load is total_factored_pressure of each cell plus beam self-weight. Shell beam forces are stored on design_details.shell_beam_forces. Tributary beam design is not replaced. The story is analyzed only when every beam had a section and the shell solved. design_building and design_floors! do not call this yet, so an unshelled panel still reads not_analyzed.

Tests: StructuralSizer slabs/test_story_shell.jl 33/33. StructuralSynthesizer analyze/test_story_shell.jl 19/19.
