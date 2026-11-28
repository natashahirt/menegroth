---
id: note-a5b7e562
type: note
project: menegroth
parent_id: plan-04899673
title: 'Core office checks still open: wall-load ratio, column steel under 1%, service
  SPD warning'
node_label: 'Core office checks still open: wall-load ratio, co'
tags: core-office,foundations,columns,spd,aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-bcfb21d9
created_at: '2026-11-08T01:59:23.614761+00:00'
updated_at: '2026-11-08T01:59:23.614761+00:00'
has_child_rationale: These showed up on the passing core-office design and were not
  in the foundation plan.
---
From the core-office design that completed on 2026-11-07 after the zero-area slab-mesh fix.

1. Wall-line loads into the mat. Factored-to-service ratio about 2.07, against about 1.30 on the spread footings. Gravity combinations should land near 1.3 to 1.4. Plan step 1 already replaces the supports/1.4 service guess and notes that the mat's stored reaction omits wall load. The 2.07 number is the measurement that step has to close.

2. Column steel under the minimum. Twenty-four columns came out at ρg 0.0046 to 0.0077. `_validate_column_section` warns and still accepts the section. The warning cites ACI 10.6.1.1. The column limits are ACI 318-11 §10.9.1, 0.01Ag to 0.08Ag (corpus: aci-318-11, page 148). §10.8.4's reduced effective area was not checked. Not previously recorded.

3. Service model warning "Stiffness matrix not SPD — trying LDLᵀ". It still fired on this run, after the slab mesh fix. Already tasked as item 2 of plan-2dcf41ac. expe-5d08745a traced an earlier story-shell warning to zero-area triangles.

Also already on the foundation plan, not repeated here: equilibrium against wall-base reactions, mat 13 hand check, wall dowels, development length as a limit state.
