---
id: anno-296d1ce9
type: annotation
project: menegroth
parent_id: plan-b2670c25
title: 'User preference: provide manual overrides for almost everything'
node_label: 'User preference: provide manual overrides for almo'
tags: preference,api-design,override
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-b20c149b
created_at: '2026-10-14T18:47:18.178782+00:00'
updated_at: '2026-10-14T18:47:18.178782+00:00'
---
The user wants manual override hooks for almost any automatically derived input (geometry-derived spans, composite context, tributary-derived quantities, and so on). In new APIs, default to deriving from the building model, but expose an explicit override argument or field, and make clear in traces and results when an override was used.
