---
id: deci-6f2facb5
type: decision
project: menegroth
parent_id: deci-0f9ac6c8
title: 'Fix the three merge-only failures: façade off in the θ fixture, Cb noise,
  column floor after the search'
node_label: three merge-failure fixes
tags: merge,cladding,cb,flat-plate,column-floor
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2dcc4614
created_at: '2026-11-19T18:06:52.185907+00:00'
updated_at: '2026-11-19T18:06:52.185907+00:00'
---
Three merge-only failures, confirmed against integration commit abe95f9e.

Ordinary-wall P-delta fixture sets wall_SDL = 0. The softened Y frame is what the test measures. The default 10 psf façade was pushing θ to 0.129. Production default stays 10 psf.

Commentary Eq. C-F1-5 is unchanged and is not capped. A hogging end that is numerical noise next to the other moments in the segment is treated as zero, and the caller keeps Cb = 1.0. The relative gate is 1e-8 of the largest absolute moment in the segment. That is a numerical cutoff, not a code factor.

The flat-plate plan-size floor is raised after the section search as well as after the slab commit. A plan size the search installed above the size at the start of the round is a floor. The search does not go back under it. On the pentagon that stops the 14/18/20/22 in cycle. The installed size is whatever the search required before it was allowed to shrink, which the run will show.
