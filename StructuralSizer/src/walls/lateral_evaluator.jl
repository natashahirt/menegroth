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

"""
    _wall_geometry_vector(w) -> (cx, cy, r)

The rank-1 geometry vector `b = [cx, cy, cy·x − cx·y]` for a wall: the axial
deformation of the pier under a rigid-diaphragm displacement `u = [δx, δy, φ]`
is `b·u`, and the pier force is `k·(b·u)`. `(cx, cy)` is the in-plane axis unit
vector; the third term is the moment arm about the origin.
"""
@inline function _wall_geometry_vector(w::WallLine)
    cx = cos(w.θ); cy = sin(w.θ)
    return (cx, cy, cy * w.x - cx * w.y)
end

"""
    _assemble_story_K(walls_in_story) -> (K::Matrix, walls)

Assemble the 3×3 story stiffness `K = Σ k_i b_i b_iᵀ` about the plan origin.
"""
function _assemble_story_K(walls::Vector{WallLine})
    K = zeros(3, 3)
    for w in walls
        b = _wall_geometry_vector(w)
        bv = (b[1], b[2], b[3])
        @inbounds for a in 1:3, c in 1:3
            K[a, c] += w.k * bv[a] * bv[c]
        end
    end
    return K
end

"""
    _center_of_rigidity(K) -> (xr, yr)

Plan coordinates of the story CENTER OF RIGIDITY (CR) — the point at which a pure
diaphragm translation induces no twist — from the 3×3 story stiffness `K = Σ k_i
b_i b_iᵀ` assembled about the plan origin (see [`_assemble_story_K`](@ref)). The CR is
where the translation–rotation coupling vanishes: measuring the torsional arms about
`(xr, yr)` zeros the `K[1,3]`/`K[2,3]` coupling terms. Setting those shifted coupling
terms to zero gives the 2×2 system

    [ K12  −K11 ] [xr]   [K13]
    [ K22  −K12 ] [yr] = [K23]      (det = K11·K22 − K12² = |translational block| > 0).

The determinant is the translational-block determinant, which is strictly positive for
any story braced in two independent directions (and hence whenever `_solve_spd` has not
already failed closed on a singular `K`). Using the CR as the drift/torsion reference
makes the reported response ORIGIN-INVARIANT: for a symmetric core `K13 = K23 = 0`, so
`CR = (0,0)` and the arithmetic is identical to the origin-referenced form (existing
known-answer tests are unchanged).
"""
@inline function _center_of_rigidity(K::AbstractMatrix{Float64})
    K11 = K[1, 1]; K12 = K[1, 2]; K22 = K[2, 2]
    K13 = K[1, 3]; K23 = K[2, 3]
    det = K11 * K22 - K12 * K12          # translational-block determinant (> 0 if 2-way braced)
    # CR GUARD: a non-SPD translational block (det ≤ 0) means the two translational modes
    # are not independent — the layout is a translational MECHANISM — and the CR is
    # undefined. Fail closed here rather than dividing by a zero/negative determinant and
    # propagating NaN CR coordinates into drift/torsion. `_solve_spd` normally catches this
    # first; this guard makes the helper robust regardless of call ordering.
    det > 0 || throw(SingularStiffnessError(
        "translational block is singular (det(K_tt)=$(det) ≤ 0): the two translational " *
        "modes are not independent (a translational mechanism); center of rigidity undefined."))
    xr = (K11 * K23 - K12 * K13) / det
    yr = (K12 * K23 - K22 * K13) / det
    return (xr, yr)
end

"""
    _translational_block_spectrum(K) -> (; λmin, λmax, det, vmin)

Closed-form spectrum of the 2×2 TRANSLATIONAL block `K_tt = K[1:2, 1:2]` of a 3-DOF story
stiffness. `K_tt` is ORIGIN-INVARIANT (the translation–translation coupling does not involve
the moment arm) and BOTH of its entries carry units N/m, so its eigenvalues are directly
comparable without the rotational-DOF scaling the full 3×3 needs.

For the symmetric block `[K11 K12; K12 K22]` the eigenvalues are closed form,
`λ = (tr ± √(tr² − 4·det))/2`, with `tr = K11 + K22` and `det = K11·K22 − K12²`. The
discriminant equals `(K11 − K22)² + 4·K12² ≥ 0` exactly, so it is CLAMPED at 0 to absorb
tiny-negative round-off before the square root. `λmin` is the SOFTEST translational mode
(its interstory stiffness in the worst translational direction) and `vmin` is that mode's
unit eigenvector — the TRUE worst translational direction, which subsumes a discrete +X/+Y
drift sweep and closes the √2 diagonal-weak-mode gap. `det` (the translational-block
determinant) is returned for the CR / mechanism guards.
"""
@inline function _translational_block_spectrum(K::AbstractMatrix{Float64})
    K11 = K[1, 1]; K12 = K[1, 2]; K22 = K[2, 2]
    tr  = K11 + K22
    det = K11 * K22 - K12 * K12
    disc = tr * tr - 4 * det
    disc < 0 && (disc = 0.0)                 # clamp tiny-negative-from-roundoff
    s = sqrt(disc)
    λmax = 0.5 * (tr + s)
    λmin = 0.5 * (tr - s)
    # Eigenvector for λmin of the symmetric block ((K_tt − λmin·I)·v = 0). Choose the
    # larger-norm of the two row-orthogonal candidates for numerical robustness.
    v1 = (K12, λmin - K11)
    v2 = (λmin - K22, K12)
    v  = (abs(v1[1]) + abs(v1[2])) >= (abs(v2[1]) + abs(v2[2])) ? v1 : v2
    nrm = hypot(v[1], v[2])
    vmin = nrm > 0 ? (v[1] / nrm, v[2] / nrm) : (1.0, 0.0)
    return (λmin = λmin, λmax = λmax, det = det, vmin = vmin)
end

"""
    _torsional_stiffness_cr(K) -> K_theta_cr

Condensed TORSIONAL stiffness about the center of rigidity, via the SCHUR COMPLEMENT of the
translational block of the 3-DOF story stiffness:

    K_theta_cr = K33 − [K13 K23]·inv(K_tt)·[K13; K23]
               = K33 − (K22·K13² − 2·K12·K13·K23 + K11·K23²)/det(K_tt).

This is the rotational stiffness that remains once the diaphragm is free to translate to its
CR (the two translation DOFs statically condensed out). It is ORIGIN-INVARIANT and DIRECTLY
observes twist stiffness — the quantity the center-of-rigidity-translation drift metric is
mathematically blind to (the CR translation is independent of φ by the CR's defining
property). For a positive-definite `K` the Schur complement is strictly positive; it → 0
exactly when the diaphragm can twist about the CR as a mechanism. Requires `det(K_tt) > 0`
(the translational block invertible); callers guard that first.
"""
@inline function _torsional_stiffness_cr(K::AbstractMatrix{Float64})
    K11 = K[1, 1]; K12 = K[1, 2]; K22 = K[2, 2]
    K13 = K[1, 3]; K23 = K[2, 3]; K33 = K[3, 3]
    det = K11 * K22 - K12 * K12
    quad = (K22 * K13 * K13 - 2 * K12 * K13 * K23 + K11 * K23 * K23) / det
    return K33 - quad
end

"""
    _cr_translation(u, cr) -> (tx, ty)

Rigid-body translation of the CENTER OF RIGIDITY `cr = (xr, yr)` given the origin-
referenced story displacement `u = [δx, δy, φ]`. A rigid diaphragm displaces the
physical point `(x, y)` by `(δx − φ·y, δy + φ·x)`, so the CR translation is
`(δx − φ·yr, δy + φ·xr)`. This is the ORIGIN-INVARIANT translation component used for
interstory drift and torsional-amplification `δ_avg`: it is the physical displacement
of a physical point, independent of the arbitrary input origin.
"""
@inline function _cr_translation(u::AbstractVector{Float64}, cr::NTuple{2,Float64})
    xr, yr = cr
    return (u[1] - yr * u[3], u[2] + xr * u[3])
end

"""
    _wall_centroid(walls_s) -> (cx, cy)

Per-story geometric centroid (arithmetic mean) of the wall plan positions.

SUPERSEDED AS A PLAN-CENTER ANCHOR (crit5): this was formerly used as an origin-covariant
PROXY for the plan center — the anchor the TRUE plan corners `plan_center ± (hx, hy)` and the
CR-to-corner lever were measured from. `crit5` proved that proxy UNSAFE: for an eccentric
service core (walls clustered at one end) the wall centroid coincides with the center of
rigidity, so corners anchored to it miss the true far plate corner and the corner-drift /
torsional-lever metrics UNDER-state the twist. The corner-drift and torsional-floor metrics
now anchor the corners to the TRUE floor-plate center `ReducedDiaphragmEvaluator.plate_center`
(the four occupant corners `plate_center ± (hx, hy)`) and FAIL CLOSED when it is absent —
they never use this wall centroid.

This helper is RETAINED only as a plain geometric utility (and for tests that reference it);
it must NOT be reintroduced as the corner-drift plan-center anchor. Returns `(0.0, 0.0)` for
an empty wall list.
"""
@inline function _wall_centroid(walls_s::Vector{WallLine})
    isempty(walls_s) && return (0.0, 0.0)
    sx = 0.0; sy = 0.0
    for w in walls_s
        sx += w.x; sy += w.y
    end
    n = length(walls_s)
    return (sx / n, sy / n)
end

"""
    _reference_length(ev, walls_s) -> Float64

Plan reference length `L_ref` [m] used to non-dimensionalize the rotational DOF of
a 3×3 story stiffness before the conditioning test in [`_assert_nonsingular_K`](@ref).
Prefers a plan dimension (the larger of the two plan extents `2·plan_halfwidth`).
If `plan_halfwidth` is unset `(0,0)`, falls back to the largest wall radial offset
from the plan origin (ENGINEERING JUDGMENT: a defensible geometric length scale for
the torsional arm when no plan extent is supplied); if that is also zero (all walls
at the origin) returns `1.0`, under which a genuinely unrestrained rotational mode
still reads as singular.
"""
function _reference_length(ev::ReducedDiaphragmEvaluator, walls_s::Vector{WallLine})
    Lplan = max(2 * ev.plan_halfwidth[1], 2 * ev.plan_halfwidth[2])
    Lplan > 0 && return Lplan
    Lgeom = maximum((hypot(w.x, w.y) for w in walls_s); init = 0.0)
    return Lgeom > 0 ? Lgeom : 1.0
end

"""
    _plate_encloses_walls(ev::ReducedDiaphragmEvaluator, walls_s, active_ids=nothing) -> Bool

ENCLOSURE GUARD (fail-closed) for the reduced-tier corner-drift / torsion certification.
Returns `true` iff `plate_center` is present AND every ACTIVE `WallLine` `w` in `walls_s` lies
inside (or exactly on) the plate rectangle `plate_center ± plan_halfwidth`:

    cx − hx − tol ≤ w.x ≤ cx + hx + tol    AND    cy − hy − tol ≤ w.y ≤ cy + hy + tol

with `(cx, cy) = plate_center`, `(hx, hy) = plan_halfwidth`.

WHY (crit7): the four-corner max-drift / torsion metrics are EXACT only over the rectangle
`plate_center ± plan_halfwidth` (convexity of `|disp(p)|²` in the plan point `p`), and are
exact for the TRUE occupant diaphragm ONLY when that rectangle ENCLOSES every drift-relevant
point. `plate_center` and `plan_halfwidth` are two FREE, caller-supplied fields and nothing
else cross-checks them against the wall positions, so an UNDER-COVERING plate (e.g. the core
half-extent mistaken for the full floor) makes BOTH plate-anchored gates (corner drift AND the
`res.torsion` amplification ratio) silently UNDER-state the real edge drift while the only
plate-independent gate (`util_trans`) is twist-blind — the exact formula then fails OPEN.

This predicate enforces the CHECKABLE proxy WALLS ⊆ plate for the real (uncheckable here)
requirement occupants ⊆ plate: the reduced model carries no independent occupant outline, so
the caller's `plate_center`/`plan_halfwidth` is CONTRACTUALLY the true occupant diaphragm in
the `WallLine` frame. The Phase 10 unified-FEM survivor check (true geometry) is the FINAL
authority. RESIDUAL NOT CAUGHT: a plate that encloses the walls but is declared SMALLER than
the true occupant diaphragm (walls ⊆ plate ⊂ occupants) is uncatchable here — it is delegated
to the caller contract + the FEM survivor check.

ENGINEERING JUDGMENT (tolerance, not a code clause): `tol = 1e-9 + 1e-9·hypot(hx, hy)` — an
absolute floor plus a plate-SCALED relative term — so a wall EXACTLY on the plate boundary
(`|w.x − cx| == hx`) PASSES despite floating-point assembly noise, while a genuine over-hang
(even a few mm beyond a plan-scale plate) FAILS closed. The test is ORIGIN-INVARIANT: walls
and plate translate together, so a joint origin shift leaves every inequality unchanged.

ENGINEERING JUDGMENT (degenerate plate, not a code clause): a NEGATIVE half-extent (`hx < 0`
or `hy < 0`) is a nonsensical / inverted plate and is treated as NON-enclosing (fail closed). A
ZERO half-extent (a thin, axis-aligned plate) is NOT force-failed: it is left to the per-wall
bounds below, which ENCLOSE walls lying ON that axis (within `tol`) and FAIL-CLOSE any wall OFF
it. This keeps legitimately degenerate plans certifiable (e.g. a line of walls all at `x = cx`
declared with `plan_halfwidth = (0, hy)`) while a genuinely SPREAD layout declared under a
zero-extent plate still fails closed through the per-wall bounds. An empty `walls_s` is
vacuously enclosed.

ACTIVE-ID MASK (`active_ids`, ENGINEERING JUDGMENT — not a code clause): the SIMP optimizer
drives REMOVED candidates to the void floor `ρ_min` but keeps them in `walls_s` (their stiffness
is floored to prevent an exactly-singular `K`, never deleted). A removed candidate parked
OUTSIDE the plate must NOT flip this gate — it is physically absent. The OPTIMIZER (which alone
holds the densities `x`, `ρ_min`, and `penal`) computes the Set of ACTIVE candidate ids and
passes it in; when `active_ids !== nothing` any wall with `w.id ∉ active_ids` is SKIPPED before
the bounds test. `active_ids === nothing` (the default) treats EVERY wall as active, so the
one-shot CHECK path and the FEM tier are byte-for-byte unchanged.

HOW ACTIVITY IS DEFINED (and why `ρ_min`'s magnitude is IRRELEVANT): a candidate is ACTIVE iff
its PENALIZED stiffness fraction `ρ^penal > ε_abs` — the fraction of `k_max` actually assembled
into `K` (`_active_candidate_ids`; `k = ρ^penal·k_max`). This is a PER-WALL ABSOLUTE test against
a fixed constant, so it degrades to "ALL active" (guard fully armed) as `ρ_min → 1` and NEVER to
"all removed": at `ρ_min=1.0` every `ρ^penal = 1 > ε_abs`, so no wall is masked and this gate
cannot silently disable itself. The earlier LINEAR test (`ρ` vs `ρ_min·(1+ε)`) FAILED OPEN at a
legal `ρ_min=1.0`, where every density is pinned at the floor yet still carries full stiffness —
the whole active set went empty and the gate became vacuously true for all layouts. The absolute
`ρ^penal` test removes that dependence on `ρ_min`'s magnitude entirely.

An all-removed / empty-after-mask set is vacuously enclosed (same rule as an empty `walls_s`).
This is a BACKSTOP, not a hole: with the absolute `ρ^penal` threshold an empty active set occurs
ONLY when every wall is truly void (`ρ^penal ≤ ε_abs` everywhere) = a global mechanism, which the
load-independent singular-stiffness / translational / eigenstructure floors fail closed on
INDEPENDENTLY of this gate. The negative-half-extent (inverted plate) branch, by contrast, fires
BEFORE the mask (crit-P2): a NON-EMPTY `walls_s` with an inverted plate fails closed regardless of
which walls are active.

WHY RELATIVE STIFFNESS IS NEVER USED TO INFER REMOVAL: a relative-stiffness threshold (comparing
one wall's `k` to OTHERS') would be UNSAFE — one very stiff inside wall could push a genuinely
REAL outside wall below the threshold and silently skip it, under-stating the certified drift (the
exact-formula-fails-OPEN failure mode this guard exists to prevent). "Removed" is therefore the
optimizer's PER-WALL ABSOLUTE `ρ^penal` density fact, never a quantity this predicate reconstructs
by comparing `w.k` across walls.
"""
function _plate_encloses_walls(ev::ReducedDiaphragmEvaluator, walls_s::Vector{WallLine},
                               active_ids::Union{Nothing,AbstractSet}=nothing)
    ev.plate_center === nothing && return false
    isempty(walls_s) && return true                 # vacuously true: nothing to enclose
    cx, cy = ev.plate_center
    hx, hy = ev.plan_halfwidth
    # NEGATIVE (inverted) half-extent on a NON-EMPTY wall set ⇒ cannot enclose (fail closed),
    # INDEPENDENT of the active-ID mask (crit-P2). An inverted / garbage `plan_halfwidth` must
    # never report "enclosed", so this fires BEFORE the per-wall loop and mask skip: a non-empty
    # `walls_s` with an inverted plate fails closed regardless of WHICH walls are active (the
    # empty-`walls_s` case already returned vacuously-true above). A ZERO half-extent is NOT
    # force-failed — it is left to the per-wall bounds below (encloses on-axis walls within
    # `tol`, fails closed on off-axis walls) so a valid thin/axis-aligned plan is not rejected.
    (hx < 0 || hy < 0) && return false
    tol = 1e-9 + 1e-9 * hypot(hx, hy)               # absolute + plate-scaled boundary tolerance
    for w in walls_s
        # ACTIVE-ID MASK (ENGINEERING JUDGMENT, not a code clause): when `active_ids` is
        # supplied, SKIP any wall the optimizer has driven to negligible penalized stiffness
        # (`w.id ∉ active_ids`). A density-REMOVED candidate is physically absent, so it can
        # neither be enclosed nor fail-close the gate — it is simply not examined. Activity is
        # the optimizer's PER-WALL ABSOLUTE `ρ^penal > ε_abs` fact (`_active_candidate_ids`),
        # never a RELATIVE comparison to other walls, so a genuinely real outside wall can never
        # be silently skipped (see docstring). `active_ids === nothing` ⇒ every wall is examined,
        # byte-for-byte identical to the one-shot CHECK / FEM tiers.
        active_ids === nothing || w.id in active_ids || continue
        (cx - hx - tol <= w.x <= cx + hx + tol) || return false
        (cy - hy - tol <= w.y <= cy + hy + tol) || return false
    end
    # EMPTY-AFTER-MASK BACKSTOP: if the mask skipped every wall (empty active set) this returns
    # vacuously true — SAFE, not a hole: an empty active set means every wall is truly void
    # (ρ^penal ≤ ε_abs everywhere) = a global mechanism, which the load-independent singular-
    # stiffness / translational / eigenstructure floors fail closed on independently of this gate.
    return true
end

# FEM tier (and any non-reduced evaluator) carries TRUE geometry and is NOT subject to the
# reduced-tier enclosure proxy, so it always "encloses" — mirrors
# `_plate_center_missing(::AbstractLateralEvaluator) = false`. Keeps FEM unaffected. The
# optional `active_ids` arg is accepted (and ignored) so the two arities match the reduced
# method and the mask threads transparently through evaluator-agnostic call sites.
_plate_encloses_walls(::AbstractLateralEvaluator, ::Vector{WallLine},
                      ::Union{Nothing,AbstractSet}=nothing) = true

function evaluate_lateral(ev::ReducedDiaphragmEvaluator,
                          walls::Vector{WallLine},
                          loads::Vector{StoryLoad};
                          active_ids::Union{Nothing,AbstractSet}=nothing)
    nstory = length(ev.story_heights)
    story_disp = zeros(nstory, 3)
    drift = zeros(nstory)
    torsion = ones(nstory)
    wall_forces = Dict{Int,Float64}()
    for w in walls
        wall_forces[w.id] = 0.0
    end

    # Cumulative story shear: the shear a story resists is the sum of the lateral
    # forces applied at and above it (shear-building idealization).
    for s in 1:nstory
        walls_s = [w for w in walls if w.story == s]
        isempty(walls_s) && continue
        K = _assemble_story_K(walls_s)

        # Cumulative force + torsional moment about the origin from all loads
        # at/above this story, including ASCE 7 accidental eccentricity (VERIFY).
        Fx = 0.0; Fy = 0.0; Mz = 0.0
        Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
        for ld in loads
            ld.story < s && continue
            Fx += ld.Fx; Fy += ld.Fy
            eax = ev.accidental_ecc * Lx
            eay = ev.accidental_ecc * Ly
            # Mz = Fy·x − Fx·y ; accidental eccentricity worsens the moment.
            Mz += ld.Fy * (ld.ex + sign_nonzero(ld.Fy) * eax) -
                  ld.Fx * (ld.ey + sign_nonzero(ld.Fx) * eay)
        end
        f = [Fx, Fy, Mz]

        u = _solve_spd(K, f, _reference_length(ev, walls_s))
        story_disp[s, :] .= u

        # Center of rigidity for this story (origin-invariant drift/torsion reference).
        # Safe: `_solve_spd` above has already confirmed `K` is positive-definite, so
        # the translational block is PD ⇒ `_center_of_rigidity`'s determinant is > 0.
        cr = _center_of_rigidity(K)

        # Interstory drift ratio for this story. This is a TRUE per-story
        # relative (interstory) displacement, NOT an absolute/cumulative-from-
        # base quantity: story `s` is modeled as an isolated 3-DOF spring whose
        # stiffness `K` is assembled only from story-`s` walls (`walls_s`), and
        # `u = K⁻¹ f` is therefore the deformation ACROSS story `s` alone under
        # that story's cumulative shear `f`. No base-to-floor accumulation enters
        # `u`, so `sqrt(u[1]^2 + u[2]^2)` is the relative translation between the
        # floors bounding story `s`, and dividing by the story height `h` gives
        # the interstory drift ratio Δ/h_sx compared against the allowable story
        # drift Δ_a (ASCE 7-22 §12.12.1 / Table 12.12-1, PDF p. 194-195).
        #
        # IDEALIZATION & LIMITATION: this is a shear-building model — stories are
        # DECOUPLED springs with NO cantilever flexural coupling across stories,
        # so this drift intentionally omits the rigid-body rotation a lower story
        # imposes on the ones above. Rigorous coupled multistory (cantilever)
        # drift is delegated to the unified-FEM tier (`FEMLateralEvaluator`); this
        # reduced value is a fast, differentiable inner-loop proxy, not a
        # substitute for it.
        #
        # ORIGIN INVARIANCE: the interstory drift is the magnitude of the rigid-body
        # translation of the diaphragm CENTER OF RIGIDITY (`_cr_translation`), not of
        # the arbitrary input origin. Both are identical when there is no twist (φ = 0)
        # or when the layout is symmetric (CR = origin), so this is backward-compatible
        # with the known-answer tests; it differs only for a torsionally-responding
        # asymmetric layout, where the CR translation is the physically meaningful,
        # origin-independent drift.
        h = ev.story_heights[s]
        tx, ty = _cr_translation(u, cr)
        drift[s] = h > 0 ? sqrt(tx^2 + ty^2) / h : 0.0

        # Torsional amplification δ_max/δ_avg (ASCE 7 §12.8.4.3 torsional-irregularity
        # metric; VERIFY) — EXACT realization at the four TRUE occupant corners. δ_avg is
        # taken at the CR so the ratio is origin-invariant; δ_max is evaluated EXACTLY over
        # the corners `plate_center ± (hx, hy)` (`_torsion_amplification` 4-arg; exact lever
        # `hypot(hx + |xr − cx|, hy + |yr − cy|)`), correct even when the CR lies outside the
        # plate. This GATES feasibility (the `res.torsion/torsion_limit` slot in
        # `constraint_fns` / `solve_wall_layout`). When `plate_center === nothing` the corners
        # cannot be located, so torsion certification is UNAVAILABLE and we FAIL CLOSED with
        # `Inf` — never a wall-centroid / origin / plate-span proxy (crit5/rev6/crit6); the
        # callers then refuse the layout (status=:geometry_required).
        #
        # ENCLOSURE GUARD (crit7, fail-closed): the four-corner metric is EXACT only if the
        # plate `plate_center ± plan_halfwidth` ENCLOSES the drift-relevant points. The two
        # FREE fields `plate_center`/`plan_halfwidth` are not otherwise cross-checked against
        # the wall positions, so an UNDER-COVERING plate would make this gate silently under-
        # state the twist (exact formula fails OPEN). When this story's walls are not ⊆ plate
        # we therefore also FAIL CLOSED to `Inf` (see `_plate_encloses_walls`); callers refuse
        # with `status = :geometry_inconsistent`.
        # `active_ids` masks density-removed candidates out of the enclosure proxy so a removed
        # wall parked outside the plate cannot fail-close this gate (nothing ⇒ all walls, as the
        # one-shot CHECK path and FEM tier require).
        torsion[s] = (ev.plate_center === nothing || !_plate_encloses_walls(ev, walls_s, active_ids)) ? Inf :
                     _torsion_amplification(u, ev.plan_halfwidth, cr, ev.plate_center)

        # Recover per-wall in-plane shear force: V_i = k_i (b_i · u).
        for w in walls_s
            b = _wall_geometry_vector(w)
            wall_forces[w.id] = w.k * (b[1]*u[1] + b[2]*u[2] + b[3]*u[3])
        end
    end

    return LateralResult(story_disp, drift, wall_forces, torsion)
end

"""Sign that returns +1 for zero (so accidental eccentricity is always additive)."""
@inline sign_nonzero(x::Real) = x < 0 ? -1.0 : 1.0

"""
    _solve_spd(K, f, L_ref) -> u

Solve the 3×3 story system `K u = f` for a well-conditioned, positive-definite `K`.
FAILS CLOSED: a singular or near-singular `K` (a story with insufficient or
collinear walls to be laterally stable) raises [`SingularStiffnessError`](@ref)
rather than returning a pseudo-inverse or `K + εI`-perturbed solution that would
look plausible for an unstable layout. `L_ref` is the plan reference length used
to scale-normalize the conditioning test (see [`_assert_nonsingular_K`](@ref));
the SOLVE itself is an exact, unperturbed Cholesky on the UNSCALED `K`, so valid
results are not altered."""
function _solve_spd(K::Matrix{Float64}, f::Vector{Float64}, L_ref::Float64)
    Ksym = Symmetric(K)
    _assert_nonsingular_K(Ksym, L_ref)  # fail closed on singular / near-singular K
    return cholesky(Ksym) \ f
end

"""
    _torsion_amplification(u, halfwidth, cr, plan_center) -> δ_max/δ_avg

Corner drift amplification `δ_max/δ_avg` from the rigid-body displacement `u = [δx, δy,
φ]`, evaluating `δ_max` over the four corners `plan_center ± (hx, hy)`. `δ_avg` is the
translation magnitude at the diaphragm CENTER OF RIGIDITY `cr = (xr, yr)` (`_cr_translation`,
origin-invariant); each corner displacement is the rigid-diaphragm field
`disp(p) = (δx − φ·p_y, δy + φ·p_x) = δ_avg(CR) + φ × (p − CR)`.

USED BY the reduced evaluator (4-arg) once `ReducedDiaphragmEvaluator.plate_center` is known:
the corners are anchored to that TRUE plate center `(cx, cy)`, so the amplification is EXACT
regardless of where the CR sits (crit5/rev6 showed the earlier wall-centroid and plate-span-
bound proxies UNDER-stated an eccentric / non-orthogonal core, and both are removed). The FEM
tier (`fem_evaluator.jl`) uses the 2-arg form, whose master-node displacements are already
referenced to the diaphragm master at the DOF origin.
"""
function _torsion_amplification(u::Vector{Float64}, halfwidth::NTuple{2,Float64},
                                cr::NTuple{2,Float64}, plan_center::NTuple{2,Float64})
    tx, ty = _cr_translation(u, cr)
    δavg = sqrt(tx^2 + ty^2)
    δavg < 1e-12 && return 1.0
    hx, hy = halfwidth
    cx, cy = plan_center
    φ = u[3]
    δmax = δavg
    for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
        px = cx + sx * hx; py = cy + sy * hy     # TRUE corner anchored to the plan center
        dx = u[1] - φ * py                       # rigid-diaphragm displacement about the
        dy = u[2] + φ * px                       # DOF origin: (δx − φ·p_y, δy + φ·p_x)
        δmax = max(δmax, sqrt(dx^2 + dy^2))
    end
    return δmax / δavg
end

# 3-arg form: plan center defaults to the DOF origin (the model's natural frame, in which
# the plan is centered at the origin). Reduces exactly to evaluating the corners at
# `(±hx, ±hy)`.
_torsion_amplification(u::Vector{Float64}, halfwidth::NTuple{2,Float64},
                       cr::NTuple{2,Float64}) =
    _torsion_amplification(u, halfwidth, cr, (0.0, 0.0))

# Backward-compatible 2-arg form (CR AND plan center at the origin): preserves the prior
# behavior EXACTLY for callers that reference displacements to the plan origin — e.g. the
# FEM tier's master-node displacements in `fem_evaluator.jl`, which are already measured at
# the diaphragm master and NOT part of this origin-invariance change.
_torsion_amplification(u::Vector{Float64}, halfwidth::NTuple{2,Float64}) =
    _torsion_amplification(u, halfwidth, (0.0, 0.0), (0.0, 0.0))

# Principal plan directions swept by the direction-complete stability check:
# +X = (1,0) and +Y = (0,1). ENGINEERING JUDGMENT: sweeping BOTH principal
# directions (not only the design load's direction) is a mechanism-prevention
# safeguard — a layout braced only along the design load leaves the orthogonal
# diaphragm-translation mode a near-zero-stiffness mechanism that a direction-aligned
# drift check cannot see. Motivated by (but NOT a verbatim magnitude from) ASCE 7-22
# §12.5 "Direction of Loading"; we deliberately do NOT invent the ASCE orthogonal-load
# combination magnitudes (that is Phase 6's job) — we reuse the SUPPLIED design
# resultant magnitude, swept into each axis.
const _DIRECTION_COMPLETE_DIRS = ((:X, 1.0, 0.0), (:Y, 0.0, 1.0))

"""
    direction_complete_interstory_drift(ev, walls, loads; active_ids=nothing) -> (; directions, drift, corner_drift)

`active_ids` (optional) is the SIMP optimizer's Set of ACTIVE candidate ids; when supplied it
masks density-removed walls out of the per-story enclosure proxy (see [`_plate_encloses_walls`]).
`nothing` (default) examines every wall, leaving the one-shot CHECK / FEM paths unchanged.

DIRECTION-COMPLETE, origin-invariant per-story interstory drift sweep. Returns BOTH a
serviceability realization (`drift`, the CR translation) AND the physical drift SAFETY
quantity (`corner_drift`, the EXACT max-corner interstory drift):

  * `drift[s, d]` — magnitude of the CENTER-OF-RIGIDITY translation (`_cr_translation`),
    the translational demand / serviceability realization. It is mathematically blind to
    the twist DOF φ (the CR translation is independent of φ by the CR's defining property),
    so it is NOT the stability/drift-limit authority; it is retained for serviceability and
    for the existing origin-invariant known-answer tests.
  * `corner_drift[s, d]` — the EXACT max-corner interstory drift over the FOUR TRUE occupant
    corners `plate_center ± (hx, hy)`. The rigid-diaphragm displacement of corner `p` is
    `disp(p) = (δx − φ·p_y, δy + φ·p_x)` (= `CR translation + φ × (p − CR)`), and
    `corner_drift = max_p hypot(disp(p)) / h` — EXACT, with NO slack, and CORRECT even when
    the CR lies outside the plate (the non-orthogonal rev6 case). This is the quantity ASCE
    7-22 §12.12.1 limits: the design story drift Δ ≤ allowable Δ_a from Table 12.12-1, with Δ
    taken AT THE BUILDING EDGES including diaphragm rotation (ASCE 7-22 §12.8.6.5); torsion
    enters it DIRECTLY and UNCAPPED through φ, and it is what `constraint_fns` /
    `solve_wall_layout` use for the drift feasibility check (corpus: asce-7-22; §12.12.1 PDF
    p. 194; §12.8.6.5 PDF p. 188). When `ev.plate_center === nothing` the corners cannot be
    located, so `corner_drift` FAILS CLOSED to `Inf` (certification unavailable) — it NEVER
    falls back to the wall centroid, the DOF origin, or a plate-span lever bound (crit5/rev6/
    crit6). The Phase 10 unified-FEM survivor check (true geometry) is the accuracy authority.

For each story `s` it forms the cumulative applied lateral-load RESULTANT MAGNITUDE
`F_s = hypot(ΣFx, ΣFy)` over all loads at/above `s` (exactly the story-shear resultant
the primal `evaluate_lateral` already forms), then evaluates the drift under a CANONICAL
load set that does NOT depend on the design load's direction: the full resultant swept
into `+X = (F_s, 0)` and `+Y = (0, F_s)` (see `_DIRECTION_COMPLETE_DIRS`). Each canonical
case carries the SAME accidental-eccentricity torsion companion used by `evaluate_lateral`
— identical `eax`/`eay`, `sign_nonzero`, and `ev.accidental_ecc` (ASCE 7-22 §12.8.4.2.2) —
applied at the force-weighted participation centroid of the loads at/above `s`.

Both metrics are origin-invariant: the CR translation (`_cr_translation`) is the physical
displacement of a physical point, and the corners `plate_center ± (hx, hy)` translate WITH
the walls+loads (the `plate_center` is in the same frame as `WallLine.x, y`), so translating
walls+loads+plate_center jointly leaves `corner_drift` and `drift` unchanged.

A near-dead principal direction produces a large FINITE value there (good Ipopt gradient,
no throw), so the per-story MAX over directions smoothly becomes infeasible when any
principal mode is unbraced. Fails closed (`SingularStiffnessError`) only on a genuinely
singular `K` via `_solve_spd`.
"""
function direction_complete_interstory_drift(ev::ReducedDiaphragmEvaluator,
                                             walls::Vector{WallLine},
                                             loads::Vector{StoryLoad};
                                             active_ids::Union{Nothing,AbstractSet}=nothing)
    nstory = length(ev.story_heights)
    ndir = length(_DIRECTION_COMPLETE_DIRS)
    D = zeros(nstory, ndir)
    C = zeros(nstory, ndir)
    Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
    for s in 1:nstory
        walls_s = [w for w in walls if w.story == s]
        isempty(walls_s) && continue
        K = _assemble_story_K(walls_s)
        Lref = _reference_length(ev, walls_s)
        h = ev.story_heights[s]

        # Cumulative story-shear resultant magnitude F_s = hypot(ΣFx, ΣFy) and the
        # force-weighted participation centroid (ex_c, ey_c) of the loads at/above s,
        # where the equivalent resultant is applied for the torsion companion.
        Fx = 0.0; Fy = 0.0; wsum = 0.0; exc = 0.0; eyc = 0.0
        for ld in loads
            ld.story < s && continue
            Fx += ld.Fx; Fy += ld.Fy
            wl = hypot(ld.Fx, ld.Fy)
            wsum += wl; exc += wl * ld.ex; eyc += wl * ld.ey
        end
        F_s = hypot(Fx, Fy)
        if wsum > 0
            exc /= wsum; eyc /= wsum
        end
        eax = ev.accidental_ecc * Lx
        eay = ev.accidental_ecc * Ly

        # CR is the reference for the (origin-invariant) serviceability drift; the EXACT
        # corner metric anchors the four occupant corners to the TRUE plate center. Both are
        # safe when the canonical solve below does not throw — i.e. K is PD, so the
        # translational block is PD and the CR is well-defined.
        cr = _center_of_rigidity(K)
        center = ev.plate_center
        hx, hy = ev.plan_halfwidth
        # ENCLOSURE GUARD (crit7, fail-closed): the EXACT four-corner drift below is exact only
        # when the plate `plate_center ± plan_halfwidth` ENCLOSES the drift-relevant points. An
        # UNDER-COVERING plate (the two FREE fields are not otherwise cross-checked against the
        # walls) would make this metric under-state the real edge drift — the exact formula
        # fails OPEN. Fail closed to `Inf` when this story's walls are not ⊆ plate (see
        # `_plate_encloses_walls`); computed ONCE per story (direction-independent). `active_ids`
        # masks density-removed candidates (nothing ⇒ all walls, as the CHECK/FEM paths require).
        encloses = _plate_encloses_walls(ev, walls_s, active_ids)

        for (di, (_, dx, dy)) in enumerate(_DIRECTION_COMPLETE_DIRS)
            Fxc = F_s * dx; Fyc = F_s * dy
            # Accidental-eccentricity torsion companion, term-for-term as in
            # `evaluate_lateral` (ASCE 7-22 §12.8.4.2.2), for the equivalent resultant
            # acting at (exc, eyc): Mz = Fy·(ex + sign·eax) − Fx·(ey + sign·eay).
            Mz = Fyc * (exc + sign_nonzero(Fyc) * eax) -
                 Fxc * (eyc + sign_nonzero(Fxc) * eay)
            u = _solve_spd(K, [Fxc, Fyc, Mz], Lref)   # fail-closed on singular K
            # (1) CR-translation drift (serviceability realization, φ-blind). PRESERVED.
            tx, ty = _cr_translation(u, cr)
            D[s, di] = h > 0 ? sqrt(tx^2 + ty^2) / h : 0.0
            # (2) EXACT max-corner interstory drift over the four TRUE occupant corners
            # `plate_center ± (hx, hy)` (ASCE 7-22 §12.12.1, Δ at the building edges incl.
            # diaphragm rotation per §12.8.6.5). The rigid-diaphragm displacement of corner
            # `p` is `(δx − φ·p_y, δy + φ·p_x)`; `corner_drift = max_p hypot(disp(p))/h`,
            # EXACT (no slack) and correct even when the CR lies outside the plate (rev6).
            # FAIL CLOSED to `Inf` when `plate_center === nothing` — no wall-centroid / origin
            # / plate-span proxy (crit5/rev6/crit6; corpus: asce-7-22, §12.12.1 PDF p. 194;
            # §12.8.6.5 PDF p. 188). Also fail closed when the plate UNDER-COVERS this story's
            # walls (`!encloses`, crit7) — same reason the exact metric would otherwise fail OPEN.
            if center === nothing || !encloses
                C[s, di] = Inf
            else
                cx, cy = center
                cdrift = 0.0
                for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
                    px = cx + sx * hx; py = cy + sy * hy
                    cdrift = max(cdrift, hypot(u[1] - u[3] * py, u[2] + u[3] * px))
                end
                C[s, di] = h > 0 ? cdrift / h : 0.0
            end
        end
    end
    return (directions = Symbol[d[1] for d in _DIRECTION_COMPLETE_DIRS],
            drift = D, corner_drift = C)
end

"""
    eigenstructure_stability(ev, walls, loads, drift_limit; active_ids=nothing) -> NamedTuple

`active_ids` (optional) is the SIMP optimizer's Set of ACTIVE candidate ids; when supplied it
masks density-removed walls out of the torsional-floor enclosure proxy (see
[`_plate_encloses_walls`]). `nothing` (default) examines every wall, leaving the one-shot CHECK /
FEM paths unchanged.

EIGENSTRUCTURE STABILITY GATE (reduced tier) — the stability authority for the cheap tier.
It reads the story stiffness EIGENSTRUCTURE directly (translational spectrum + condensed
torsional stiffness about the center of rigidity) and compares each against a PHYSICAL
anti-mechanism floor derived from the SAME drift limit `DL = drift_limit`. One check catches
translation + diagonal + torsion; the Phase 10 unified-FEM survivor cross-check is the FINAL
authority, and this is its fast proxy.

Per story `s`, from the assembled 3-DOF `K` over `[ux, uy, θ]`:

  * TRANSLATIONAL floor — require `λmin(K_tt) ≥ k_req_trans = F_s/(h·DL)`.
    Derivation: a resultant-equivalent edge load `F_s` acting on a translational mode of
    stiffness `k` produces interstory drift `δ/h = F_s/(k·h)`; requiring `δ/h ≤ DL` gives
    `k ≥ F_s/(h·DL)`. `λmin(K_tt)` is the softest translational mode (its eigenvector is the
    true worst direction), so this subsumes the discrete +X/+Y drift sweep and closes the √2
    diagonal-weak-mode gap. Utilization `util_trans = k_req_trans/λmin(K_tt)`.

  * TORSIONAL floor — require `K_theta_cr ≥ k_req_tors = F_s·e_acc·r_ref/(h·DL)`.
    Derivation: the accidental-torsion moment `M_acc = F_s·e_acc` twists the diaphragm by
    `φ = M_acc/K_theta_cr`; a plan corner at radius `r` from the CR then drifts `φ·r`, and
    `φ·r/h ≤ DL` gives `K_theta_cr ≥ M_acc·r/(h·DL)`. `r_ref` is the EXACT max CR-to-corner
    lever `max_corner hypot(corner − CR) = hypot(hx + |xr − cx|, hy + |yr − cy|)` over the four
    TRUE occupant corners `plate_center ± (hx, hy)` — correct even when the CR lies outside the
    plate. `K_theta_cr` (the Schur complement of `K_tt`) DIRECTLY observes the twist stiffness
    the CR-translation drift cannot. Utilization `util_tors = k_req_tors/K_theta_cr`. When
    `plate_center === nothing` the lever cannot be located: the torsional floor is UNAVAILABLE
    and FAILS CLOSED (`k_req_tors = util_tors = Inf`); the TRANSLATIONAL floor and the load-
    independent mechanism guards need no `plate_center` and still run.

`F_s = hypot(ΣFx, ΣFy)` is the per-story cumulative design-shear resultant magnitude —
EXACTLY the resultant `evaluate_lateral` / `direction_complete_interstory_drift` form. `e_acc`
and the plan dimensions are taken identically to `evaluate_lateral` so the two stay
consistent (see the ENGINEERING JUDGMENT comment below for `e_acc`).

The demand floors SCALE with `F_s`: a story with ~zero cumulative resultant has ~zero floor
and so cannot be the authority for a mechanism in an UNLOADED story. That case is handled by
the LOAD-INDEPENDENT mechanism guards here — a translational block at/below the numeric
singular threshold, or a condensed torsional stiffness at/below the numeric singular scale,
throws [`SingularStiffnessError`](@ref) regardless of load — plus the fail-closed `rcond`
backstop in `_solve_spd`. So a zero-shear story can NEVER silently waive the stability gate
for a genuine mechanism.

Returns per-story vectors `λmin_tt`, `λmax_tt`, `K_theta_cr`, `k_req_trans`, `k_req_tors`,
`util_trans`, `util_tors` (NaN/0 entries for stories with no walls). Throws
[`SingularStiffnessError`](@ref) on a genuine (load-independent) translational or torsional
mechanism; callers in the differentiable optimizer loop wrap it to a penalty sentinel.
"""
function eigenstructure_stability(ev::ReducedDiaphragmEvaluator,
                                  walls::Vector{WallLine},
                                  loads::Vector{StoryLoad},
                                  drift_limit::Real;
                                  active_ids::Union{Nothing,AbstractSet}=nothing)
    nstory = length(ev.story_heights)
    λmin_tt = fill(NaN, nstory); λmax_tt = fill(NaN, nstory)
    K_theta = fill(NaN, nstory)
    k_req_trans = zeros(nstory); k_req_tors = zeros(nstory)
    util_trans = zeros(nstory); util_tors = zeros(nstory)

    Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
    # `r_ref` (the EXACT max CR-to-corner lever) is computed PER STORY in the loop below as
    # `max_corner hypot(corner − CR)` over the four TRUE occupant corners `plate_center ±
    # (hx, hy)` = `hypot(hx + |xr − cx|, hy + |yr − cy|)`. This is correct even when the CR
    # lies outside the plate (the non-orthogonal rev6 case). It REPLACES the removed plate-span
    # bound `hypot(2·hx, 2·hy)` and the earlier wall-centroid-eccentric estimate, both of which
    # could MIS-state the lever (crit5/rev6/crit6). When `plate_center === nothing` the corners
    # cannot be located and the torsional floor FAILS CLOSED (`util_tors = Inf`).
    # ENGINEERING JUDGMENT (direction-complete accidental eccentricity, not a code clause):
    # `evaluate_lateral` applies accidental eccentricity `accidental_ecc·L` about each plan
    # axis (eax = accidental_ecc·Lx, eay = accidental_ecc·Ly; accidental torsion per
    # ASCE 7-22 §12.8.4.2.2, as cited in `evaluate_lateral`). For the direction-complete
    # torsional floor we use the LARGER plan dimension, `e_acc = accidental_ecc·max(Lx, Ly)`,
    # so the floor bounds the accidental twist for a resultant in the worst direction
    # (conservative, consistent with sweeping both principal directions per §12.5). Reuses
    # the SAME `ev.accidental_ecc` as the primal — no invented ASCE magnitude.
    e_acc = ev.accidental_ecc * max(Lx, Ly)

    for s in 1:nstory
        walls_s = [w for w in walls if w.story == s]
        isempty(walls_s) && continue
        K = _assemble_story_K(walls_s)
        Lref = _reference_length(ev, walls_s)
        h = ev.story_heights[s]

        spec = _translational_block_spectrum(K)
        # LOAD-INDEPENDENT translational-mechanism guard (also the CR guard): K_tt is
        # unit-homogeneous (N/m), so λmin/λmax is a true reciprocal condition number. At or
        # below the numeric singular threshold the translational modes are a mechanism.
        if spec.λmax <= 0 || spec.λmin <= SINGULAR_STIFFNESS_RCOND * spec.λmax
            throw(SingularStiffnessError(
                "story $s translational block is singular / a mechanism " *
                "(λmin_tt=$(spec.λmin), λmax_tt=$(spec.λmax), rcond ≤ $(SINGULAR_STIFFNESS_RCOND)): " *
                "under-braced in a principal translational direction."))
        end

        Kθ = _torsional_stiffness_cr(K)
        # LOAD-INDEPENDENT torsional-mechanism guard. `K_theta_cr` carries units N·m; its
        # natural scale is λmax(K_tt)·L_ref² (translational stiffness × plan length²). A
        # condensed torsional stiffness at/below the numeric singular scale is a twist
        # mechanism — caught here REGARDLESS of applied shear, so a zero-shear story with a
        # torsional mechanism is not silently waived by the demand-scaled floor below.
        tors_scale = spec.λmax * Lref * Lref
        if Kθ <= SINGULAR_STIFFNESS_RCOND * tors_scale
            throw(SingularStiffnessError(
                "story $s condensed torsional stiffness about the CR is singular / a mechanism " *
                "(K_theta_cr=$(Kθ) ≤ rcond·λmax·L_ref² = $(SINGULAR_STIFFNESS_RCOND * tors_scale)): " *
                "the diaphragm can twist freely about the center of rigidity."))
        end

        # Cumulative design-shear resultant magnitude F_s (same resultant as the primal).
        Fx = 0.0; Fy = 0.0
        for ld in loads
            ld.story < s && continue
            Fx += ld.Fx; Fy += ld.Fy
        end
        F_s = hypot(Fx, Fy)

        # TRANSLATIONAL anti-mechanism floor from the SAME drift limit DL (derivation above).
        # Frame-independent — needs no plate_center — so it always runs.
        kqt = (h > 0 && drift_limit > 0) ? F_s / (h * drift_limit) : 0.0
        λmin_tt[s] = spec.λmin; λmax_tt[s] = spec.λmax; K_theta[s] = Kθ
        k_req_trans[s] = kqt
        util_trans[s] = kqt / spec.λmin

        # TORSIONAL floor. Both guards above have passed, so the translational block is PD and
        # the CR is well-defined. When plate_center is known, use the EXACT max CR-to-corner
        # lever `r_ref = max_corner hypot(corner − CR)` over the four TRUE occupant corners
        # `plate_center ± (hx, hy)`. When plate_center === nothing the lever cannot be located:
        # FAIL CLOSED (util_tors = Inf) — never a plate-span / origin proxy (crit5/rev6/crit6).
        # ENCLOSURE GUARD (crit7): also fail closed when the plate UNDER-COVERS this story's
        # walls (`!_plate_encloses_walls`) — the exact CR-to-corner lever is a valid torsional
        # floor only over a plate that encloses the drift-relevant points; an under-covering
        # plate would under-state `r_ref` and let the floor fail OPEN. The TRANSLATIONAL floor
        # and the load-independent mechanism guards above do NOT consult the guard and still run.
        # `active_ids` masks density-removed candidates out of the enclosure proxy (nothing ⇒
        # all walls, as the one-shot CHECK path and FEM tier require).
        if ev.plate_center === nothing || !_plate_encloses_walls(ev, walls_s, active_ids)
            k_req_tors[s] = Inf
            util_tors[s]  = Inf
        else
            cr = _center_of_rigidity(K)
            cx, cy = ev.plate_center
            hx, hy = ev.plan_halfwidth
            r_ref = 0.0
            for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
                r_ref = max(r_ref, hypot(cx + sx * hx - cr[1], cy + sy * hy - cr[2]))
            end
            kqr = (h > 0 && drift_limit > 0) ? F_s * e_acc * r_ref / (h * drift_limit) : 0.0
            k_req_tors[s] = kqr
            util_tors[s]  = kqr / Kθ
        end
    end

    return (λmin_tt = λmin_tt, λmax_tt = λmax_tt, K_theta_cr = K_theta,
            k_req_trans = k_req_trans, k_req_tors = k_req_tors,
            util_trans = util_trans, util_tors = util_tors)
end

# ------------------------------------------------------------------------------
# Analytic sensitivities (∂ of drift / wall force w.r.t. each wall stiffness k_i)
# ------------------------------------------------------------------------------
# For u = K⁻¹ f with K = Σ k_i b_i b_iᵀ (f independent of k_i):
#   ∂u/∂k_i = −K⁻¹ (b_i b_iᵀ) u
# These support gradient-based layout optimization without finite differences.

"""
    story_drift_sensitivity(ev, walls, loads, story) -> Dict{Int,Float64}

Analytic `∂(drift_story)/∂k_i` for every wall `i` in `story`. Uses the adjoint of
the 3×3 story system (no finite differences).
"""
function story_drift_sensitivity(ev::ReducedDiaphragmEvaluator,
                                 walls::Vector{WallLine},
                                 loads::Vector{StoryLoad},
                                 story::Int)
    walls_s = [w for w in walls if w.story == story]
    sens = Dict{Int,Float64}(w.id => 0.0 for w in walls_s)
    isempty(walls_s) && return sens

    K = _assemble_story_K(walls_s)
    # Assemble the SAME load vector `f` as `evaluate_lateral`, INCLUDING the ASCE
    # 7-22 §12.8.4.2 accidental-eccentricity terms (5% of the plan dimension
    # perpendicular to each force direction; corpus: asce-7-22 §12.8.4.2.2, PDF
    # p. 187), so this analytic gradient is the exact derivative of the drift the
    # evaluator actually reports. Must stay term-for-term identical to the Mz
    # built in `evaluate_lateral` (same eax/eay, same `sign_nonzero` convention,
    # same `ev.accidental_ecc`); a mismatch here silently differentiates a
    # different load case than the primal.
    Fx = 0.0; Fy = 0.0; Mz = 0.0
    Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
    for ld in loads
        ld.story < story && continue
        Fx += ld.Fx; Fy += ld.Fy
        eax = ev.accidental_ecc * Lx
        eay = ev.accidental_ecc * Ly
        # Mz = Fy·x − Fx·y ; accidental eccentricity worsens the moment.
        Mz += ld.Fy * (ld.ex + sign_nonzero(ld.Fy) * eax) -
              ld.Fx * (ld.ey + sign_nonzero(ld.Fx) * eay)
    end
    f = [Fx, Fy, Mz]
    # Fail closed on a singular / near-singular story before solving (mirrors
    # `_solve_spd`): no `K + εI` fudge, no silent sensitivity on an unstable layout.
    # Same scale-normalized conditioning test (same L_ref) as the primal.
    Ksym = Symmetric(K)
    _assert_nonsingular_K(Ksym, _reference_length(ev, walls_s))
    Kfac = cholesky(Ksym)
    u = Kfac \ f
    h = ev.story_heights[story]
    δ = sqrt(u[1]^2 + u[2]^2)
    (h <= 0 || δ < 1e-12) && return sens

    # NOTE: this analytic sensitivity differentiates the ORIGIN-referenced translation
    # drift `sqrt(u₁²+u₂²)/h`, which equals the CENTER-OF-RIGIDITY drift that
    # `evaluate_lateral` now reports whenever there is no twist (φ = 0) or the layout
    # is symmetric (CR = origin) — the regime of the known-answer FD test. It is a
    # verified standalone utility, NOT the optimizer's gradient source: Ipopt uses
    # numerical gradients of the direction-complete `constraint_fns`, so the layout
    # solve is differentiating the actual (origin-invariant, direction-complete) drift.
    # d(drift)/dk_i = (1/h) * (u_xy · du_xy/dk_i)/δ, with du/dk_i = −K⁻¹(b b')u
    for w in walls_s
        b = collect(_wall_geometry_vector(w))
        du = -(Kfac \ (b * (b' * u)))
        sens[w.id] = (u[1]*du[1] + u[2]*du[2]) / (δ * h)
    end
    return sens
end
