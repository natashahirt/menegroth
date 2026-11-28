---
id: expe-fe0b32ea
type: experiment
project: menegroth
parent_id: plan-0b622f2c
title: 'Multi-material Pareto engine (ParetoScalarization) proven on RC columns: genuine
  weight<->carbon front, 8 non-dominated designs'
node_label: Multi-material Pareto engine (ParetoScalarization)
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/core/objectives.jl@b8eb825, StructuralSizer/src/StructuralSizer.jl@b8eb825,
  StructuralSizer/test/optimize/test_pareto_scalarization.jl@b8eb825, StructuralSizer/test/runtests.jl@b8eb825,
  scripts/runners/multimaterial_pareto.jl@b8eb825
session_id: sess-3438c003
created_at: '2026-11-25T00:35:10.277179+00:00'
updated_at: '2026-11-25T00:35:10.277179+00:00'
---
Built the weighted-scalarization Pareto-continuation engine and proved it on a real multi-material MIP.

ParetoScalarization{O1,O2,R1,R2} <: AbstractObjective (objectives.jl, exported): minimizes the DIMENSIONLESS convex combination w*(o1/ref1) + (1-w)*(o2/ref2), w in [0,1], with ref1/ref2 positive quantities matching o1/o2 units. objective_value delegates to each component's own objective_value and FORWARDS precompute kwargs (rebar, transverse), so it inherits exact semantics incl. the RC concrete/rebar carbon split, and works unchanged under every checker whose cache precomputes objective_value (AISC steel + ACI columns/beams both route through generic objective_value with a NoUnits branch). Construction validates w in [0,1] and positive refs. Sweeping w=1->0 walks supported Pareto points from the o1-optimum to the o2-optimum.

Key physics finding: for PURE AXIAL columns volume<->carbon is DEGENERATE (capacity ~ f'c so Ag ~ 1/f'c, and carbon-index ecc/f'c is monotone decreasing -> highest grade dominates BOTH). The genuine non-dominated conflict is WEIGHT<->CARBON across normalweight vs lightweight concrete at equal strength: LWC lighter (rho 1840 vs 2380) but higher embodied carbon/vol (ecc 0.243 vs 0.127). Real engineering trade (cut floor/seismic mass vs embodied carbon).

Runner scripts/runners/multimaterial_pareto.jl: RC columns, 8 heterogeneous groups, menu [NWC_4000, LWC_4000], MinWeight<->MinCarbon, sweep w over 11 steps via ParetoScalarization. Result: 8 DISTINCT non-dominated designs, genuine conflict YES, every swept design >= both certified single-objective anchors YES, weight span x1.51 (12140->18352 kg), carbon span x1.63 (3755->6125 kgCO2e). Front is richer than a 2-point material flip because the rebar split makes weight and carbon non-collinear WITHIN a section: minimizing weight picks a smaller concrete section with MORE steel, and rebar ecc (1.72) >> concrete ecc, so smaller-section = lower weight but higher carbon. Measurement gotcha fixed: size_columns wraps concrete in ReinforcedConcreteMaterial so the MIP optimizes rebar-split weight/carbon while materials_chosen returns the bare Concrete; design_weight/carbon must pass opts.rebar_material + get_transverse_rebar(opts) to objective_value to stay consistent with what was optimized (gross measurement gave a design below the 'min-carbon' anchor and failed the >=-anchor check).

Scope limit (honest): one capacity checker handles one material family, so a true steel<->concrete Pareto needs a multi-checker extension (future work). The scalarization engine itself is material-agnostic.

Tests: test/optimize/test_pareto_scalarization.jl 25/25 green (pure objective_value contract: exact weighted combo, anchor ordering recovers components, construction validation; integration: pure MinWeight->all-LWC, pure MinCarbon->all-NWC, they differ=conflict, scalarization w=1/w=0 anchors reproduce them). n_max==0 and existing objective paths unchanged (additive).
