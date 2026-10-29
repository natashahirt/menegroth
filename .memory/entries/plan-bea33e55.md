---
id: plan-bea33e55
type: plan
project: menegroth
parent_id: plan-396a2056
title: Rebuild Asap parametric frame processing
node_label: Rebuild Asap parametric frame processing
tags: asap,parametric,topology,loads,springs,architecture
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-49e87f70
created_at: '2026-10-29T15:15:09.846977+00:00'
updated_at: '2026-10-29T15:15:09.846977+00:00'
has_child_rationale: User accepted the implementation plan.
---
Confirmed plan: replace duplicated parametric processing with an atomic, shared topology-normalization pipeline for FrameModel and mixed Model. Preserve source declarations for repeat processing; remap LineLoad and PointLoad, converting fracture-point loads to NodeForce; reject TributaryLoad and unsupported Joist-host semantics initially; make springs model-owned; prove behavior with dual-model conservation, release, unit, atomicity, and idempotence tests.
