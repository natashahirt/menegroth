---
id: todo-155dcab2
type: todo
project: menegroth
parent_id: todo-cd4f1ef8
title: 'Coordinated: honor params.beam_I_factor / column_I_factor (thread cracking
  factors, no-op at defaults + gate)'
node_label: 'Coordinated: honor params.beam_I_factor / column_I'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-39b9bfe7
created_at: '2026-10-21T15:39:49.565982+00:00'
updated_at: '2026-10-21T15:39:49.565982+00:00'
---
Thread the ACI 318-11 §10.10.4.1 cracking factors from DesignParameters down to the Asap section builders so the declared knobs are actually honored (currently inert; applied values come from hardcoded defaults that happen to equal the param defaults 0.35/0.70).

Call-site inventory (verified):
- design_workflow.jl:909 hardcoded 0.70 → params.column_I_factor
- design_workflow.jl:1110 already params.column_I_factor (ok)
- utils.jl:3872 _apply_column_results!(.,:concrete,.) relies on default 0.70 → thread params.column_I_factor
- utils.jl:3274/3294 _apply_beam_results!(.,opts.material) relies on to_asap_section default 0.35 → thread params.beam_I_factor
- Steel paths (2856, 3808) take no factor (correct).

Threading route: I_factor kwarg through size_beams!/size_columns! → _size_*_impl! → _apply_*_results!, concrete-only branch; callers _size_beams_columns! / _reconcile_columns! pass params.{beam,column}_I_factor. Verified no-op at defaults.

Execution: coordinated graph (engineer → reviewer + critic + tester gate → memory), medium rigor. Gate scripts/runners/verify_i_factor_threading.jl asserts (a) default params ⇒ byte-identical concrete element Ix/Iy/J; (b) non-default knob scales element I by the ratio.
