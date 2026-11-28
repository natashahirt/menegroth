---
id: chec-354fc41f
type: checkpoint
project: menegroth
parent_id: chec-2dea3888
title: Rigid mat strips use Bowles combined-footing statics
node_label: Bowles strip statics
tags: mat,bowles,strip,foundations
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f84b3650
created_at: '2026-11-12T14:16:40.976750+00:00'
updated_at: '2026-11-12T14:16:40.976750+00:00'
---
Rigid mat strip moments no longer use wL²/10, wL²/11, and wL²/12. Bowles, Foundation Analysis and Design, 5th ed., §9-2 (textbook-bowles-foundation-analysis-design-5e, PDF pages 502–504) treats the strip as a combined footing: uniform soil pressure upward, column loads as downward point loads, and the shear and moment diagrams from statics. Positive moment is bottom steel near the columns. Negative moment is top steel between the columns. §10-6 item 1 (PDF page 576) is the mat strip read as that combined footing.

A two-column hand case (20 ft by 10 ft, 100 kip at 2 ft and 18 ft, qu = 1 ksf) gives M_neg = 300 kip·ft and M_pos = 20 kip·ft. That test passed.

ACI 336.2R Eq. (5-1) is not readable in the corpus text (the formula is OCR garbage on PDF page 8). wall_footing_kr is still not defined, so design_footing of a rigid mat throws at the stiffness gate after the strip moments are computed. The wall-strip file that mentions the gate does not load (_Aabb is missing) and is not included.

No file pin: the memory server tracks the main checkout. Worktree row-f-nlp.
