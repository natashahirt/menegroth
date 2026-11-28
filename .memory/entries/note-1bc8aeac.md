---
id: note-1bc8aeac
type: note
project: menegroth
parent_id: expe-7cf96561
title: 'Scale gotcha fixed at root: objective_value now unit-canonical (uconvert)
  for all materials, incl. US-customary steel'
node_label: 'Scale gotcha fixed at root: objective_value now un'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/core/objectives.jl@f252256, StructuralSizer/test/optimize/test_column_full.jl@f252256
session_id: sess-3103885d
created_at: '2026-11-25T03:27:05.597317+00:00'
updated_at: '2026-11-25T03:27:05.597317+00:00'
---
PROBLEM (the 'scale gotcha'): objective_value(MinWeight/MinCarbon/MinCost, s, mat, L) multiplied metric geometry (A·L in m^3) by a material density defined in US-customary units (A992 steel ρ in lb/ft^3). The product stayed in a COMPOUND unit (m^3·lb/ft^3), not kg. When coefficients were ustrip'd at the MIP cache boundary they came out ~1/16.0184× the true kg value. SI-defined materials (ρ in kg/m^3) were already canonical, so a MIP mixing A992 + S355 under one objective silently compared coefficients on two different scales — a latent correctness bug beyond the ε-constraint budget API that surfaced it.

FIX (root, not a patch): wrapped the standard objectives in objectives.jl with explicit uconvert — MinWeight → u"kg", MinVolume → u"m^3", MinCost → u"kg"·cost, MinCarbon → u"kgCO2e". Every material (US or SI) now yields coefficients in the documented canonical units. Precompute sites (AISC/ACI/pixelframe caches) need NO change: they ustrip against unit(objective_value(...)), which is now canonical automatically.

BLAST RADIUS = effectively zero behavioral change: StructuralSizer within-material optimization is scale-invariant (ranking unchanged). StructuralSynthesizer consumers are all either RELATIVE compares within one material+objective (size_columns.jl:321/392, size_beams.jl:1125, capture_results.jl:900 floor-ratchet obj(sec) vs obj(prev)) or operate on CONCRETE/RC (column_oversize.jl:159, interactive_checks.jl:835, already canonical via _rc_objective). None report steel objective_value as an absolute physical quantity. ONLY broken test: test_column_full.jl 'Material Comparison', which compared steel MinWeight (kg) vs concrete MinCarbon (kgCO2e) and only 'passed' because steel weight was buggily ~16× small. Fixed by minimizing the SAME objective (MinVolume) on all three so the comment's stated volume<volume comparison is actually tested. 140/140 green.

Verified post-fix: column_full 140/140, Multi-Material MIP 45, ε-constraint 45, scalarization 25, coupled warm start + continuation, PixelFrame 355 — all green.
