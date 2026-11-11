---
id: expe-b14193ea
type: experiment
project: menegroth
parent_id: plan-bff9aa9f
title: 'FEA flat-plate mesh convergence: M⁻ mesh dependence is from section-cut band
  δ=max(3h,c), not the FE field'
node_label: 'FEA flat-plate mesh convergence: M⁻ mesh dependenc'
tags: fea,mesh,flat-plate,safety,performance
status: active
open_threads: 2
success: 'null'
files: scripts/runners/study_fea_mesh_convergence.jl@ea295d4
session_id: sess-b4afcaf1
created_at: '2026-10-26T16:20:32.790083+00:00'
updated_at: '2026-10-26T17:56:55.602393+00:00'
---
Runner: scripts/runners/study_fea_mesh_convergence.jl (logs/fea_mesh_convergence*.csv).

Geometries: 8x5 office (20 ft bays, 18 in cols, h=9 in) and 3x3 grid (30 ft bays, 22 in cols, h=11 in). Quantities from run_moment_analysis(FEA(target_edge=…)).

Findings:
1. Frame-strip M⁻ (ext/int) and column M⁻ converge only once 3*h_mesh < c (target_edge ≲ 0.15 m). 3x3 grid vs 0.08 m ref: 0.10–0.15 m within ~3%; 0.20 m −10..−12%; 0.30 m −21..−25%; 0.50 m −31..−35%. Production default target_edge = clamp(min_span/20, 0.15, 0.75) m → 0.30 m (20 ft bays) / 0.46 m (30 ft bays), i.e. on the unconverged (unconservative) side.
2. Cause: _section_cut_bandwidth δ = max(3*h_mesh, c_avg) centered on the column face; a coarse mesh widens δ and smears the face peak. Re-extracting the same FE solutions with δ pinned to c gives column M⁻ within ±5% of the 0.10 m reference for every mesh up to 1.0 m.
3. Unbalanced moments from column stubs are independently mesh-sensitive (≈48% at 0.30 m, 11% at 0.15 m vs 0.10 m) — not a band effect; feeds punching γv·Msc.
4. M⁺ within ~3–10%, deflection within ~2–8%, column shears within ~2%, Vu_max mesh-independent.

Implication: a coarse 'fast' sweep mesh is NOT safe under the current band rule. Any change to δ or the default mesh changes production design moments → needs user decision (no code change made).
