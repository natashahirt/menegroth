---
id: expe-6dcbaa95
type: experiment
project: menegroth
parent_id: plan-3b429631
title: 'Column shrink-and-verify on medium_office: mechanism works + safe, BUT shrinking
  to min plan-area INCREASED true carbon (+4.8% columns) — empirically validates WP
  2.5 (rebar in objective) as a prerequisite'
node_label: 'Column shrink-and-verify on medium_office: mechani'
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/column_shrink_verify.jl@921a87b
session_id: sess-a2c7af45
created_at: '2026-11-21T19:35:46.124616+00:00'
updated_at: '2026-11-21T19:35:46.124616+00:00'
---
Ran scripts/runners/column_shrink_verify.jl on medium_office (3x3, 3-story flat plate).

Procedure: design A (grow-only) -> flat_plate_column_shrink_verify! installs the probe's lightest-plan-area section on each oversized column + re-solves frame -> capture_design -> design B. Compare all_checks_pass and ec.jl carbon.

Result:
- 4 columns shrunk: #21/24/25/28, 12x12 -> 10x10 (exactly the probe's prediction).
- SAFETY PRESERVED: all_checks_pass A=true, B=true. The shrink-and-verify mechanism works and keeps the design code-compliant.
- CARBON WENT UP: columns A=7614 -> B=7983 kgCO2e (+4.8%); total 53633 -> 54002 (+0.69%). WORSE, not lighter.

Root cause: the probe (and the sizer's objective / obj_coeffs) rank sections by PLAN AREA = concrete only (map: 'RC objectives ignore rebar'). Shrinking 12->10 forces a higher-rho section; ec.jl counts rebar, and the rebar carbon increase outweighs the concrete saving. This is EXACTLY plan.md WP 2.5: 'without rebar a thin, heavily reinforced section looks cheaper than it is.'

Implications for Part B sequencing:
1. O4 'oversize' MUST be measured on true (rebar-inclusive) carbon, not plan area. My plan-area probe gives a misleading signal and should be re-based on ec.jl carbon.
2. WP 2.5 (rebar in EVERY RC objective) is a hard PREREQUISITE for any Phase 3 column shrink. With a rebar-blind objective, a shrink pass can make true carbon WORSE while passing all checks.
3. The grow-only FLOOR we flagged as causing oversize was, on these 4 columns, accidentally protecting the (true-carbon-better) 12x12 against a rebar-blind 'lightest'. Convergence stability and the objective are coupled.

NEXT: re-run the oversize probe keyed on ec.jl carbon (concrete+rebar) to get the REAL O4 gap; expect it to be much smaller than the 2.1% plan-area figure, possibly ~0 on this benchmark. Mechanism is proven; the lever is the objective, not the floor.

Caveat: slab FEA not re-run at shrunk sizes (embedded in slab sizer); column-level verify is conservative. design_building ~1208s due to concurrent waffle-run contention.
