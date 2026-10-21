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

# ENGINEERING JUDGMENT (numerical safety, not a code clause): a story stiffness is
# treated as singular / near-singular when the reciprocal condition number of its
# SCALE-NORMALIZED stiffness (λ_min/λ_max after non-dimensionalizing the rotational
# DOF — see `_assert_nonsingular_K`) falls to or below this tolerance. The raw 3×3
# story K mixes units — translational DOFs carry N/m, the rotational DOF N·m, the
# coupling terms N — so λ_min/λ_max of the UNSCALED matrix is NOT dimensionless and
# scales like L_ref² with plan size/origin; the normalization below makes this a
# genuine, scale-invariant conditioning metric. A well-braced story then has all
# three modes (two translational + torsional) of comparable (normalized) stiffness,
# so rcond ≫ 1e-8; a value this small means at least one lateral or torsional mode
# is effectively unrestrained. Chosen well above assembly round-off so a genuinely
# stable layout — of ANY footprint — is never rejected, yet far above the point
# where a Float64 solve loses all significance.
const SINGULAR_STIFFNESS_RCOND = 1e-8

"""
    _assert_nonsingular_K(Ksym, L_ref)

Fail-closed guard for a 3×3 story stiffness: throws [`SingularStiffnessError`](@ref)
if `Ksym` is not positive-definite or is near-singular (reciprocal condition number
at or below [`SINGULAR_STIFFNESS_RCOND`](@ref)).

The raw story `K` is mixed-unit (translational N/m, rotational N·m, coupling N), so
its spectrum is scale/origin-dependent and a bare λ_min/λ_max is NOT a condition
number. We first non-dimensionalize the rotational DOF by the plan reference length
`L_ref` via `S = diag(1, 1, 1/L_ref)`, forming `K_scaled = S·K·S` whose three
entries are all ~N/m, then test the reciprocal condition number of `K_scaled`. This
makes the test scale-invariant: a well-braced large-footprint layout is no longer
falsely rejected, and a genuine singularity (an unrestrained translational or
torsional mode) is still caught. The SOLVE itself (`_solve_spd`) uses the UNSCALED
`K`; the scaling only informs the singular/non-singular decision. Uses the exact
3×3 symmetric spectrum (cheap) rather than a perturbed factorization.
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

# Fields
- `story_heights::Vector{Float64}`: story heights [m], index = story
- `plan_halfwidth::NTuple{2,Float64}`: half plan extent `(Lx/2, Ly/2)` [m] used
  to evaluate corner drift for the torsional amplification metric
- `accidental_ecc::Float64`: ASCE 7 accidental eccentricity fraction (default 0.05)
- `boundary::Symbol`: shear-building idealization; stories treated as independent
  (interstory) springs. Cantilever flexural coupling across stories is the FEM
  tier's job.
"""
Base.@kwdef struct ReducedDiaphragmEvaluator <: AbstractLateralEvaluator
    story_heights::Vector{Float64}
    plan_halfwidth::NTuple{2,Float64} = (0.0, 0.0)
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

function evaluate_lateral(ev::ReducedDiaphragmEvaluator,
                          walls::Vector{WallLine},
                          loads::Vector{StoryLoad})
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
        h = ev.story_heights[s]
        drift[s] = h > 0 ? sqrt(u[1]^2 + u[2]^2) / h : 0.0

        # Torsional amplification δ_max/δ_avg at plan corners (ASCE 7 §12.8.4.3
        # torsional-irregularity metric; VERIFY).
        torsion[s] = _torsion_amplification(u, ev.plan_halfwidth)

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

"""Corner drift amplification `δ_max/δ_avg` from rigid-body displacement `u`."""
function _torsion_amplification(u::Vector{Float64}, halfwidth::NTuple{2,Float64})
    δavg = sqrt(u[1]^2 + u[2]^2)
    δavg < 1e-12 && return 1.0
    hx, hy = halfwidth
    δmax = δavg
    for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
        dx = u[1] - u[3] * (sy * hy)
        dy = u[2] + u[3] * (sx * hx)
        δmax = max(δmax, sqrt(dx^2 + dy^2))
    end
    return δmax / δavg
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

    # d(drift)/dk_i = (1/h) * (u_xy · du_xy/dk_i)/δ, with du/dk_i = −K⁻¹(b b')u
    for w in walls_s
        b = collect(_wall_geometry_vector(w))
        du = -(Kfac \ (b * (b' * u)))
        sens[w.id] = (u[1]*du[1] + u[2]*du[2]) / (δ * h)
    end
    return sens
end
