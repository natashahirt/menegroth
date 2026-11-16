---
id: plan-ba4a1d63
type: plan
project: menegroth
parent_id: plan-879616a6
title: 'Joist floor: re-check swapped rib sections; size girders on the intended load
  path too'
node_label: Re-check ribs, hierarchy demand
tags: joist,collinear-ribs,member-check,load-path,girder,story-shell
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ffd44328
created_at: '2026-11-16T02:27:58.810552+00:00'
updated_at: '2026-11-16T02:27:58.810552+00:00'
has_child_rationale: The 1.25 m concrete module (one-way joists at 34 in) printed
  63 of 120 beams OK with ratio 0
---
Diagnosis on grid/x1y1 one-way joists (scene sdf_grid_x1y1_loose.mgscene):

1. `_install_rib_section!` (collinear_ribs.jl) installs the shared-bar section without updating `m.base.check`, so `member_check` returns nothing (identity check on section) and `capture_results` marks the beam OK because `:members` is absent. 63 of 120 beams. The swap keeps phi*Mn+ >= old but does not re-check shear or the final frame demand.
2. Load path: 6x5 m panel lines inside 12x10 m column bays. Lines x=6, x=18 have no columns and land at midspan of the 12 m girders y=0,10,20 (each two 6 m T10x16 pieces). Beam forces come from the elastic frame; the tributary cascade is width/carbon bookkeeping only. Concrete joists default fixed-fixed. The soft girder takes ~76 kN at x=6 (13 mm sag); inner-bay joists cantilever off the non-rotating x=12 girder and prop the x=6 line (124-588 kN m vs ~34 kN m simple span; outer bays 28-40). x=12 pieces grew to T30x36 (1659 kip ft). Column sum 1366 kip vs 1303 kip floor + ~30 kip columns: equilibrium is fine, distribution is the problem.

User decisions:
- Re-run the beam checks on the swapped section against the group's final demand and record them.
- Size girders on the larger of the frame force and the intended path (joists -> beam line -> girder -> column) reactions.

How the intended-path reactions are computed is not decided yet; ask before implementing.
