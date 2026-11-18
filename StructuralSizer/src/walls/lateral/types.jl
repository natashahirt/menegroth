# ==============================================================================
# Lateral-Force-Resisting System — Evaluator Interface & Reduced Diaphragm Model
# ==============================================================================
# Plan S2. One swappable interface (`AbstractLateralEvaluator`) with two
# fidelities so the layout optimizer and the wall checker are fidelity-agnostic:
#   - `ReducedDiaphragmEvaluator` — cheap, differentiable, 3 DOF/story rigid-
#     diaphragm distribution (this file). Used in the S4 inner loop and as the
#     known-answer oracle for the FEM tier.
#   - `FEMLateralEvaluator` — Asap shells (see `fem_evaluator.jl`), for validating
#     near-optimal survivors only.
#
# The reduced model is the efficiency crux (see plan): with rigid floor
# diaphragms the building's lateral response is 3 DOF per story (u_x, u_y, θ_z)
# regardless of wall count. Each story assembles a 3×3 stiffness
#   K = Σ_i k_i · b_i b_iᵀ           (rank-1 per wall → Woodbury-friendly)
# from per-wall analytic stiffness `k_i` (see `wall_section.jl`) and a geometry
# vector b_i, solves K·u = f, and recovers drift + per-wall forces. Assembly is
# O(nWalls), the solve O(1) per story. Everything is smooth in k_i, so drift and
# wall forces are differentiable (analytic sensitivities below).
#
# Reference for the layout-optimization use of this reduced model:
#   Zhang & Mueller (2017) "Shear wall layout optimization for conceptual design
#   of tall buildings" (corpus: zhang-mueller-2017-shear-wall-layout-opt).
# Torsion / accidental eccentricity per ASCE 7-22 §12.8.4 (VERIFY).

using LinearAlgebra

# ------------------------------------------------------------------------------
# Fail-closed solve policy (numerical safety)
# ------------------------------------------------------------------------------
# A laterally under-braced story has a singular (or, with floating-point assembly
# noise, near-singular) 3×3 stiffness. Papering over that with a pseudo-inverse
# or a `K + εI` diagonal fudge returns a plausible-looking displacement for an
# unstable layout — i.e. it FAILS OPEN. Instead we detect the degeneracy and
# raise, so the caller surfaces a FAIL. This matches the fail-closed house style
# of the flexure / out-of-plane / bearing checkers (refuse rather than invent a
# number).

"""
    SingularStiffnessError(msg)

Raised when a lateral stiffness matrix is singular or so ill-conditioned that its
solution cannot be trusted (e.g. an under-braced story with insufficient or
collinear walls, or an under-constrained FEM model). Callers should surface this
as an infeasible / FAIL result rather than consuming a fabricated displacement.
"""
struct SingularStiffnessError <: Exception
    msg::String
end

Base.showerror(io::IO, e::SingularStiffnessError) = print(io, "SingularStiffnessError: ", e.msg)

# ENGINEERING JUDGMENT (numerical safety, not a code clause): this is a PURE NUMERICAL /
# UNDER-BRACE BACKSTOP, NOT the definition of lateral stability. Lateral stability for the
# reduced tier is now DEFINED, directly from the stiffness EIGENSTRUCTURE, by the
# `eigenstructure_stability` gate: per story it reads the softest translational eigenvalue
# `λmin(K_tt)` and the condensed torsional stiffness about the center of rigidity
# `K_theta_cr` and compares each against a PHYSICAL anti-mechanism floor derived from the
# drift limit. That gate catches translation + diagonal + torsion in one physically-grounded
# check (the `direction_complete_interstory_drift` sweep remains as the translational
# demand / serviceability realization, but it does NOT define stability — being the
# center-of-rigidity translation, it is mathematically blind to the twist DOF). The Phase 10
# unified-FEM survivor cross-check is the FINAL stability authority; this reduced-tier
# eigenstructure gate is the fast proxy. This `rcond` guard remains ONLY as a fail-closed
# backstop so the Cholesky in `_solve_spd` never factorizes a (near-)singular K: a story
# stiffness is treated as numerically singular / under-braced when the reciprocal condition
# number of its SCALE-NORMALIZED stiffness (λ_min/λ_max after non-dimensionalizing the
# rotational DOF — see `_assert_nonsingular_K`) falls to or below this tolerance. The
# raw 3×3 story K mixes units — translational DOFs carry N/m, the rotational DOF N·m,
# the coupling terms N — so λ_min/λ_max of the UNSCALED matrix is NOT dimensionless and
# scales like L_ref² with plan size; the L_ref normalization below removes that plan-
# scale dependence so the BACKSTOP does not falsely reject a large-footprint but well-
# braced layout. What this backstop reliably catches — genuine rank deficiency (an
# unrestrained translational or torsional mode, λ_min → 0) — is origin-invariant
# (rank is preserved under the origin-shift congruence), which is all it must catch
# now that the eigenstructure gate owns the stability decision; the exact normalized
# rcond value is NOT claimed to be an origin-invariant stability margin. The value is
# kept at 1e-8 (not lowered to machine-ε): a near-dead mode this ill-conditioned is
# both numerically untrustworthy to factorize AND, physically, flagged independently
# by the eigenstructure floors, so the two layers agree.
const SINGULAR_STIFFNESS_RCOND = 1e-8

"""
    _assert_nonsingular_K(Ksym, L_ref)

NUMERICAL / under-brace BACKSTOP (not the stability definition — see
[`SINGULAR_STIFFNESS_RCOND`](@ref) and [`eigenstructure_stability`](@ref)): throws
[`SingularStiffnessError`](@ref) if `Ksym` is not positive-definite or is so ill-
conditioned that its Cholesky factorization cannot be trusted (reciprocal condition
number at or below [`SINGULAR_STIFFNESS_RCOND`](@ref)).

The raw story `K` is mixed-unit (translational N/m, rotational N·m, coupling N), so a
bare λ_min/λ_max is NOT a condition number and would scale like `L_ref²` with plan
size. We first non-dimensionalize the rotational DOF by the plan reference length
`L_ref` via `S = diag(1, 1, 1/L_ref)`, forming `K_scaled = S·K·S` whose three entries
are all ~N/m, then test the reciprocal condition number of `K_scaled`. This removes
the plan-SCALE dependence so the backstop does not falsely reject a well-braced large-
footprint layout. It does NOT claim to produce an origin-invariant stability margin:
the exact `rcond` value still depends on the origin, but the only thing this backstop
must catch — genuine rank deficiency (λ_min → 0, an unrestrained translational or
torsional mode) — is origin-invariant, because rank is preserved under the origin-
shift congruence. The actual stability verdict is made elsewhere by the origin-
invariant [`eigenstructure_stability`](@ref) gate (softest translational eigenvalue +
condensed torsional stiffness about the CR). The SOLVE itself (`_solve_spd`) uses
the UNSCALED `K`; the scaling only informs the singular/non-singular decision. Uses
the exact 3×3 symmetric spectrum (cheap) rather than a perturbed factorization.
"""
function _assert_nonsingular_K(Ksym::Symmetric{Float64,Matrix{Float64}}, L_ref::Float64)
    Lr = L_ref > 0 ? L_ref : 1.0
    S = Diagonal([1.0, 1.0, 1.0 / Lr])
    Kscaled = Symmetric(S * Matrix(Ksym) * S)   # ~N/m in every entry (dimensionless rcond)
    λ = eigvals(Kscaled)              # real, ascending (Symmetric ⇒ real spectrum)
    λmin, λmax = first(λ), last(λ)
    if λmax <= 0 || λmin <= SINGULAR_STIFFNESS_RCOND * λmax
        throw(SingularStiffnessError(
            "story stiffness is singular or near-singular " *
            "(scale-normalized λ_min=$(λmin), λ_max=$(λmax), rcond≤$(SINGULAR_STIFFNESS_RCOND), " *
            "L_ref=$(Lr) m): the story is under-braced / laterally unstable."))
    end
    return nothing
end

# ------------------------------------------------------------------------------
# Data model (bare SI: N, m, N/m, rad) — geometry-agnostic so it lives in the
# sizer; the synthesizer supplies these from building geometry.
# ------------------------------------------------------------------------------

"""
    WallLine

One wall pier participating in the lateral system, as plain data (bare SI).

# Fields
- `id::Int`: stable identifier (used to key returned wall forces)
- `x::Float64`, `y::Float64`: plan position of the wall centroid [m]
- `θ::Float64`: orientation of the wall's in-plane (strong) axis [rad, CCW from +X]
- `k::Float64`: in-plane lateral stiffness for this story [N/m]
- `story::Int`: 1-based story index the pier belongs to
"""
struct WallLine
    id::Int
    x::Float64
    y::Float64
    θ::Float64
    k::Float64
    story::Int
end

"""
    StoryLoad

Lateral load applied at a story diaphragm (bare SI). `(Fx, Fy)` act at the
center of mass `(ex, ey)`; the evaluator adds ASCE 7 accidental eccentricity.

# Fields
- `story::Int`: 1-based story index
- `Fx::Float64`, `Fy::Float64`: story force components [N]
- `ex::Float64`, `ey::Float64`: center-of-mass plan position [m]
"""
struct StoryLoad
    story::Int
    Fx::Float64
    Fy::Float64
    ex::Float64
    ey::Float64
end

"""
    LateralResult

Output of any `AbstractLateralEvaluator`. All bare SI.

# Fields
- `story_disp::Matrix{Float64}`: `nStories × 3` interstory displacements `[δx, δy, φ]`
- `drift::Vector{Float64}`: interstory drift ratio per story (dimensionless)
- `wall_forces::Dict{Int,Float64}`: wall id → in-plane shear demand [N]
- `torsion::Vector{Float64}`: torsional amplification `δ_max/δ_avg` per story (≥ 1)
- `wall_forces_withheld::Set{Int}`: ids whose `wall_forces` entry is **not** a
  validated demand (stored as `NaN`). Used by the FEM tier to withhold upper-story
  shear, whose recovery is not yet oracle-validated; empty for the reduced tier and
  for exact base-story recovery. A consumer must treat a withheld id as "unknown /
  infeasible", never as a passing (e.g. zero) demand.

Do NOT index `wall_forces` directly when a withheld id is possible: use
[`is_withheld`](@ref) / [`wall_shear_demand`](@ref), which make the withheld
status explicit instead of relying on `NaN ≤ 1` happening to be `false`.
"""
struct LateralResult
    story_disp::Matrix{Float64}
    drift::Vector{Float64}
    wall_forces::Dict{Int,Float64}
    torsion::Vector{Float64}
    wall_forces_withheld::Set{Int}
end

# Convenience constructor: a result with no withheld walls (the common case —
# the reduced evaluator and the exact FEM base-story recovery). Keeps existing
# 4-argument call sites working unchanged.
LateralResult(story_disp, drift, wall_forces, torsion) =
    LateralResult(story_disp, drift, wall_forces, torsion, Set{Int}())

"""
    is_withheld(res::LateralResult, id::Integer) -> Bool

`true` when wall `id`'s force in `res.wall_forces` is a **withheld / unvalidated**
sentinel (member of `res.wall_forces_withheld`, stored as `NaN`) rather than a
trustworthy in-plane shear demand. Currently only the FEM tier withholds (its
not-yet-oracle-validated upper-story shear); the reduced tier withholds nothing.

Consumers MUST gate on this (or on [`wall_shear_demand`](@ref)) before using a
force: a withheld id is "unknown", never a passing (e.g. zero) demand. Relying on
`NaN ≤ 1` evaluating to `false` is NOT an acceptable substitute — it couples a
safety decision to IEEE-754 comparison semantics and silently breaks the moment
any consumer takes `abs`, sums, or defaults the force first.
"""
is_withheld(res::LateralResult, id::Integer) = id in res.wall_forces_withheld

"""
    wall_shear_demand(res::LateralResult, id::Integer) -> Union{Float64,Nothing}

Safe accessor for a validated per-wall in-plane shear demand [N]. Returns the
finite demand when wall `id` was validated, or `nothing` when its force is
WITHHELD (see [`is_withheld`](@ref)) or otherwise non-finite. Returning `nothing`
rather than a `NaN` forces every consumer to make an explicit skip / mark-
infeasible decision for a withheld id instead of silently propagating a `NaN`.
An id absent from `wall_forces` reads as `0.0` (no participation), matching a
plain `get(..., 0.0)` lookup.
"""
function wall_shear_demand(res::LateralResult, id::Integer)
    is_withheld(res, id) && return nothing
    v = get(res.wall_forces, id, 0.0)
    isnan(v) && return nothing   # defensive: a stray NaN is still "unknown"
    return v
end

# ------------------------------------------------------------------------------
# Evaluator interface
# ------------------------------------------------------------------------------

"""Abstract lateral-analysis evaluator. Subtypes implement [`evaluate_lateral`](@ref)."""
abstract type AbstractLateralEvaluator end

"""
    evaluate_lateral(ev, walls, loads) -> LateralResult

Distribute `loads` (Vector{StoryLoad}) to `walls` (Vector{WallLine}) and return a
[`LateralResult`](@ref). Same signature for every fidelity tier.
"""
function evaluate_lateral end

# ------------------------------------------------------------------------------
# Reduced rigid-diaphragm evaluator (cheap, differentiable)
# ------------------------------------------------------------------------------

"""
    ReducedDiaphragmEvaluator

Cheap 3-DOF-per-story rigid-diaphragm lateral evaluator (plan S2).

EXACT CORNER-DRIFT / TORSION CERTIFICATION (requires geometry): the twist-sensitive metrics
(max-corner interstory drift, torsional amplification, torsional stability floor) are
evaluated at the FOUR TRUE occupant corners `plate_center ± (hx, hy)`. They therefore need
the true floor-plate geometric CENTER `plate_center` in addition to the plate HALF-extents
`plan_halfwidth = (hx, hy)`. The corner displacement is then EXACT — correct even when the
center of rigidity lies OUTSIDE the plate (the non-orthogonal rev6 case) — with no slack.

FAILS CLOSED without geometry: when `plate_center === nothing` (the default) the reduced tier
CANNOT locate the corners, so corner-drift / torsion CERTIFICATION is UNAVAILABLE. It must
NEVER fall back to the wall centroid, the DOF origin `(0, 0)`, or a plate-span lever bound —
each of those proxies was proven to UNDER-state eccentric / non-orthogonal interstory corner
drift and return an over-limit layout as feasible (crit5 eccentric core; rev6 non-orthogonal
CR-outside-plate; crit6 origin / undersized-plate). Instead corner drift and torsion report
`Inf`, and `solve_wall_layout` returns `feasible = false`, `status = :geometry_required`. The
FRAME-INDEPENDENT checks (translational eigenstructure floor, per-wall shear, singular fail-
closed solve) still run without `plate_center`; only the twist certification is withheld. The
Phase 10 unified-FEM survivor check (true geometry) remains the accuracy AUTHORITY.

ENCLOSURE CONTRACT (fail-closed, crit7): the exact four-corner metrics are exact ONLY when the
plate `plate_center ± plan_halfwidth` ENCLOSES the drift-relevant points. The reduced model
has NO independent occupant outline, so `plate_center`/`plan_halfwidth` is CONTRACTUALLY the
TRUE occupant diaphragm expressed in the `WallLine` frame. As a checkable proxy for the
(uncheckable here) requirement occupants ⊆ plate, the tier enforces WALLS ⊆ plate at runtime
via [`_plate_encloses_walls`](@ref): when any story's walls fall OUTSIDE the plate, the
twist-sensitive metrics FAIL CLOSED to `Inf` exactly as for a missing `plate_center`, and
`solve_wall_layout` refuses the layout with `status = :geometry_inconsistent`. RESIDUAL NOT
caught here: a plate that encloses the walls but is declared SMALLER than the true occupant
diaphragm (walls ⊆ plate ⊂ occupants) — delegated to the caller contract and the FEM survivor
check (true geometry, the final authority).

# Fields
- `story_heights::Vector{Float64}`: story heights [m], index = story
- `plan_halfwidth::NTuple{2,Float64}`: plate HALF-extent `(hx, hy) = (Lx/2, Ly/2)` [m]; the
  four occupant corners are `plate_center ± (hx, hy)`
- `plate_center::Union{Nothing,NTuple{2,Float64}}`: TRUE floor-plate geometric center
  `(cx, cy)` [m], expressed in the SAME frame as `WallLine.x, y`. `nothing` (default) disables
  corner-drift / torsion certification and fails the tier closed (see above)
- `accidental_ecc::Float64`: ASCE 7 accidental eccentricity fraction (default 0.05)

Stories are treated as independent (interstory) shear-building springs; cantilever flexural
coupling across stories is the FEM tier's job.
"""
Base.@kwdef struct ReducedDiaphragmEvaluator <: AbstractLateralEvaluator
    story_heights::Vector{Float64}
    plan_halfwidth::NTuple{2,Float64} = (0.0, 0.0)
    plate_center::Union{Nothing,NTuple{2,Float64}} = nothing
    accidental_ecc::Float64 = 0.05
end

