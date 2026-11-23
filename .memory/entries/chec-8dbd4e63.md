---
id: chec-8dbd4e63
type: checkpoint
project: menegroth
parent_id: deci-62d877ec
title: Single-constraint drift optimality-criteria resizer implemented + closed-loop
  verified
node_label: drift OC resizer
tags: drift,optimality-criteria,virtual-work,sizing,lateral,StructuralSizer,Asap
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/drift_optimality.jl@35421ca, StructuralSizer/src/optimize/_optimize.jl@35421ca,
  StructuralSizer/src/StructuralSizer.jl@35421ca, StructuralSizer/test/optimize/test_drift_optimality.jl@35421ca,
  StructuralSizer/test/runtests.jl@35421ca
session_id: sess-69780ed3
created_at: '2026-11-23T19:15:09.873789+00:00'
updated_at: '2026-11-23T19:15:09.873789+00:00'
has_child_rationale: Implements the optimality-criteria resizer specified in the drift-sizing
  decision
---
## What

Pure, unit-agnostic single-constraint drift resizer `drift_optimality_resize(c, s, w, s_min, δ_allow) -> DriftOptimalityResult` in `StructuralSizer/src/optimize/drift_optimality.jl` (included from `optimize/_optimize.jl`, exported).

Consumes Asap's `drift_participation` coefficients `c_e` (Σc = δ). First-order separable drift model: δ(s') = Σ γ_e/s'_e with γ_e = c_e·s_e. Minimizing weight W=Σ w_e s'_e s.t. δ≤δ_allow gives the optimality criterion s'_e = √(λ γ_e/w_e), KKT stationarity w_e s'_e²/γ_e = λ, single multiplier √λ = (Σ_active √(γ_e w_e))/(δ_allow − Σ_frozen γ_e/s_min_e).

## Design points
- Strength floors via small active-set loop over scalar λ: members whose optimal < s_min are frozen at s_min (still spend γ/s_min of budget), rest share remainder. Converges ≤ n passes.
- Inactive constraint (δ_now ≤ δ_allow) → sizes returned unchanged (active=false). Never over-stiffens an already-compliant system.
- Zero/negative participation members (growth can't help drift) pinned to strength floor up front.
- Pure Float64/SI; FE participation, catalog snap, and outer re-solve loop are the caller's job. Decision deci-62d877ec assumptions honored.

## Verification — 27/27 green (optimize/test_drift_optimality.jl)
- Synthetic: single-member exact (s'=γ/δ_allow), 2-member KKT stationarity equal across members, OC strictly lighter than uniform step-up for same δ_allow (~30%), inactive no-op, strength floor freeze, zero-participation drop-to-floor, input validation.
- **Closed loop vs Asap**: portal frame, tighten to δ_allow=0.6·δ0, iterate resize→`Asap.update!(values_only)`→`solve!`; final drift converges to δ_allow within rtol 3%. Validates the first-order model + factorization-reuse participation end to end.

## Gotchas found
- `el.section.Ix` is Unitful — ustrip before the pure call.
- `update!` is exported by both Asap and StructuralSizer → qualify `Asap.update!`.
- The resize loop MUST `solve!` after each stiffness update before re-querying participation (stale u otherwise → ~10× over-stiffening).

## Next
- Multi-story (multi-λ) + wind serviceability (h/400) constraints; per-DOF I_y/I_z/A participation split (todo drift-multi-constraint).
- Driver in StructuralSynthesizer mapping continuous s' → steel/RC catalog with strength floor; wire into DualSystem high-rise (todo drift-prove).
