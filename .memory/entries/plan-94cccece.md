---
id: plan-94cccece
type: plan
project: menegroth
parent_id: deci-2bb4ccf6
title: 'Slab visualization: sized section on the solver mid-plane'
node_label: 'Slab visualization: sized section on the solver mi'
tags: viewer,slab,deck,ribs,waffle,mid-plane,section
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-67f85c6c
created_at: '2026-11-06T23:23:30.046618+00:00'
updated_at: '2026-11-06T23:23:30.046618+00:00'
has_child_rationale: Visualization plan for solid, drop, rib, waffle, and deck floors
  on the solver mid-plane.
---
User asked to plan the slab picture on 2026-11-06, after choosing to stay on the solver mid-plane (deci-2bb4ccf6). No solver change. No office rerun.

Datum. The shell node is the story elevation and the mid-plane. Concrete of thickness h runs from h/2 below the node to h/2 above it. Analysis mode draws the plate that was meshed. Geometry mode draws the sized section centered on that same plane.

Scene, added only from values the design already stores. A solid slab adds nothing. A drop panel already has h_drop and the two plan sizes on the slab drawing. A composite deck adds one profile per slab: hr, rib_top, rib_bottom, pitch, fill_depth, total_depth, gage thickness, and a rib direction in the slab plane taken from the stored rib angle (from_slab uses the slab span axis; perpendicular and parallel are the beam option). shell_thickness stays total_depth, the plate the mesh used. A concrete rib adds nothing to the slab beyond its topping thickness; the stem is the beam section below hf. Element eccentricity is not in the scene today. The packet gains the solved frame eccentricity, the same four numbers Asap stores, before a stem may leave the node line. A missing profile, direction, spacing, or eccentricity stays null and the viewer says so. No stand-in flute, spacing, or offset.

Detail sheet, local section, same hatch and dimensions as the current sheets.
- Solid: the rectangle already drawn, span by thickness.
- Drop: a step, h beside h + h_drop, over the stored drop sizes.
- Ribs and waffle: the slab sheet is the topping between stems. Stem width bw and depth h − hf come from the rib's T-section. Spacing is the distance between those members. The beam sheet keeps that T, flange included, so the flange is not drawn again as a second slab. If the slab thickness and hf disagree, both values are shown and no blended section is built.
- Deck: one pitch. Hatched fill above the deck plus the trapezoid (hr, rib_top, rib_bottom). The steel sheet is a stroke of the stored gage. Dimensions are those stored widths and depths.

Building.
- Solid and drop: the centered extrusion already built. Drop triangles keep their own thickness.
- Deck, geometry mode only: the profile repeated across the slab outline, the whole depth centered on the node. Analysis mode keeps the flat plate of total_depth.
- Ribs: the shell is the topping, centered. The stem is the beam solid. It is shifted to the soffit only when the solved eccentricity is the web-below-slab offset. A zero eccentricity stays on the node line, which is the model that was solved.

Order. (1) Write the deck profile, rib direction, and frame eccentricity into the scene from the design record, with tests that a solid slab gains none of them. (2) Detail sections. (3) Geometry-mode deck solid and eccentricity-aware stem. Analysis meshes stay as they are.

Out of scope: moving the mid-plane, meshing flutes into the solve, a second rib solid on top of a member that already has a section, 3D rebar, and an office rerun.
