---
id: deci-d393c2b8
type: decision
project: menegroth
parent_id: deci-63970067
title: Foundations show their own analysis in the viewer; base springs are a recorded
  future option
node_label: Foundation fields in viewer
tags: foundations,viewer,scene,settlement,soil-pressure,ssi
status: active
open_threads: 0
success: 'null'
files: viewer/src/detail-overlay.ts@c42db04, StructuralSynthesizer/src/scene/build.jl@c42db04,
  StructuralSizer/src/foundations/types.jl@c42db04
session_id: sess-5d95b467
created_at: '2026-11-07T21:46:25.250864+00:00'
updated_at: '2026-11-07T21:46:25.250864+00:00'
has_child_rationale: User asked to align foundation output with the rest of the analysis
  display.
---
Each foundation method returns what it actually computed, the scene stores it, and the viewer draws it in the existing modes:
- Deflection = settlement. Winkler mat/strip and Shukla: their computed field. Rigid footing: the plane q/ks, only when Soil.ks is given. When ks is missing the view says settlement was not computed because ks is not given (user ruling).
- Stress = bearing pressure against qa (rigid: the linear ACI 336.2R distribution; Winkler: ks·w). Its integral must equal the load, so the picture also checks equilibrium.
- Internal loads = moment and shear at the code critical sections; rigid mats show strip moment diagrams, never an invented contour field.

Today the footing deflection overlay colors the box by its support node displacement, which is zero because grade bases are fixed (deci-531636c3). That picture is replaced.

Base springs (soil-structure interaction feeding settlement back into the building model) are NOT part of this redesign. User ruling: record as a future option; bases stay fixed.

Sequencing: after the load-balance check, mat hand check, and mat dowels; built alongside the development-length limit state, which reopens every foundation designer.
