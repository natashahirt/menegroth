---
id: deci-bf3759a9
type: decision
project: menegroth
parent_id: plan-4b6f6344
title: Wall groups share a mark only when the reinforcement matches
node_label: Wall marks follow reinforcement
tags: walls,phase-7,grouping,design
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d2a2b55c
created_at: '2026-10-29T02:09:18.435360+00:00'
updated_at: '2026-10-29T02:09:18.435360+00:00'
has_child_rationale: 'Corrects step 7 of the wall demand plan: a geometry group is
  not designed for the worst instance.'
---
Geometry and connectivity identify walls of the same shape. They do not share a design.

Each pier is checked for its own concurrent (N, M, V), one record per wall, story, direction, and combination. A base pier and a roof pier with the same length and thickness stay separate designs.

A shared mark is for piers whose required reinforcement comes out the same. Raw load values are not a group key. Designing a geometry group for the governing instance across the group is off. Column upsizing is an optional pass and is not applied to walls.
