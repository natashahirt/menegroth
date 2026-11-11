---
id: deci-4f3eb12e
type: decision
project: menegroth
parent_id: plan-4fb2ee75
title: 'Opening framing: auto with opt-out, conventional layout, optional off-axis
  frames, joists clipped'
node_label: 'Opening framing: auto with opt-out, conventional l'
tags: openings,trimmers,headers,irregular-geometry,joists
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1a5c74fe
created_at: '2026-11-11T15:49:02.700641+00:00'
updated_at: '2026-11-11T15:49:02.700641+00:00'
has_child_rationale: User answered the opening-plan questions
---
User decisions 2026-11-11:
- Rectangular openings in beam-supported floors (one-way, composite deck, joists, beam-supported two-way) are framed automatically, with a per-opening opt-out. Warn listing the added beams.
- Layout is conventional: trimmers parallel to the span run support to support beside the opening; headers perpendicular to the span run between the trimmers. (Corrects the earlier note that headers extend to supports.)
- Off-axis frames are allowed when the user asks: per-opening framing setting :auto (default; frame only span-aligned rectangles, else warn + cantilever check), :opening_axes (frame along the opening's own edges; trimmers land skewed on the first beam; refuse that opening if a trimmer finds no beam), :none (warn + cantilever). A non-rectangular opening is never auto-framed; an explicit frame on one uses the enclosing rectangle in the chosen direction and warns.
- Joists crossing an unframed opening stop at it; a joist with one supported end is checked as a cantilever; a joist with no support is dropped.
- Add the three extra audit items at the end: joist landings on walls, level-1 tributary joists ignoring interior girders, quad area via fan triangulation.
Phase order: A openings, B beam rings as supports, D tests for re-entrant drop and sloped refusal, C level-2/solid-head story filter + column solid heads, F ingest checks, E deck girder construction load (investigate first), then extras.
