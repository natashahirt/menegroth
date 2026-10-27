---
id: deci-f3faf903
type: decision
project: menegroth
parent_id: deci-82d2484a
title: Report element-by-material takeoff and keep the designed column bars
node_label: Report element-by-material takeoff and keep the de
tags: embodied-carbon, takeoff, rebar, columns
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/StructuralSynthesizer.jl@9921c53, StructuralSynthesizer/src/design_types.jl@9921c53,
  StructuralSynthesizer/src/design_workflow.jl@9921c53, StructuralSynthesizer/src/postprocess/ec.jl@9921c53,
  StructuralSynthesizer/test/core/test_postprocess_ec.jl@9921c53, scripts/runners/sweep_case_runner.jl@9921c53
session_id: sess-797711ba
created_at: '2026-10-27T19:34:22.158330+00:00'
updated_at: '2026-10-27T19:34:22.158330+00:00'
---
DesignSummary now carries a MaterialTakeoff for slabs, columns, beams, struts, and foundations. Each holds concrete volume, rebar mass, structural-steel mass, and the embodied carbon of those three, summed from the same element volumes as the carbon split. The sweep CSV writes those fields.

Flat-plate reconciliation was replacing the P-M section with four #8 bars, so column rebar mass did not depend on the design. An unchanged cross-section now keeps those bars. A grown column keeps them when they still satisfy ACI 318-11 §10.9.1 (0.01Ag ≤ As ≤ 0.08Ag; corpus: aci-318-11, page 148) and otherwise receives the least standard layout inside that window. The slab moment is not stored on the column, so this path does not run a new P-M design.

test_postprocess_ec.jl: 80 passed. logs/sweep_carbon_takeoff.csv was written before this bar fix, so its column rebar masses are the four-#8 values.
