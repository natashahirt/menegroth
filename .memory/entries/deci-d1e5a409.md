---
id: deci-d1e5a409
type: decision
project: menegroth
parent_id: plan-c7b78612
title: Coefficients are the default; the strip and the shell are the other two methods
node_label: Coefficients, then strip, then shell
tags: slabs,one-way,coefficients,strip,fea
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9a6bddb8
created_at: '2026-10-31T19:35:13.945996+00:00'
updated_at: '2026-10-31T19:35:13.945996+00:00'
has_child_rationale: User confirmed all three methods should be built, with a default
  and a fallback.
---
Locked 2026-10-31. All three panel analyses are in scope. Coefficients are the default on a bay that meets ACI 318-11 §8.3.3. A bay outside those limits uses the continuous strip. The shell is the third method and the analysis for a two-way panel.

This closes the open default-method question. The earlier note that the hierarchy was deferred is superseded by this choice: the methods are planned, and the coefficients are what a regular bay runs first.
