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
"""
struct LateralResult
    story_disp::Matrix{Float64}
    drift::Vector{Float64}
    wall_forces::Dict{Int,Float64}
    torsion::Vector{Float64}
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

        u = _solve_spd(K, f)
        story_disp[s, :] .= u

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

"""Solve `K u = f` robustly; falls back to a pseudo-inverse if `K` is singular
(e.g. a story with insufficient walls to be stable)."""
function _solve_spd(K::Matrix{Float64}, f::Vector{Float64})
    try
        return cholesky(Symmetric(K + 1e-9 * I)) \ f
    catch
        return pinv(K) * f
    end
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
    Fx = 0.0; Fy = 0.0; Mz = 0.0
    for ld in loads
        ld.story < story && continue
        Fx += ld.Fx; Fy += ld.Fy
        Mz += ld.Fy * ld.ex - ld.Fx * ld.ey
    end
    f = [Fx, Fy, Mz]
    Kfac = cholesky(Symmetric(K + 1e-9 * I))
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
