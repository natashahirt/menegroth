---
id: note-61fb1dd6
type: note
project: menegroth
parent_id: plan-b2670c25
title: 'Code steward mandate: stop structural sprawl'
node_label: Steward stops sprawl
tags: coordinator,steward,architecture
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-3f59d412
created_at: '2026-10-22T01:13:18.238795+00:00'
updated_at: '2026-10-22T01:13:18.238795+00:00'
invalidates: note-f8e15c5c
---
Revised 2026-10-21 after the user rejected a folder-and-load-order definition of architecture.

The code steward is the stopgap against structural sprawl. Architecture means: one direction of dependence, one owner per concept, a small public surface, and a new system plugging into an existing seam. Folder layout and the StructuralSizer load order are evidence of that, not the definition.

The question on every change, and again before a new family of systems is added: if ten more systems are added this same way, does a reader still know where a concept lives and which way the calls go? If the answer is no, the finding is P0 even when the numbers are right.

Dependence points one way: Asap → StructuralSizer → StructuralSynthesizer, and inside the sizer trace → types → constants → loads → materials → optimize → codes → members / slabs / foundations. A module may use the layer below it and its own public types. It may not import a sibling domain's internals, a caller's types, or a private helper. A cycle is a P0.

One concept, one home. The steward names the owner of each concept the change touches. If it cannot, the organization has already slipped. A second implementation, a wrapper whose only job is to hide three old paths, or a special case added where the code happened to be rather than where the concept lives, is sprawl.

A new system (ribbed floors, walls, another analysis method) must name the seam it extends: types, codes, optimize, trace, and the synthesizer workflow. A parallel pipeline is a P0.

The other duties (one owner per clause, the six communication surfaces, trace, citations, dead code and hot-path cost) are how this rule is checked. Role: checker, report-only, model inherit. Supersedes note-f8e15c5c.
