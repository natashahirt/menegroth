---
id: deci-7cccc278
type: decision
project: menegroth
parent_id: plan-a79eb74f
title: 'A trace is a path through the design map: every event names a map node, every
  step follows a map edge'
node_label: Trace = path through map
tags: trace,design-map,flowchart,contract,decision
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/plan.md@0a0202c
session_id: sess-ee879530
created_at: '2026-11-13T16:07:25.506939+00:00'
updated_at: '2026-11-13T16:07:25.506939+00:00'
---
User 2026-11-13: the trace should be a path through the overall design map. Contract (plan.md Workstream T): TraceEvent labels are map node ids; consecutive events for one element must follow edges present in the map. An event with no node or a step on a missing edge fails the path test (undocumented code path or wrong map). Check-level nodes seeded from StructuralSizer TRACE_REGISTRY (@traced: func_name, layer, events, file, line).
