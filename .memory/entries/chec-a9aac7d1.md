---
id: chec-a9aac7d1
type: checkpoint
project: menegroth
parent_id: plan-ec9a5d12
title: 'Audit follow-through: tributary area raises, checkerboard cache removed, flexure
  depth limit matches εt = 0.005'
node_label: Audit fixes and remaining findings
tags: audit,voronoi,checkerboard,flexure,benchmark
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-654a5743
created_at: '2026-11-04T00:45:23.720413+00:00'
updated_at: '2026-11-04T00:45:23.720413+00:00'
---
Done after the mechanical pass, each with tests:

1. external/Asap/src/Tributary/voronoi.jl: _meshes_area and _clip_to_boundary no longer swallow errors. No overlap stays a zero area; a clipping or measure failure raises. A missing Voronoi cell still takes an equal share of the boundary and now warns. Voronoi tests 24/24, and the warning did not fire on them.

2. StructuralSynthesizer pattern_cases.jl: removed the process-wide _CHECKERBOARD_CACHE. The partition also depends on struc.cells and is cheap, so it is recomputed per call. Pattern-loading tests 229/229.

3. FrameLine DDM gate docstring now says the three geometry checks read spans from the skeleton, not from the stored center_spans.

4. check_flexural_adequacy used Rn_max = 0.319·β₁·f'c, which is above the εt = 0.005 limit that required_reinforcement enforces (Rn ≈ 911 psi at 4 ksi versus ≈ 1085 psi). It now uses the εt = 0.005 Rn (ACI 318-11 §10.3.4, page 142; §10.2.7.1, page 140). The ratio is converted to psi before ustrip, because ft/inch stays NoDims and ustrip counts it as 12, which made the ratio 1000 times too small. Flat-plate plus tier-1 tests 160 pass, 1 pre-existing broken.

Left as findings, not changed:
- spread_footing flexure warns when εt < 0.005 and returns the steel anyway.
- DDM §13.6.1.4 offset check is skipped with a warning when the coordinate lookup throws.
- A cell face with no edges contributes no tributary load, with a warning.
- NLP multi-start falls back to the x0 result when no start is feasible.
- Unused-value scan (scripts/runners/audit_unused.py, logs/audit_unused.txt) has 849 raw hits, almost all keyword arguments or returned fields. critical_section_properties returns principal unit vectors e1, e2 that no caller reads; punching_stress_general recomputes them from θp, so the stress is unaffected.

Not committed. The working tree mixes this work with another session's directory split (files moved into punching/, pipeline/, ddm/, checks/), so a partial commit would cut through that refactor.
