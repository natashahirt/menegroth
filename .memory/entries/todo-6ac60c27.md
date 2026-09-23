---
id: todo-6ac60c27
type: todo
project: menegroth
parent_id: plan-a4de4826
title: Wire composite hogging onto 6-arg MIP is_feasible
node_label: Wire composite hogging onto 6-arg MIP is_feasible
tags: composite,hogging,mip,coordinator
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-be79c82c
created_at: '2026-09-23T03:08:42.474431+00:00'
updated_at: '2026-09-23T03:21:06.633612+00:00'
---
Wire CompositeContext onto the 6-arg is_feasible/explain MIP path (SteelBeamOptions.composite → demand.composite) so hogging Cb=1.0 and Lb=L apply in production, not only the 8-arg overload. W21X55 L=10ft Cb=1.67 Mux_neg=432 kip-ft must fail 6-arg. Nested under foundation safety corrections.
