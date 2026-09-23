---
id: todo-c32a7ad6
type: todo
project: menegroth
parent_id: plan-a4de4826
title: Invalidate pattern cache after re-solve; keep signed Pu on combined footings
node_label: Invalidate pattern cache after re-solve; keep sign
tags: patterns,foundations,cache,uplift,coordinator
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-0c95bc1c
created_at: '2026-09-23T03:51:40.765656+00:00'
updated_at: '2026-09-23T04:04:22.359101+00:00'
---
P0: pattern_u cache is not cleared after Asap.update!/solve! in the sizing loop, so later member_group_demands envelope unsized pattern u. P0: Fz<0 clamped to Pu=0/Ps=0 so combined/strip footings lose the uplift couple (400 kN / -200 kN, 20 ft). Nested under foundation safety corrections.
