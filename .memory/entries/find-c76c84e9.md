---
id: find-c76c84e9
type: finding
project: menegroth
parent_id: plan-63d83cc7
title: 'Overnight recon reshapes the plan: WP2.5 beams ALREADY done; FEA remesh is
  a big FEM change not a quick win; 2 safety flags need user inputs I can''t guess'
node_label: 'Recon: beams done, FEA remesh big, safety inputs needed'
tags: recon,wp25,fea,foundations,safety,corpus,scope
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/optimize/api/beams.jl@f669498, StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/cache.jl@42efbff
session_id: sess-822795b1
created_at: '2026-11-26T16:31:23.793858+00:00'
updated_at: '2026-11-26T16:31:23.793858+00:00'
has_child_rationale: Deep recon before touching safety-critical code found half the
  scope is done/collides/needs sign-off inputs.
---
Findings from recon on the overnight program (plan-63d83cc7):

1. **Slice A (WP 2.5 beams) is ALREADY DONE.** beams.jl:176 now wraps `_sizing_material(opts.material, opts.rebar_material, transverse)` → `ReinforcedConcreteMaterial`, and `precompute_capacities!(::ReinforcedConcreteMaterial)` passes rebar/transverse into `objective_value` → `_rc_objective`, so RC beam obj_coeffs count rebar carbon. Git -L shows it used to pass plain `opts.material` (snapshot 246377490); the RC wrap landed since. Sizing-map rank #11 is STALE for beams. Remaining WP 2.5 = walls + footings only (footings are HOT: foundation Phase C/D active).

2. **Slice B (FEA remesh) is NOT a quick exact win.** fea_mesh_key includes each column's (x,y,c1,c2,shape,position,orientation); a column growth changes the key → acquire_fea_cache! replaces the cache → full remesh, BY DESIGN (the column patch is clipped into the mesh so the column-face geometry drives strip integration + section cuts). 'Fixed mesh + patch stiffness' is a real FEM re-architecture of how the column couples to the slab mesh, with punching/moment-extraction correctness at stake. Not safe to do blind overnight; needs a dedicated careful session.

3. **Column/foundation covering-MILP: notes only** (collides with plan-43330edb one-owner + plan-93430266 D-series + foundation Phase D). See fold-in notes.

4. **Two safety flags need inputs I must NOT guess (code-accuracy rule):**
   - Lateral→foundations (#4): which ASCE 7 load combinations route to footings, AND sliding needs a friction coefficient / geotech input the codebase itself flags as missing (chec-4d790ca0 Phase D: 'needs user inputs for sliding/tension'). Overturning/uplift/base-shear reaction routing is doable without new input; sliding is not.
   - Mat strip statics (#5): the fix reassigns tension faces + changes magnitudes on a mat; face assignment may currently be swapped. Needs a careful ACI 336.2R §6.1.2 derivation + user sign-off, not a guess.

5. **Enabling cladding DL / lateral→foundations by DEFAULT** changes seismic weight W → base shear → every lateral check, wall sizing, and foundation across the whole building. Flipping these on unsupervised overnight is imprudent; better to land behind default-off flags with A/B evidence so the user flips them after review.

RECOMMENDATION: overnight = land the four safety flags as DEFAULT-OFF, corpus-cited, well-tested proposals (byte-identical off) + A/B deltas; steel Cm (F) is the cleanest; do NOT flip defaults or attempt FEA remesh / sliding without the flagged inputs.
