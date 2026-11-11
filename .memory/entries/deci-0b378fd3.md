---
id: deci-0b378fd3
type: decision
project: menegroth
parent_id: plan-2dcf41ac
title: Story shell wired to walls, and a grillage frame path for rib networks
node_label: Story shell wired to walls, and a grillage frame p
tags: story-shell,walls,grillage,waffle,ribs,tributary,efficiency
status: active
open_threads: 3
success: 'null'
files: ''
session_id: sess-f5dfe580
created_at: '2026-11-07T15:49:55.312023+00:00'
updated_at: '2026-11-08T02:42:50.479344+00:00'
---
2026-11-07. Additions to plan-2dcf41ac, with the user's choices.

Story shell with walls (after the SPD fix): mesh the supporting_wall_segments as constraint lines; restrain wall nodes as the flat-plate shell does (_hold_slab_on_walls!, ACI 318-11 R13.6.3.3: uz and rotation about the wall axis fixed), with the rotation taken about a skewed wall's own axis; support only along solid piers (an opening reaching the slab soffit breaks the line); sum shell reactions per wall into wall gravity demand, taking the larger of tributary and shell (same rule as beams); remove the wall exclusion in _story_shell_design_levels. Tests: one-way slab between two walls vs hand fixed-end and midspan moments; wall plus columns reaction equilibrium.

Grillage frame path for ribs (no shell FEA), with the rib geometry: ACI 318-19 §8.2.1 (aci-318-19 p.101) equilibrium + compatibility. Rib network graph (closed form for straight and isoparametric grids; planar arrangement only for free-form). Panel load to ribs by the isotropic straight skeleton (get_tributary_polygons_isotropic) as Asap TributaryLoad (piecewise linear, exact FEF), cached per congruent panel shape, rectangles closed form. Curved ribs cut by sagitta tolerance n = ceil(L / sqrt(8 R delta)). Ribs continuous through crossings; columns as the story shell's rotational springs; solid heads as stiff regions. One factorization per pass, patterns as extra RHS. Topping per panel: the user wants any spanning method or deck selectable (one-way, two-way, deck), not a fixed rule. Story shell and grillage share the rib graph and sections; analysis chosen per floor.

Order: (1) story-shell convergence diagnosis, (2) SPD warning, (3) story shell with walls, (4) rib geometry + grillage frame path, (5) placed-bar takeoff, (6) rib API and NLP ribs, (7) rib deflection without a story shell.
