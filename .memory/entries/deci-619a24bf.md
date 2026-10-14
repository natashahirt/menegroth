---
id: deci-619a24bf
type: decision
project: menegroth
parent_id: deci-280a8580
title: 'CompositeContext requirements: irregular tributary areas + manual override'
node_label: 'CompositeContext requirements: irregular tributary'
tags: composite,requirements,tributary
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-b20c149b
created_at: '2026-10-14T18:47:12.790468+00:00'
updated_at: '2026-10-14T18:47:12.790468+00:00'
---
User requirements for the CompositeContext design:
(1) It must generalize to irregular tributary areas. The building already applies irregular tributary areas as beam loads, and the composite slab description (especially effective width per AISC 360-16 §I3.1a) must derive from the same tributary geometry, not from assumed regular beam spacing. Open mechanics question for the design proposal: with irregular geometry, the distance to the adjacent beam or to the slab edge varies along the span, so which value feeds §I3.1a? This must be grounded in the corpus or put to the user; do not invent a rule.
(2) Default: derive the context from the building. The user can manually override any field.
