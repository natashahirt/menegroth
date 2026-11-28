---
id: expe-f2241cc0
type: experiment
project: menegroth
parent_id: expe-10235d3c
title: 'T-beam capacity cache exactness sweep: 3/3 waffle geometries bit-identical
  cache ON vs OFF (grid/x1y1, special/rhombus_8x12, star/e0c0)'
node_label: 'T-beam capacity cache exactness sweep: 3/3 waffle '
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/tbeam_cache_exactness_sweep.jl@313e4bd
session_id: sess-bbb27d28
created_at: '2026-11-23T18:03:33.629297+00:00'
updated_at: '2026-11-23T18:03:33.629297+00:00'
---
Multi-geometry exactness confirmation for the in-memory T-beam capacity cache (capacity_store, note/deci chain under expe-10235d3c). Each plan designed twice (cache ON vs OFF) at max_iterations=6; all five fingerprint fields compared bit-for-bit.

RESULTS — all PASS, bit-identical:
- grid/x1y1: all_checks_pass=true, critical Column 3 (pm_interaction) r=0.9899660947052036, total_ec=57268.55669788574, ec_intensity=119.30949312059529. pipeline=306.6 s/design.
- special/rhombus_8x12: all_checks_pass=true, critical Beam 35 (flexure) r=0.9972554646822545, total_ec=16288.714761461011, ec_intensity=169.6741120985554.
- star/e0c0: all_checks_pass=true, critical Beam 115 (flexure) r=0.9945943096810913, total_ec=67591.81354168584, ec_intensity=140.8162782118455. pipeline=613.4 s/design (heaviest; 64 RC T-beam groups).

Conclusion: the content-keyed capacity_store is bit-exact across typical and weird (rhombus, star) waffle plans, not just grid/x1y1. Note all three converged early ('Story shell and frame agree on the installed sections') well under the iteration cap, so these are the one-way-joist/mixed configs, not the failing dense-waffle min-reinforcement case (todo ribsteel). Validation cost: ~2x306 + 2x(rhombus) + 2x613 s.
