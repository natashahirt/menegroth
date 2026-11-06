---
id: deci-b7058ae4
type: decision
project: menegroth
parent_id: menegroth
title: Detail sheets draw stored bars and stirrups, not a spacing
node_label: Section drawings from stored bars
tags: viewer,rebar,stirrup,detail
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c437e59c
created_at: '2026-11-06T22:30:29.345681+00:00'
updated_at: '2026-11-06T22:30:29.345681+00:00'
---
The detail panel draws a cross section and a longitudinal section in engineering linework: cut concrete hatched, bars filled, centerlines and dimensions.

Column bars are the stored centers. A beam's bars are the single tension layer at d and, when present, the compression layer at d_prime, spaced the way that section's own clear-spacing check already spaces them. The stirrup or tie is the closed centerline inset by the stored clear cover plus half the stored bar diameter. A circular spiral radius is recovered from the bar seat the constructor used.

Transverse spacing is not a field on the section, so the longitudinal section does not invent stirrup ticks. The caption says the spacing is not recorded. A scene written before `transverse` still draws its outline and any `rebar_m` it has.
