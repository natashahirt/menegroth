---
id: todo-fcdb03a2
type: todo
project: menegroth
parent_id: plan-cecee16b
title: H1 — Steel braced frames (CBF/EBF/BRBF), demand-as-input
node_label: 'H1: Braced frames'
tags: todo,steel,braced-frame,cbf,ebf,brbf,aisc,phase-h
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:26:03.455246+00:00'
updated_at: '2026-07-15T02:26:03.455246+00:00'
has_child_rationale: First scope-ladder step for steel LFRS; Strut type exists with
  no sizer
---
# H1 — Steel braced frames

The first, dev-loop-sized step of the steel LFRS ladder (mirrors wall S1). Design concentric (CBF), eccentric (EBF), and buckling-restrained (BRBF) braced frames with **per-frame demand supplied as input** (defer full lateral distribution to Phase A3/A4).

**Build:** give `Strut` a sizer (currently type-only), brace member design (AISC 360-16 Ch. E compression / Ch. D tension — have the checks), tension/compression-only behavior in the Asap model, EBF link design, and story-level brace force recovery. Connections (gusset plates) hand off to D5. **Canon:** AISC 360-16 (member design, in code). **Couples to:** D5, A5 (stability), and A3 for real demands later.
