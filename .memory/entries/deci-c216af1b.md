---
id: deci-c216af1b
type: decision
project: menegroth
parent_id: deci-c2d7f74e
title: Extra transfer bars are credited to the column strip of the moment that needs
  them
node_label: Transfer bars use their own strip
tags: flat-plate,moment-transfer,aci-318-11,13.5.3.2
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-bdc81220
created_at: '2026-11-09T00:15:45.408577+00:00'
updated_at: '2026-11-09T00:15:45.408577+00:00'
has_child_rationale: The band fix left the additional-bar count on the primary strip.
---
Additional bars at a column are counted against the column strip of the moment that still needs steel, not always the primary strip.

`_directional_transfer_bars` sizes each axis with that axis's column-strip steel (`design_c1` / `design_c2`, swapped when the span runs along c2) and reports the axis whose band is short by more area (`direction = :c1` or `:c2`). A direction with no strip design is credited with zero steel already placed. ACI 318-19 §8.6.1.2 top steel is measured across c2, so it is compared with the c1-direction strip.

The placed-steel εt check adds those bars only to the band they belong to. A result with no `direction` is still counted in both bands.

Test: a 40 kip·ft secondary moment on a 0.30 in² secondary strip needs bars, while the 4.0 in² primary strip would have covered it. `slabs/test_moment_transfer_13_5_3_3.jl` passed 51/51.
