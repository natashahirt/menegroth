---
id: chec-deb01717
type: checkpoint
project: menegroth
parent_id: plan-00ace284
title: Column/slab pipeline re-audit fixes implemented (uncommitted); Phase B items
  held for the no-ratchet session
node_label: Column/slab pipeline re-audit fixes implemented (u
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9127bb29
created_at: '2026-11-09T02:23:45.174564+00:00'
updated_at: '2026-11-09T02:23:45.174564+00:00'
---
Done (uncommitted, tests pass: StructuralSizer 1384/1384 targeted + punching/integrity/foundation files; StructuralSynthesizer core/test_flat_plate_member_stage.jl 322/322):
- φPn,max cap (ACI 318-11 §10.3.6) in biaxial checks (`_axial_design_cap`); checker uses |Muy| and rejects non-finite demands.
- Bar redesign (`_reinforcement_adequate` / `resize_column_with_reinforcement`) takes geometry + βdns and applies δns; both orientations only when Muy > tol (wall piers keep strong-axis Mu).
- `_update_column_sizes!`: change on c1 OR c2; slenderness geometry passed for rect sections.
- Positional `size_columns`: single curvature M1 = −M2 (Cm = 1). RCColumnDemand docstring no longer calls M1 = 0 conservative (struct default unchanged).
- Edge punching superposes both moments (parallel-axis with Vu·e shift + symmetry-axis with γv(b2,b1), Jc⊥). Slab kernel picks axes from free-edge dir (`_edge_moment_pairs`); shared `punching_check` (footings) takes the worse of both assignments because callers' Mux/Muy labels are inconsistent (FoundationDemand.Mux convention unverified).
- Secondary one-way shear on d_inner in Phase C and `phase_a_depth_passes`.
- Integrity §13.3.8.5 prescriptive: `integrity_bottom_bars!`, `design_integrity_check` (≥2 column-strip bottom bars per direction; secondary reported unverified when not designed, i.e. DDM/EFM/rule-of-thumb). Old force formula kept only for report generators.
- Synthesizer: `rc_frame_column_check` for columns outside the flat-plate full-load check; missing punching data -> not ok; monotone stacking `_stack_flat_plate_columns!` inside `check_flat_plate_columns!` loop; `designed_above` staleness record.
Held for other session: Phase B stale moments, flat-slab d in remedies, edge outer section in punching_resolution.jl, Phase A secondary shear call in iteration.jl.
Sway: plan-5e222c49.
Tooling gotcha: test_quiet routed a StructuralSynthesizer run to the StructuralSizer server on port 18400 (both servers on same port?) — use --fresh.
