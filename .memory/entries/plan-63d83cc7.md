---
id: plan-63d83cc7
type: plan
project: menegroth
parent_id: plan-267f93b4
title: 'Overnight program: WP 2.5 beam carbon objective, FEA remesh speedup, + four
  safety flags (cladding DL & lateral→foundations enabled; mat statics & steel Cm
  default-off proposals)'
node_label: 'Overnight: WP2.5 beams + FEA remesh + 4 safety flags'
tags: overnight,optimization,safety,wp25,carbon,foundations,steel-cm,mat,corpus,sizing
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-822795b1
created_at: '2026-11-26T16:27:42.711913+00:00'
updated_at: '2026-11-26T16:27:42.711913+00:00'
has_child_rationale: 'User reviewed all tiers + safety flags, chose: integration branch,
  enable the two safety-increasing flags by default, do all 5 scope items overnight.'
---
## Mandate (user decisions, 2026-11-26)
- Branch: stay on integration/2026-11-18, resolve conflicts as they arise (it is HOT: concurrent one-owner column refactor plan-43330edb + foundation Phase C/D chec-4d790ca0).
- Safety autonomy: corpus-cited analysis + fix per flag; ENABLE the two safety-INCREASING flags by default (cladding dead load consumer; lateral/pattern reactions reaching foundations); the two equation-change flags (mat strip statics, steel Cm) land DEFAULT-OFF with corpus writeups for sign-off.
- Scope (all): safety flags x4; WP 2.5 rebar in RC beam objective; FEA flat-plate remesh speedup; fold column/foundation covering-MILP ideas into existing plans; WP 2.5 walls+footings too (footings hot — care).

## Prior art that reshapes this (from memory)
- expe-6dcbaa95: column shrink-and-verify already built; shrinking raised carbon +4.8% because RC objective is rebar-blind → WP 2.5 (rebar in objective) is the real lever, not a shrink pass.
- Flat-plate COLUMN objective already counts rebar (ReinforcedConcreteMaterial in _column_cache_material). RC beams/walls/footings still gross (map rank #11). Precedent runner: scripts/runners/wp25_carbon_ab.jl.
- plan-43330edb one-owner columns + plan-93430266 D-series grouping own the column-selection turf; do NOT build a parallel column optimizer — feed ideas in as notes.
- Foundation Phase D (per-combination envelopes, 20% col-load rule, sliding/tension) needs user geotechnical inputs; sliding cannot be fully implemented without a friction coefficient.

## Slice order (bank low-risk/no-corpus-gate first)
A. WP 2.5 beams: rebar in RC beam obj_coeffs (mirror column ReinforcedConcreteMaterial). Capacity byte-identical; only objective moves. No corpus gate (embodied-carbon weighting). checker_objectives.jl / checker_cache.jl.
B. FEA flat-plate remesh: column size is in mesh key → remesh every column step. Fixed mesh + patch stiffness / key on geometry. Exact/bit-identical. SS/slabs/.../fea/cache.jl.
C. SAFETY (enable): cladding dead load. GravityLoads.wall_SDL (10 psf default) has no consumer → missing from perimeter gravity, W, foundations. Corpus: ASCE 7 dead-load definition. phase0/seismic-weight-and-foundation-lateral.md Issue A.
D. SAFETY (enable, partial): lateral/pattern reactions → foundations (overturning/uplift/base shear). FoundationDemand single (P,M) → per-combination. Sliding deferred (needs friction input). Corpus: ASCE 7 load combos. Issue B. HOT (foundation Phase D).
E. SAFETY (default-off proposal): mat strip statics per ACI 336.2R §6.1.2 Step 3 vs current §8.3.3 beam coeffs; face assignment looks swapped. Issue D.
F. SAFETY (default-off proposal): steel Cm. Current 0.6 for all steel compression members under-amplifies (unconservative up to 1.67x). AISC 360-16 App.8 §8.2.1: Cm=1.0 single-curvature/transversely loaded. Pass signed M1/M2. Issue C.
G. Notes: write column/foundation covering-MILP ideas into plan-43330edb and foundation Phase D.

## Invariants
- Every slice: recon → (corpus if code-derived, cite source_id+clause+page) → implement → test (flag-off byte-identical where flagged) → memory record → surgical commit. 
- Default-off flags byte-identical when off. Safety-increasing enables carry a regression + capacity-preserving check.
- code-accuracy: stop and ask if any spec/sign/unit/combo ambiguity before generating code.
