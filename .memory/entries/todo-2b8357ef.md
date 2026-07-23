---
id: todo-2b8357ef
type: todo
project: menegroth
parent_id: plan-73c8dcc7
title: 'P0: DesignState serializable substrate + domain-agnostic export seam (round-trip
  on medium_office)'
node_label: 'todo: DesignState'
tags: designstate,serialization,export-seam,medium_office
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-8856e3bd
created_at: '2026-07-23T14:46:48.216136+00:00'
updated_at: '2026-07-23T16:49:57.462875+00:00'
---
Define/implement DesignState as a projection/adapter over BuildingDesign + DesignParameters + TraceCollector + corpus citation set. Reuse api/serialize.jl / deserialize.jl. Serialize to a domain-agnostic export seam (stable ids + explicit code/data/corpus refs). Validate JSON round-trip on medium_office. Mark done by discarding with reason 'completed'.
