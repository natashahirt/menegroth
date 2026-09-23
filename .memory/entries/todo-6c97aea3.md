---
id: todo-6c97aea3
type: todo
project: menegroth
parent_id: plan-a4de4826
title: Ungate hogging from composite sentinel on 6-arg is_feasible
node_label: Ungate hogging from composite sentinel on 6-arg is
tags: hogging,mip,signed-moments,coordinator
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-fd4c0ecb
created_at: '2026-09-23T03:29:02.773745+00:00'
updated_at: '2026-09-23T03:37:53.573949+00:00'
---
Hogging Chapter F (Cb=1.0, Lb=L) must run on 6-arg is_feasible whenever Mux_neg is present, not only when demand.composite===true. Default SteelBeamOptions() is composite=false; optimize_discrete currently false-PASSes W21X55 at Mux_neg=432. NLP composite=true also drops Mux_neg. Nested under foundation safety corrections.
