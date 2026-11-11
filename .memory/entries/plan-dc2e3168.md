---
id: plan-dc2e3168
type: plan
project: menegroth
parent_id: plan-9768ec38
title: Opening bands, one deep beam, then the rigid office
node_label: Opening bands, one deep beam, then the rigid offic
tags: walls,openings,deep-beam,diaphragm
status: active
open_threads: 4
success: 'null'
files: ''
session_id: sess-51fed68a
created_at: '2026-11-06T11:16:11.258269+00:00'
updated_at: '2026-11-06T14:19:23.456196+00:00'
---
Three wall items, in order, ahead of applying a flexible-diaphragm story force.

1. Split a horizontal opening segment at the story joint. A horizontal segment exists only in the story that has the opening. An ordinary lintel uses the beam flexure and shear checks. Stories above a window stay on the gross-pier path. Prove it on the three-story office.

2. A short band, clear span at most four times its depth, is designed as one deep beam. ACI 318-19 §9.9.1.3 (corpus: aci-318-19, PDF p. 154) names Chapter 23 strut-and-tie as satisfying §9.9.1.2. Scope is one opening band: its strut, its tie, the nodes at its ends, the §9.9.2.1 shear limit, and the §9.9.3 side reinforcement. Not a general truss.

3. On the rigid office, report which piers the gravity stage withholds. Wide piers already use the second-order cut when rigid masters exist. Narrow piers stay on the 5 percent nonsway test. Do not apply §6.6.4.6. A gravity building with no rigid diaphragm stays first-order.

The long-span fire-rating beam remains the reminder to write AISC 360-16 §F4 (todo-562ec7a4). The column ratio comparison remains the reminder for the 0.01 band (todo-e9bd8f1d).
