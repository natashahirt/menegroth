---
id: todo-cd4f1ef8
type: todo
project: menegroth
parent_id: deci-89225495
title: Add executable DesignParameters field-completeness invariant test + resolve
  dead beam_I_factor
node_label: 'TODO: completeness invariant'
tags: todo,test,invariant,PREPARE_AFFECTING_FIELDS,beam_I_factor,safety-critical
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f5bbcf39
created_at: '2026-10-21T04:03:22.949433+00:00'
updated_at: '2026-10-21T04:03:22.949433+00:00'
has_child_rationale: 'Deferred critic P2 finding #1 from P0-1 review'
---
## Deferred critic finding #1 (P2)

Add an **executable** completeness-invariant test asserting:

`PREPARE_AFFECTING_FIELDS ∪ (all pipeline param_slices) ∪ {capture-time fields} == fieldnames(DesignParameters)`

The test must **fail on any unclassified field** so a newly-added `DesignParameters` field cannot silently escape routing classification.

Also **resolve the dead `beam_I_factor` field**: it is hardcoded `0.70` at `design_workflow.jl:909` instead of reading `params.beam_I_factor`. Either delete the field or wire it up + classify it — **in the same commit** as the invariant test.

**Rationale**: this invariant is the single thing preventing a silently-stale structural design (an unclassified result-affecting field would be misrouted as param-only and skip the needed prepare step). It is currently tribal/unasserted.
