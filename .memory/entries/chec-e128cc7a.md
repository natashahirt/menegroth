---
id: chec-e128cc7a
type: checkpoint
project: menegroth
parent_id: menegroth
title: 'Rib deflection: Ie ratchet hardened (max_iter 4->8, converges), :sensitive
  l/480 kept'
node_label: 'Rib deflection: Ie ratchet hardened (max_iter 4->8'
tags: ribbed-floors,deflection,convergence,aci
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/rib_deflection.jl@f3c8521,
  StructuralSynthesizer/src/analyze/members/members/rib_story.jl@f3c8521
session_id: sess-f0597650
created_at: '2026-11-20T00:24:57.237706+00:00'
updated_at: '2026-11-20T00:24:57.237706+00:00'
---
Follow-up to chec-b8ddfab2. Investigated the ribbed story-1 deflection failure: it is REAL, not an artifact. Confirmed element_deflection_profile returns absolute global-Z station displacement, _bay_surface uses the 4 column-top displacements, _bay_span is the longest SIDE (~12 m / 39 ft, not a diagonal), and Delta_lt = lambda_D*Delta_S + (Delta_DL - Delta_S) with lambda_D=2.0 is the correct ACI 318-11 §9.5.2.5 incremental form (no double-count). ACI min-thickness l/21 deemed-to-satisfy does NOT cover the stricter :sensitive l/480 partition-damage limit, so there is no contradiction; a 39-ft waffle genuinely fails l/480 (~25 mm total long-term) at every available stem depth up to 24 in (30 in total).

User decision: KEEP rib_deflection_limit=:sensitive (l/480). The story is correctly reported infeasible; the system (not the sizing) must change (deeper / shorter span / PT).

Hardening (max_iter raised 4->8 in story_rib_deflection; report_rib_deflection! now warns when the Ie ratchet does not converge, noting the reported ratio is a lower bound since stiffness only ratchets down). Rerun grid/x1y1 dense_waffle: converged=true on every story now, long-term ratio holds at a true 1.5x (no longer a lower bound).

STILL OPEN: overall pass=false on Beam 138 is_feasible 1.51 (a girder) — user deprioritized for now.
