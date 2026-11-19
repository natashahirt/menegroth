---
id: deci-b57949dd
type: decision
project: menegroth
parent_id: deci-6241f871
title: At a crossing the shorter span that already reaches supports stays continuous
  and carries the longer one
node_label: Shorter span carries the longer one
tags: framing-level,hierarchy,nova,engineering-judgment,joists
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-489e7aa7
created_at: '2026-11-18T22:18:47.562992+00:00'
updated_at: '2026-11-19T04:50:51.841522+00:00'
---
Natasha confirmed this reading of the hand-drawn 2024 strokes (test_drawn, triple_bay_drawn, triple_bay_bau_drawn). ENGINEERING JUDGMENT. No code states which crossing beam supports the other.

A line with two columns, walls, or :support vertices is level 0 and stays one piece. An unranked line is cut where it crosses a beam already ranked. When two unranked pieces cross and both already reach a support at each end, the shorter one is ranked and the longer one is cut. A piece's level is one above the higher beam it stops on. Pieces that stop on the same generation share a level. Equal lengths support neither.

Checked against her stroke ids: test_drawn matches 4/5/10/4. triple_bay_drawn matches the carried levels 30/60/24, and triple_bay_bau matches the 18 carried strokes. The extra level-0 strokes in her files are collinear pieces of a column line, which stay level 0 as one line.

On the current ranker, nova/e3c4 leaves 136 of 148 lines at level 0 because both directions run through each joint. This rule resolves it as 12 lines on the columns, 80 on those, and 288 short pieces on the 80. grid/x1y1 would gain a third level (6/4/8 lines) because a shorter span cuts a longer one. Not implemented yet; the next check is the joist-system designs on the complex 2024 layouts.
