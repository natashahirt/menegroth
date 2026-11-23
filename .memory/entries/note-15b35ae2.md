---
id: note-15b35ae2
type: note
project: menegroth
parent_id: expe-10235d3c
title: 'Fixed beam explain_feasibility RC dispatch: optimize_discrete passed RC sizing-material
  → generic ''aggregate'' fallback instead of per-check explanation'
node_label: 'Fixed beam explain_feasibility RC dispatch: optimi'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aci/beams/t_checker.jl@e9ce024, StructuralSizer/src/members/codes/aci/beams/checker/checker_diagnostics.jl@e9ce024
session_id: sess-97eb7119
created_at: '2026-11-23T17:04:49.158081+00:00'
updated_at: '2026-11-23T17:04:49.158081+00:00'
---
Root-caused the pre-existing failure in concrete_beam/test_joist_ribs.jl 'check_tbeam_section reports what the sizer reported' (2 fails + 1 error).

Cause: both the rectangular (RCBeamSection) and T-beam (RCTBeamSection) explain_feasibility methods dispatch on material::Concrete only. is_feasible has RC overloads delegating to .concrete (t_checker.jl:254), but explain_feasibility did NOT. optimize_discrete._explain_chosen passes the _sizing_material (a ReinforcedConcreteMaterial) → dispatch fell through to the generic explain_feasibility(::AbstractCapacityChecker,...) fallback (interface.jl:182), which returns governing_check='aggregate', one CheckResult, ratio 0.0. So res.explanations (sizer-reported) was the degenerate 'aggregate' explanation while check_tbeam_section (which passes opts.material = Concrete) produced the real 6-check 'flexure'-governed explanation → mismatch.

Fix: added RC explain_feasibility overloads for RCBeamSection and RCTBeamSection that delegate to .concrete, exactly mirroring the is_feasible RC pattern. Since _sizing_material(concrete,...).concrete === opts.material.concrete, the sizer's explanation now matches check_tbeam_section's.

Verified: concrete_beam/test_joist_ribs.jl + test_tbeam.jl → 2661/2661 pass (was 2 fail + 1 error). Broader sweep (signed_demands, torsion, rc_rebar_objective, tbeam_optimization, rib_sets) 291/291 pass. Safe: the overloads only change dispatch (strength/serviceability use concrete; rebar is objective-only), and the capacity cache already holds the RC-derived fy.
