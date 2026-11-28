---
id: todo-15a5fe44
type: todo
project: menegroth
parent_id: chec-84bfdaa7
title: 'Decide advisory member slenderness handling for axial sizer (KL/r≤200 §E2
  compression, L/r≤300 §D1 tension): warn vs hard constraint vs omit'
node_label: Decide advisory member slenderness handling for ax
tags: axial-member,slenderness,aisc,chapter-e,chapter-d,open-decision,corpus
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ddbef912
created_at: '2026-11-23T18:13:04.065787+00:00'
updated_at: '2026-11-23T18:13:04.065787+00:00'
has_child_rationale: Open question flagged by the step-3 axial sizer agent; a user-level
  decision deferred out of scope
---
`size_axial_members` currently does NOT apply the AISC 360-16 advisory slenderness limits: KL/r ≤ 200 for compression (§E2) and L/r ≤ 300 for tension (§D1). These are serviceability/handling preferences, not strength checks, so they were intentionally left out of the thin sizer (scope held to reusing existing strength checks only).

DECISION NEEDED (user): should the axial sizer (a) ignore them, (b) emit a warning/trace when a chosen section exceeds them, or (c) reject candidate sections exceeding them as a hard constraint? Likely a per-role default (e.g. hard for primary compression braces, advisory for secondary ties).

Before implementing: these are code-derived, so verify the exact clause text/intent against the corpus (§E2 'User Note', §D1) and cite source_id + clause + page. The parallel corpus clause-inventory agent (15c4a795) is already retrieving §D1/§E2 — fold its finding in here.
