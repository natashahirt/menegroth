# ==============================================================================
# Shear-Wall Layout Optimization — NLP Problem (plan S4)
# ==============================================================================
# A `WallLayoutNLPProblem <: AbstractNLPProblem` that plugs into the EXISTING
# continuous optimizer (`optimize_continuous`, `:ipopt` backend). Gradient-based
# continuous topology optimization over a ground structure of candidate wall
# lines (chosen paradigm). Carbon-first objective, extensible to drift and
# multi-objective by swapping the `AbstractObjective` — never the solver.
#
# Design variables: per-candidate density ρ_i ∈ [ρ_min, 1] (SIMP relaxation of
# present/absent). Wall thickness t_i = ρ_i · t_max_i; stiffness is penalized
# k_i = ρ_i^p · k_max_i (p > 1) so intermediate densities are stiffness-
# inefficient and the optimum drives toward 0/1 (present/absent). Embodied carbon
# is linear in ρ_i (mass ∝ thickness), so low-benefit walls are removed.
#
# The inner loop uses ONLY the cheap differentiable `ReducedDiaphragmEvaluator`
# and a closed-form ACI shear proxy — full ACI code checks (`checker.jl`) and the
# Asap FEM tier run only on survivors (plan decoupling principle).
#
# Layout-optimization reference: Zhang & Mueller (2017)
# (corpus: zhang-mueller-2017-shear-wall-layout-opt). Drift limits per
# ASCE 7-22 Table 12.12-1 (VERIFY).

using Unitful

# ------------------------------------------------------------------------------
# Extensibility objectives (satisfy "new AbstractObjective, not new solver")
# ------------------------------------------------------------------------------

"""Minimize peak interstory drift ratio (layout objective B)."""
struct MinDrift <: AbstractObjective end

"""
    WeightedLayoutObjective <: AbstractObjective

Scalarized multi-objective (layout objective C): `w_carbon·(carbon/carbon_ref) +
w_drift·(drift/drift_ref)`. Reference values normalize the two scales; sweep the
weights (or use ε-constraints) to trace a Pareto front.
"""
struct WeightedLayoutObjective <: AbstractObjective
    w_carbon::Float64
    w_drift::Float64
    carbon_ref::Float64
    drift_ref::Float64
end

# ------------------------------------------------------------------------------
# Candidate wall + problem
# ------------------------------------------------------------------------------

"""
    WallCandidate

One admissible wall line in the ground structure (bare SI). The optimizer
decides its density (→ thickness/presence); position/orientation/length are
fixed inputs.

# Fields
- `id::Int`: stable id (keys into evaluator wall forces)
- `x`,`y`::Float64: plan centroid [m]
- `θ::Float64`: in-plane axis orientation [rad]
- `lw::Float64`: wall length [m]
- `height::Float64`: story height [m]
- `story::Int`: 1-based story
- `E`,`ν`,`fc`,`fy`::Float64: concrete/steel elastic + strength props [Pa]
- `ρc`,`ecc`::Float64: concrete density [kg/m³], embodied carbon [kgCO₂e/kg]
- `t_max::Float64`: maximum (fully-dense) thickness [m]
- `ρt::Float64`: transverse reinforcement ratio (for shear proxy)
"""
struct WallCandidate
    id::Int
    x::Float64; y::Float64; θ::Float64
    lw::Float64; height::Float64; story::Int
    E::Float64; ν::Float64; fc::Float64; fy::Float64
    ρc::Float64; ecc::Float64
    t_max::Float64
    ρt::Float64
end

"""
    WallLayoutNLPProblem <: AbstractNLPProblem

Continuous topology-optimization problem for shear-wall layout (plan S4).

# Fields
- `candidates::Vector{WallCandidate}`: the ground structure
- `evaluator::AbstractLateralEvaluator`: cheap tier (ReducedDiaphragmEvaluator)
- `loads::Vector{StoryLoad}`: lateral demand per story
- `objective::AbstractObjective`: `MinCarbon()` (default), `MinDrift()`, or `WeightedLayoutObjective`
- `drift_limit::Float64`: allowable interstory drift ratio (ASCE 7-22 Tbl 12.12-1; VERIFY)
- `torsion_limit::Float64`: allowable δ_max/δ_avg (ASCE 7-22 §12.8.4.3; VERIFY)
- `ρ_min::Float64`: lower density bound (SIMP void floor)
- `penal::Float64`: SIMP penalization exponent (p > 1)
"""
struct WallLayoutNLPProblem <: AbstractNLPProblem
    candidates::Vector{WallCandidate}
    evaluator::AbstractLateralEvaluator
    loads::Vector{StoryLoad}
    objective::AbstractObjective
    drift_limit::Float64
    torsion_limit::Float64
    ρ_min::Float64
    penal::Float64
end

"""
    WallLayoutNLPProblem(candidates, evaluator, loads; objective=MinCarbon(),
                         drift_limit=0.02, torsion_limit=1.5, ρ_min=1e-3, penal=3.0)

Construct a layout problem. `drift_limit` default 0.02 (2%) per ASCE 7-22
Table 12.12-1 typical (VERIFY); `torsion_limit` 1.5 (extreme torsional
irregularity threshold; VERIFY).
"""
function WallLayoutNLPProblem(candidates::Vector{WallCandidate},
                              evaluator::AbstractLateralEvaluator,
                              loads::Vector{StoryLoad};
                              objective::AbstractObjective=MinCarbon(),
                              drift_limit::Real=0.02,
                              torsion_limit::Real=1.5,
                              ρ_min::Real=1e-3,
                              penal::Real=3.0)
    WallLayoutNLPProblem(candidates, evaluator, loads, objective,
                         Float64(drift_limit), Float64(torsion_limit),
                         Float64(ρ_min), Float64(penal))
end

# ------------------------------------------------------------------------------
# AbstractNLPProblem interface: core
# ------------------------------------------------------------------------------

n_variables(p::WallLayoutNLPProblem) = length(p.candidates)

function variable_bounds(p::WallLayoutNLPProblem)
    n = length(p.candidates)
    return (fill(p.ρ_min, n), fill(1.0, n))
end

"""Start from a lightly-populated layout (all candidates half-dense)."""
initial_guess(p::WallLayoutNLPProblem) = fill(0.5, length(p.candidates))

variable_names(p::WallLayoutNLPProblem) = ["ρ[$(c.id)]" for c in p.candidates]

# ------------------------------------------------------------------------------
# Map densities → WallLine springs (SIMP-penalized stiffness)
# ------------------------------------------------------------------------------

"""Full (ρ=1) in-plane stiffness [N/m] of a candidate at `t_max`."""
function _candidate_kmax(c::WallCandidate)
    return wall_stiffness_from_thickness_si(c.t_max, c.lw, c.E, c.ν, c.height;
                                            cracked=true, boundary=:cantilever)
end

"""Build `WallLine`s from densities `x` with SIMP-penalized stiffness `k = ρ^p·k_max`."""
function _walls_from_density(p::WallLayoutNLPProblem, x::Vector{Float64})
    walls = Vector{WallLine}(undef, length(p.candidates))
    @inbounds for (i, c) in enumerate(p.candidates)
        ρ = clamp(x[i], p.ρ_min, 1.0)
        k = (ρ^p.penal) * _candidate_kmax(c)
        walls[i] = WallLine(c.id, c.x, c.y, c.θ, k, c.story)
    end
    return walls
end

# ------------------------------------------------------------------------------
# Objective
# ------------------------------------------------------------------------------

"""Embodied carbon of a fully-dense candidate [kgCO₂e]: volume·density·ecc."""
_candidate_carbon_full(c::WallCandidate) = (c.lw * c.t_max * c.height) * c.ρc * c.ecc
"""Concrete volume of a fully-dense candidate [m³]."""
_candidate_volume_full(c::WallCandidate) = c.lw * c.t_max * c.height

function objective_fn(p::WallLayoutNLPProblem, x::Vector{Float64})
    obj = p.objective
    if obj isa MinCarbon
        return sum(clamp(x[i], p.ρ_min, 1.0) * _candidate_carbon_full(c)
                   for (i, c) in enumerate(p.candidates))
    elseif obj isa MinVolume
        return sum(clamp(x[i], p.ρ_min, 1.0) * _candidate_volume_full(c)
                   for (i, c) in enumerate(p.candidates))
    elseif obj isa MinDrift
        res = evaluate_lateral(p.evaluator, _walls_from_density(p, x), p.loads)
        return maximum(res.drift; init=0.0)
    elseif obj isa WeightedLayoutObjective
        carbon = sum(clamp(x[i], p.ρ_min, 1.0) * _candidate_carbon_full(c)
                     for (i, c) in enumerate(p.candidates))
        res = evaluate_lateral(p.evaluator, _walls_from_density(p, x), p.loads)
        drift = maximum(res.drift; init=0.0)
        return obj.w_carbon * (carbon / obj.carbon_ref) + obj.w_drift * (drift / obj.drift_ref)
    else
        # Fallback: treat as carbon.
        return sum(clamp(x[i], p.ρ_min, 1.0) * _candidate_carbon_full(c)
                   for (i, c) in enumerate(p.candidates))
    end
end

# ------------------------------------------------------------------------------
# Constraints: per-story drift, per-story torsion, per-wall shear strength proxy
# ------------------------------------------------------------------------------

_nstory(p::WallLayoutNLPProblem) = maximum(c.story for c in p.candidates; init=0)

function n_constraints(p::WallLayoutNLPProblem)
    return 2 * _nstory(p) + length(p.candidates)
end

function constraint_names(p::WallLayoutNLPProblem)
    ns = _nstory(p)
    names = String[]
    for s in 1:ns; push!(names, "drift utilization story $s"); end
    for s in 1:ns; push!(names, "torsion utilization story $s"); end
    for c in p.candidates; push!(names, "in-plane shear util wall $(c.id)"); end
    return names
end

"""All constraints are utilization ratios ≤ 1.0."""
function constraint_bounds(p::WallLayoutNLPProblem)
    nc = n_constraints(p)
    return (fill(-Inf, nc), fill(1.0, nc))
end

"""
    constraint_fns(p, x) -> Vector{Float64}

Utilization ratios (feasible when ≤ 1): per-story drift/`drift_limit`, per-story
torsion/`torsion_limit`, and per-wall in-plane shear `Vu/ϕVn` (ACI 318-19
§11.5.4.3 proxy, corpus: sp-wall-shear-strength-flowchart; VERIFY). All smooth
in `x` via the reduced evaluator.
"""
function constraint_fns(p::WallLayoutNLPProblem, x::Vector{Float64})
    ns = _nstory(p)
    walls = _walls_from_density(p, x)
    res = evaluate_lateral(p.evaluator, walls, p.loads)

    g = Float64[]
    for s in 1:ns
        push!(g, res.drift[s] / p.drift_limit)
    end
    for s in 1:ns
        push!(g, res.torsion[s] / p.torsion_limit)
    end
    # Per-wall shear strength proxy: demand from the evaluator, capacity from the
    # ACI in-plane shear formula at the current (density-scaled) thickness.
    # Candidates are iterated in vector order (== variable order), so `x[i]` is
    # this candidate's density.
    for (i, c) in enumerate(p.candidates)
        ρ = clamp(x[i], p.ρ_min, 1.0)
        t = ρ * c.t_max
        hw = c.height  # single-story pier height; multi-story hw handled upstream
        cap = wall_shear_capacity_si(c.fc, c.fy, c.lw, t, c.ρt, hw)
        Vu = abs(get(res.wall_forces, c.id, 0.0))
        push!(g, Vu / max(cap.ϕVn, 1e-6))
    end
    return g
end

# ------------------------------------------------------------------------------
# Solve wrapper
# ------------------------------------------------------------------------------

"""
    solve_wall_layout(p; solver=:ipopt, kwargs...) -> NamedTuple

Solve the layout problem via the existing continuous optimizer. Returns the
optimizer result (see `optimize_continuous`); densities near `ρ_min` indicate
walls the optimizer removed. Cross-check survivors with the FEM tier.
"""
function solve_wall_layout(p::WallLayoutNLPProblem; solver::Symbol=:ipopt, kwargs...)
    return optimize_continuous(p; objective=p.objective, solver=solver, kwargs...)
end
