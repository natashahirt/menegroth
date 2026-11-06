---
id: deci-b196a46b
type: decision
project: menegroth
parent_id: plan-9768ec38
title: Flexible diaphragm gives walls a tributary share and still refuses braces
node_label: Struts stay refused
tags: diaphragm,walls,struts,flexible
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0540be20
created_at: '2026-11-06T02:55:47.933522+00:00'
updated_at: '2026-11-06T02:55:47.933522+00:00'
---
On a flexible diaphragm the story force is split by the floor area each vertical element carries. Walls already have tributary_cell_areas, so the flexible-diaphragm slice gives each wall its share and replaces the stop that currently fires because walls are present.

A diagonal brace (Strut) has no floor tributary. Its force comes from the frame it braces. This slice still throws when any strut is present, the same as _require_flexible_diaphragm_tributaries! does today. Do not assign a brace a column area, a zero share, or a guessed fraction.

Tracing the diaphragm force into a braced frame and then into the diagonal is a separate load path, outside the wall-support plan. The core office uses a rigid diaphragm, so this stop does not affect it.
