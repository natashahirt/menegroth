---
id: note-e9a2f8ae
type: note
project: menegroth
parent_id: todo-8ccd78cf
title: Cladding and spread-footing lateral cases are already in; strips, mats, and
  grade walls are not
node_label: Cladding and spread-footing lateral cases are alre
tags: cladding,foundations,wind,seismic,note
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-df7afd0f
created_at: '2026-11-25T16:37:19.892778+00:00'
updated_at: '2026-11-25T16:37:19.892778+00:00'
---
Cladding is already applied. `wall_SDL` becomes perimeter `:cladding` line loads (half of each façade band on the beam at each end; a band with no lower beam hangs from the upper beam; a structural wall is omitted). Those loads are in the gravity model, the unfactored dead case, the service foundation solve, and W and Px through `_deposit_cladding!`. ASCE 7-22 §3.1.1 and §12.7.2. The vertical split is the same engineering judgment already used for wall self-weight.

Isolated spread footings already take wind and seismic when `design_ordinary_walls!` stores `foundation_lateral`. Each ASCE 7-22 §2.3 and §2.4 combination is checked. The §12.13.4 overturning reduction and the Ev = 0 soil-interface permission are not used.

Still one load: strip and mat footings collapse the combinations in `_lateral_column_demand` (largest moment with a separate maximum service P). Grade-wall nodes still read the gravity reaction only. A strip is centered on one service resultant, so checking every combination on one strip is a layout decision, not a factor to copy.
