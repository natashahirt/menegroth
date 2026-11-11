---
id: plan-b45b0d7f
type: plan
project: menegroth
parent_id: plan-b0095736
title: Ordinary-wall stage in design_building for one isolated pier
node_label: ordinary wall stage
tags: phase7,walls,design-pipeline
status: active
open_threads: 10
success: 'null'
files: ''
session_id: sess-9027b67d
created_at: '2026-10-29T20:57:41.712302+00:00'
updated_at: '2026-11-05T20:20:57.141134+00:00'
---
Add design_ordinary_walls! and run it from design_building only when DesignParameters.lateral is set. A gravity-only building (lateral nothing) keeps the two-stage pipeline and writes no wall checks.

The stage checks the given wall section (thickness, length, ρl, ρt). It does not resize, does not invent a bar catalog, and does not scale shell E. Cracked stiffness is the caller's statement, checked by the existing seismic gate.

Demands come from the unified frame-shell model: gravity basic cases, Chapter 27 wind, and ELF strength cases, combined once per group (gravity, each wind case, each QE case) rather than a full cartesian product. Assignment must be BuildingUnit. Joined assemblies stay refused. IsolatedWallShare and OutriggerSystem throw. Missing wall_inputs throws. SDC D/E/F deformation compatibility stays refused by system_checks.

OrdinaryWallInputs holds the code numbers and provision statements with no assumed pressures, R, or ρ. The result is stored on BuildingStructure.ordinary_wall_result and copied onto BuildingDesign.walls and seismic_story_drift. Wall and drift failures enter the design summary.
