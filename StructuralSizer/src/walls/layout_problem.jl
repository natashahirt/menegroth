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
    # P1 — candidate ids MUST be globally unique: the id-membership activity mask
    # (`_active_candidate_ids` / `_plate_encloses_walls`) and the `wall_forces[w.id]` /
    # `wall_shear_demand(res, c.id)` indexing both key on `c.id`, so a duplicate id would let
    # one candidate's density/force silently stand in for another's.
    length(unique(c.id for c in candidates)) == length(candidates) ||
        throw(ArgumentError("WallLayoutNLPProblem: candidate ids must be globally unique " *
                            "(duplicate `id` among candidates)."))
    # P0 — validate the SIMP void floor and penalization exponent. `ρ_min=1.0` is PERMITTED
    # (the absolute `ρ^penal` activity test in `_active_candidate_ids` handles it correctly —
    # every wall reads active); only a nonsensical floor (≤ 0 or > 1) or a non-penalizing
    # exponent (< 1, which would make intermediate densities stiffness-EFFICIENT and defeat the
    # 0/1 drive) is rejected.
    0 < ρ_min <= 1 ||
        throw(ArgumentError("WallLayoutNLPProblem: ρ_min must satisfy 0 < ρ_min ≤ 1 " *
                            "(got ρ_min=$(ρ_min))."))
    penal >= 1 ||
        throw(ArgumentError("WallLayoutNLPProblem: penal must satisfy penal ≥ 1 " *
                            "(got penal=$(penal))."))
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

# ENGINEERING JUDGMENT (activity stiffness floor, not a code clause): a candidate is "removed/
# negligible" when its PENALIZED stiffness fraction `ρ^penal` — the fraction of `k_max` actually
# assembled into the story stiffness `K` (see `_walls_from_density`, `k = ρ^penal·k_max`) — drops
# to or below this small ABSOLUTE constant. `ρ^penal` (NOT the linear density `ρ` relative to
# `ρ_min`) is what K sees, so removal MUST be judged on `ρ^penal`. This is a PER-WALL ABSOLUTE
# test (a wall's own `ρ^penal` vs a fixed constant): it NEVER compares to other walls' stiffness
# (so it is not the relative-stiffness trap) and it does NOT depend on the magnitude of `ρ_min`.
# At `ρ_min=1.0` every `ρ^penal = 1 > 1e-6`, so ALL walls read ACTIVE (the enclosure guard stays
# fully armed — it degrades to "all active", never "all removed", as `ρ_min` grows); at the
# default `ρ_min=1e-3, penal=3` a floored wall has `ρ^penal = 1e-9 ≤ 1e-6` and is correctly
# removed.
const ACTIVE_STIFFNESS_FRACTION_FLOOR = 1.0e-6   # ε_abs

"""
    _active_candidate_ids(p, x) -> Set{Int}

The Set of candidate ids the optimizer considers ACTIVE at densities `x` — those whose
PENALIZED STIFFNESS FRACTION `ρ^penal` (the fraction of `k_max` actually assembled into `K`;
see [`_walls_from_density`](@ref)) exceeds the small ABSOLUTE floor
[`ACTIVE_STIFFNESS_FRACTION_FLOOR`](@ref) (`ε_abs = 1e-6`). Passed to the reduced enclosure
proxy ([`_plate_encloses_walls`](@ref)) so a density-REMOVED candidate parked outside the plate
cannot fail-close the geometry gate (Guard F2). The optimizer is the ONLY party that holds `x`,
`ρ_min`, and `penal`, so it alone can decide activity — the evaluator never guesses, and removal
is NEVER inferred from RELATIVE stiffness (an unsafe comparison to other walls; see
[`_plate_encloses_walls`](@ref)).

ENGINEERING JUDGMENT (activity threshold, not a code clause): "active" ≡ `(clamp(x,ρ_min,1))^penal
> ε_abs`. The test is on the PENALIZED stiffness fraction because `k = ρ^penal·k_max` is exactly
what the story stiffness `K` assembles — judging removal on the linear density `ρ` relative to
`ρ_min` is UNSAFE (it FAILS OPEN at `ρ_min=1.0`/large `ρ_min`, where every density is pinned at
the floor yet still carries full `ρ^penal` stiffness). Because this is a PER-WALL ABSOLUTE test
against a fixed constant, the magnitude of `ρ_min` is IRRELEVANT to correctness: it degrades to
"all active" (guard fully armed) as `ρ_min → 1`, and only marks a wall removed when its own
`ρ^penal` is genuinely negligible.

SCOPE OF THE ACTIVITY TEST (k_max assumption, ENGINEERING JUDGMENT — not a code clause): activity
is judged purely on the DIMENSIONLESS penalized fraction `ρ^penal`, which ASSUMES the per-candidate
`k_max` is non-pathological (a physically reasonable fully-dense stiffness). The absolute-stiffness
and occupancy questions — "is this active wall's real stiffness large enough?" and "does the floor
plate actually enclose the occupants?" — are deliberately NOT answered here; they are delegated to
the Phase-10 unified-FEM survivor check (true geometry, real units), the final authority. We
DELIBERATELY do NOT gate on a per-story RELATIVE threshold such as `k_i < 1e-6·Σ_j k_j`: that is
the relative-stiffness trap — one very stiff INSIDE wall would inflate `Σ k` and push a genuinely
REAL OUTSIDE wall below the threshold, masking it out of the enclosure proxy and re-introducing a
FAIL-OPEN (the outside wall's over-hang would no longer be examined). Activity is therefore the
optimizer's PER-WALL ABSOLUTE `ρ^penal` density fact, never a comparison of `k` across walls.

An empty active set therefore occurs ONLY when every wall is floored (`ρ^penal ≤ ε_abs` everywhere);
for a LOADED such story the load-dependent eigenstructure TRANSLATIONAL floor `util_trans` is the
governing backstop (it blows up as `λmin(K_tt) → ~0`), so the resulting vacuously-enclosed gate is a
backstop, not a hole (see [`_plate_encloses_walls`](@ref)).
"""
function _active_candidate_ids(p::WallLayoutNLPProblem, x::Vector{Float64})
    return Set(c.id for (i, c) in enumerate(p.candidates)
               if (clamp(x[i], p.ρ_min, 1.0))^p.penal > ACTIVE_STIFFNESS_FRACTION_FLOOR)
end

"""
    _candidate_half_lengths(p) -> Dict{Int,Float64}

Per-candidate half-length map (candidate id → `lw/2` [m]) passed alongside the active set to the
enclosure proxy ([`_plate_encloses_walls`](@ref)) so it can run the ENDPOINT-AWARE body test (a
wall whose centroid is inside the plate but whose body over-hangs the edge fails closed). Candidate
geometry (`lw`) is DENSITY-INDEPENDENT, so this map is constant across the optimizer's iterates and
is rebuilt cheaply at each call site that already builds the active set. Keyed on `c.id` to match
the active-set membership mask (P1 guarantees `c.id` is globally unique).
"""
_candidate_half_lengths(p::WallLayoutNLPProblem) = Dict(c.id => c.lw / 2 for c in p.candidates)

# ------------------------------------------------------------------------------
# Optimizer-boundary fail-closed-to-penalty bridge
# ------------------------------------------------------------------------------
# The reduced evaluator FAILS CLOSED on a singular / under-braced story by raising
# `SingularStiffnessError` (lateral_evaluator.jl) — the correct default for the
# one-shot CHECK path and the FEM-validation tier, which must refuse an unstable
# layout outright. But the SIMP relaxation drives "removed" walls to a density
# floor (ρ_min), so on a common uni-directional lateral case the optimizer thins
# the unloaded direction's walls until the 3×3 story K is (near-)singular. If that
# throw propagated into the differentiable Ipopt loop (`objective_fn` /
# `constraint_fns`, including their finite-difference gradient probes), a single
# normal iterate would abort the ENTIRE solve.
#
# ENGINEERING JUDGMENT (optimizer numerical safeguard, NOT a code clause): at the
# optimizer boundary ONLY, we catch `SingularStiffnessError` and map it to a large
# FINITE objective penalty and a deeply INFEASIBLE constraint value, so Ipopt is
# steered AWAY from (never toward) a singular layout instead of crashing. These
# are sentinels, not physical quantities:
#   * objective penalty 1e12 ≫ any realistic carbon (~1e3–1e5 kgCO₂e), drift
#     (~1e-3–1e0), or weighted objective (~O(1)), so a singular iterate can never
#     look like a minimum;
#   * constraint value 1e6 ≫ the feasibility bound of 1.0 (utilization ≤ 1), so a
#     singular iterate is deeply infeasible and the line search / restoration
#     rejects it.
# The evaluator itself STILL THROWS by default — only these optimizer call sites
# swallow-and-penalize. The finally-selected layout is re-validated by a THROWING
# check (the FEM tier / one-shot checker call `evaluate_lateral` directly), so a
# singular layout can never be returned as a solution.
const OPTIMIZER_SINGULAR_OBJECTIVE_PENALTY = 1.0e12
const OPTIMIZER_INFEASIBLE_CONSTRAINT      = 1.0e6

# ENGINEERING JUDGMENT (survivor re-validation acceptance tolerance, not a code clause):
# `optimize_continuous` satisfies constraints only to its convergence tolerance (Ipopt
# `tol`, default 1e-6), so a legitimately-converged layout can sit a hair OVER a utilization
# of 1.0 (e.g. drift exactly at `drift_limit`). The survivor re-validation must not reject
# such a boundary-converged layout as "unstable" over pure numerical noise — yet it MUST
# still reject a genuine mechanism, which overshoots by orders of magnitude (the dead-
# direction drift is ~1e4–1e6× the limit). This relative slack cleanly separates the two.
const SURVIVOR_DRIFT_UTIL_TOL = 1.0e-6

"""
    _evaluate_lateral_or_singular(p, walls) -> Union{LateralResult,Nothing}

Run the reduced evaluator for the differentiable optimizer loop, catching the
fail-closed [`SingularStiffnessError`](@ref) and signaling it with `nothing` so
the caller can substitute a penalty / infeasible sentinel (see the constants
above). Non-`SingularStiffnessError` exceptions are re-thrown unchanged.
"""
function _evaluate_lateral_or_singular(p::WallLayoutNLPProblem, walls::Vector{WallLine};
                                       active_ids::Union{Nothing,AbstractSet}=nothing,
                                       wall_half_lengths::Union{Nothing,AbstractDict{Int,Float64}}=nothing)
    try
        # `active_ids === nothing` ⇒ positional call (byte-for-byte the FEM / one-shot CHECK
        # path, incl. the non-reduced `evaluate_lateral` that takes no `active_ids` keyword).
        # `wall_half_lengths` is threaded together with `active_ids` (both set only on the reduced
        # optimizer path), so it rides the keyword branch only.
        return active_ids === nothing ?
               evaluate_lateral(p.evaluator, walls, p.loads) :
               evaluate_lateral(p.evaluator, walls, p.loads; active_ids=active_ids,
                                wall_half_lengths=wall_half_lengths)
    catch e
        e isa SingularStiffnessError || rethrow()
        return nothing
    end
end

"""
    _eigenstructure_or_singular(p, walls) -> Union{NamedTuple,Nothing}

Run the reduced-tier [`eigenstructure_stability`](@ref) gate for the differentiable optimizer
loop, catching the fail-closed [`SingularStiffnessError`](@ref) (a load-independent
translational or torsional mechanism) and signaling it with `nothing` so the caller can
substitute an all-infeasible sentinel. Non-`SingularStiffnessError` exceptions are re-thrown.
"""
function _eigenstructure_or_singular(p::WallLayoutNLPProblem, walls::Vector{WallLine};
                                     active_ids::Union{Nothing,AbstractSet}=nothing,
                                     wall_half_lengths::Union{Nothing,AbstractDict{Int,Float64}}=nothing)
    try
        return active_ids === nothing ?
               eigenstructure_stability(p.evaluator, walls, p.loads, p.drift_limit) :
               eigenstructure_stability(p.evaluator, walls, p.loads, p.drift_limit;
                                        active_ids=active_ids, wall_half_lengths=wall_half_lengths)
    catch e
        e isa SingularStiffnessError || rethrow()
        return nothing
    end
end

"""
    _plate_center_missing(ev) -> Bool

`true` when the evaluator is the reduced tier AND its `plate_center` is absent, so the twist-
sensitive corner-drift / torsion metrics cannot locate the true plan corners and the layout
must FAIL CLOSED. In that case [`constraint_fns`](@ref) drives the per-story drift/torsion
slots infeasible (so the NLP still returns) and [`solve_wall_layout`](@ref) stamps
`status = :geometry_required`. Any other evaluator (e.g. the FEM tier, which carries true
geometry) returns `false`.
"""
_plate_center_missing(ev::ReducedDiaphragmEvaluator) = ev.plate_center === nothing
_plate_center_missing(::AbstractLateralEvaluator) = false

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
        # Mask density-removed candidates (Guard F2): a removed wall outside the plate must not
        # fail-close the enclosure proxy. The active set and half-length map (endpoint-aware body
        # test) are passed TOGETHER; both derived from the SAME `x` / candidate geometry.
        res = _evaluate_lateral_or_singular(p, _walls_from_density(p, x);
                                            active_ids=_active_candidate_ids(p, x),
                                            wall_half_lengths=_candidate_half_lengths(p))
        res === nothing && return OPTIMIZER_SINGULAR_OBJECTIVE_PENALTY  # singular ⇒ steer away
        return maximum(res.drift; init=0.0)
    elseif obj isa WeightedLayoutObjective
        carbon = sum(clamp(x[i], p.ρ_min, 1.0) * _candidate_carbon_full(c)
                     for (i, c) in enumerate(p.candidates))
        res = _evaluate_lateral_or_singular(p, _walls_from_density(p, x);
                                            active_ids=_active_candidate_ids(p, x),
                                            wall_half_lengths=_candidate_half_lengths(p))
        res === nothing && return OPTIMIZER_SINGULAR_OBJECTIVE_PENALTY  # singular ⇒ steer away
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

Utilization ratios (feasible when ≤ 1): per-story drift, per-story torsion, and per-wall
in-plane shear `Vu/ϕVn` (ACI 318-19 §11.5.4.3 proxy, corpus: sp-wall-shear-strength-flowchart;
VERIFY). All smooth in `x` via the reduced evaluator.

The DRIFT slot bounds the physical ASCE 7-22 §12.12.1 quantity — the EXACT max-corner
interstory drift (`direction_complete_interstory_drift`'s `corner_drift`, the max over the four
TRUE occupant corners `plate_center ± (hx, hy)` of `hypot(disp(corner))/h`, the design story
drift at the building edges including diaphragm rotation, §12.8.6.5), NOT the twist-blind CR
translation. Torsion enters drift feasibility DIRECTLY and UNCAPPED through the corner φ term.
When `plate_center` is absent the drift/torsion slots are driven INFEASIBLE (fail closed, see
[`_plate_center_missing`](@ref)).

STABILITY is defined by the reduced-tier EIGENSTRUCTURE gate (`eigenstructure_stability`):
the softest translational eigenvalue `λmin(K_tt)` and the condensed torsional stiffness about
the CR `K_theta_cr`, each held above a physical anti-mechanism floor derived from the drift
limit. To keep the constraint vector length unchanged (`2·nstory + nWalls`), those two
per-story floors are FOLDED into the existing per-story drift/torsion slots via `max`:

  * drift slot `s`  = max( EXACT max-corner drift util , translational floor `util_trans` ),
  * torsion slot `s` = max( `res.torsion/torsion_limit` , torsional floor `util_tors` ) — the
    amplification ratio folded with the eccentric-CR condensed-torsional anti-mechanism floor
    (load-independent, so it still catches an F_s≈0-story twist mechanism).

The translational floor is the direction-complete drift in EIGEN form (so it subsumes the
+X/+Y sweep and closes the √2 diagonal-weak-mode gap, giving Ipopt a clean monotone gradient
on `λmin(K_tt)`); the torsional floor adds the strong `1/K_theta_cr` gradient. The torsional-
amplification ratio `res.torsion/torsion_limit` — with `δ_max` now EXACT over the four TRUE
corners anchored at `plate_center` — is a feasibility GATE (crit5 showed it is the check that
catches an eccentric service core); it is folded into the torsion slot via `max`, alongside the
exact max-corner drift carrying torsion in the drift slot. `hypot`/`abs`/`max` are
subdifferentiable, so the folded slots keep the same smoothness class.
"""
function constraint_fns(p::WallLayoutNLPProblem, x::Vector{Float64})
    ns = _nstory(p)
    walls = _walls_from_density(p, x)
    # ACTIVE-ID MASK (Guard F2): the SIMP optimizer keeps removed candidates in `walls` at the
    # ρ_min stiffness floor; a removed wall parked OUTSIDE the plate would otherwise fail-close
    # the enclosure proxy and over-reject a sound layout as :geometry_inconsistent. Compute the
    # active set ONCE from `x` and reuse it for the geometry gate AND every reduced-evaluator
    # call below, so the gate and the metrics can never disagree within this iterate.
    active = _active_candidate_ids(p, x)
    # Per-candidate half-length map (density-independent) threaded TOGETHER with `active` so the
    # enclosure proxy runs the endpoint-aware body test consistently with the mask at every site.
    half_lengths = _candidate_half_lengths(p)
    res = _evaluate_lateral_or_singular(p, walls; active_ids=active, wall_half_lengths=half_lengths)
    # Singular / under-braced iterate: return an all-INFEASIBLE constraint vector
    # so Ipopt treats this layout as badly infeasible (steer away) instead of the
    # evaluator's fail-closed throw aborting the whole solve. A direct check on a
    # singular layout (via `evaluate_lateral`) STILL throws — only this optimizer
    # call site penalizes.
    res === nothing && return fill(OPTIMIZER_INFEASIBLE_CONSTRAINT, n_constraints(p))

    # GEOMETRY-REQUIRED / -INCONSISTENT fail-closed (reduced tier, option (b)): the corner-
    # drift / torsion certification cannot be trusted when (a) the true plate center is absent
    # (cannot locate the plan corners) OR (b) the plate UNDER-COVERS the walls (the exact
    # four-corner metric is exact only over a plate that encloses the drift-relevant points —
    # crit7). In either case drive EVERY per-story drift and torsion slot INFEASIBLE (large
    # positive). The NLP still returns a finite vector (no throw — good Ipopt behavior), the
    # per-wall shear slots stay real, and `solve_wall_layout` stamps `status = :geometry_required`
    # (missing) or `:geometry_inconsistent` (under-covering) on the selected layout. Never a
    # silent wall-centroid / origin / plate-span proxy (crit5/rev6/crit6/crit7). FEM tier is
    # unaffected: both predicates return the FEM-safe default for a non-reduced evaluator.
    geom_missing = _plate_center_missing(p.evaluator) ||
                   !_plate_encloses_walls(p.evaluator, walls, active, half_lengths)

    # Eigenstructure stability floors + direction-complete drift are only computed when the
    # geometry is present. Wrapped in the same singular-catch: a load-independent mechanism
    # (that `evaluate_lateral` did not already trip) maps to the all-INFEASIBLE sentinel.
    local eig, dc
    if !geom_missing
        eig = _eigenstructure_or_singular(p, walls; active_ids=active, wall_half_lengths=half_lengths)
        eig === nothing && return fill(OPTIMIZER_INFEASIBLE_CONSTRAINT, n_constraints(p))
        # Direction-complete drift (origin-invariant, both principal directions). Safe to
        # call without a singular-catch: `res` above is non-`nothing`, so every story's K
        # passed the `_solve_spd` conditioning backstop — the same K and L_ref are reused
        # here, so none of its canonical solves can throw.
        dc = direction_complete_interstory_drift(p.evaluator, walls, p.loads;
                                                 active_ids=active, wall_half_lengths=half_lengths)
    end

    g = Float64[]
    # Per-story drift slot: the EXACT MAX-CORNER interstory drift over the four TRUE occupant
    # corners (ASCE 7-22 §12.12.1, edges incl. diaphragm rotation per §12.8.6.5) AND the
    # translational eigenstructure floor (the softest-mode drift), whichever governs. Torsional
    # amplification is captured DIRECTLY and UNCAPPED by the corner drift (the hypot over the
    # four true corners). INFEASIBLE sentinel when plate_center is absent (fail closed).
    for s in 1:ns
        if geom_missing
            push!(g, OPTIMIZER_INFEASIBLE_CONSTRAINT)
        else
            drift_u = maximum(@view dc.corner_drift[s, :]) / p.drift_limit
            push!(g, max(drift_u, eig.util_trans[s]))
        end
    end
    # Per-story torsion slot: the torsional-amplification ratio `res.torsion/torsion_limit`
    # (δ_max/δ_avg ≤ torsion_limit) FOLDED with the condensed-torsional eigenstructure floor
    # `util_tors` (the load-independent twist anti-mechanism backstop), whichever governs.
    # `res.torsion`'s δ_max is now EXACT over the four TRUE corners anchored at `plate_center`
    # (`_torsion_amplification` 4-arg). crit5 showed this ratio is the check that catches an
    # eccentric service core (ratio ≫ torsion_limit); it is a feasibility GATE. INFEASIBLE
    # sentinel when plate_center is absent (fail closed).
    for s in 1:ns
        if geom_missing
            push!(g, OPTIMIZER_INFEASIBLE_CONSTRAINT)
        else
            push!(g, max(res.torsion[s] / p.torsion_limit, eig.util_tors[s]))
        end
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
        # Explicit withheld handling: `wall_shear_demand` returns `nothing` for a
        # withheld / unvalidated id (FEM upper-story shear). The reduced inner-loop
        # evaluator withholds nothing, so this only guards a (non-default) FEM-tier
        # evaluator — a withheld demand is treated as INFEASIBLE, never a passing
        # zero.
        demand = wall_shear_demand(res, c.id)
        if demand === nothing
            push!(g, OPTIMIZER_INFEASIBLE_CONSTRAINT)
        else
            push!(g, abs(demand) / max(cap.ϕVn, 1e-6))
        end
    end
    return g
end

# ------------------------------------------------------------------------------
# Solve wrapper
# ------------------------------------------------------------------------------

"""
    solve_wall_layout(p; solver=:ipopt, kwargs...) -> NamedTuple

Solve the layout problem via the existing continuous optimizer, then RE-VALIDATE the
selected layout before returning it. The optimizer result (see `optimize_continuous`)
is augmented with a `feasible::Bool`, a `revalidation` record, and — when it fails —
`status = :infeasible`; densities near `ρ_min` indicate walls the optimizer removed.

SURVIVOR RE-VALIDATION (safety cross-check): `optimize_continuous` returns its best iterate,
but an optimizer can hand back a layout that is only marginally feasible, laterally dead in a
principal direction, or torsionally soft. We re-check the SELECTED layout against the FULL
constraint set:

  * a GEOMETRY gate: if the reduced evaluator has no `plate_center`, the twist certification
    is unavailable and the layout is REFUSED with `status = :geometry_required` BEFORE any
    other check (fail closed; see [`_plate_center_missing`](@ref));
  * the throwing direct path (`evaluate_lateral`, fail-closed on a singular K);
  * the EXACT max-corner interstory drift (`direction_complete_interstory_drift`'s
    `corner_drift`, the max over the four TRUE occupant corners `plate_center ± (hx, hy)` of
    `hypot(disp(corner))/h`): the ASCE 7-22 §12.12.1 design story drift at the building edges
    including diaphragm rotation (§12.8.6.5), swept +X/+Y. Exact (no slack) and correct even
    when the CR lies outside the plate (crit5/rev6);
  * the EIGENSTRUCTURE stability gate (`eigenstructure_stability`): translational floor
    `util_trans` and the condensed-torsional floor `util_tors` (exact CR-to-corner lever);
  * the torsional-amplification ratio `res.torsion/torsion_limit` (δ_max/δ_avg, with δ_max
    EXACT over the four TRUE corners anchored at `plate_center`) — crit5 showed this ratio
    independently rejects an eccentric service core (ratio ≫ torsion_limit), so it GATES
    feasibility;
  * per-wall in-plane shear `Vu/ϕVn`.

If ANY of these exceeds its limit (beyond `SURVIVOR_DRIFT_UTIL_TOL`), or the direct check
throws, the result is REFUSED as a success (`feasible = false`, `status = :infeasible`) with
the failing story / mode / direction recorded. `worst_util` is the worst utilization across
ALL modes; `failing` is resolved in PRIORITY ORDER (drift → eigen floors → torsion → shear) so
a genuine drift-direction mechanism still reports its direction. The full-fidelity unified-FEM
survivor cross-check (Phase 10) is the FINAL stability authority (true geometry).
"""
function solve_wall_layout(p::WallLayoutNLPProblem; solver::Symbol=:ipopt, kwargs...)
    result = optimize_continuous(p; objective=p.objective, solver=solver, kwargs...)

    # GEOMETRY-REQUIRED fail-closed: the reduced tier CANNOT certify corner drift / torsion
    # without the true plate center (the four occupant corners `plate_center ± (hx, hy)` cannot
    # be located). A feasible verdict is NOT permitted on the frame-independent checks alone —
    # refuse with `status = :geometry_required` (never a silent pass, never a wall-centroid /
    # origin / plate-span proxy; crit5/rev6/crit6). The Phase 10 unified-FEM survivor check
    # (true geometry) is the accuracy authority.
    if _plate_center_missing(p.evaluator)
        reval = (ok = false, worst_util = Inf,
                 failing = (story = 0, direction = :none, mode = :geometry_required,
                            drift = Inf, util = Inf))
        return merge(result, (status = :geometry_required, feasible = false,
                              revalidation = reval))
    end

    walls_opt = _walls_from_density(p, result.minimizer)
    # ACTIVE-ID MASK (Guard F2): the selected layout still carries the optimizer's density-
    # removed candidates (floored to ρ_min). Derive the active set from the SAME minimizer that
    # produced `walls_opt`, and reuse it for BOTH the enclosure gate below and the survivor re-
    # validation, so a removed wall parked outside the plate cannot spuriously flip the layout
    # to :geometry_inconsistent / :infeasible.
    active_opt = _active_candidate_ids(p, result.minimizer)
    # Per-candidate half-length map (density-independent) threaded TOGETHER with `active_opt` so the
    # enclosure gate and the survivor re-validation both run the endpoint-aware body test.
    half_lengths_opt = _candidate_half_lengths(p)

    # ENCLOSURE GATE (crit7, fail-closed): plate_center is present (handled above), but the
    # exact four-corner drift / torsion metrics are exact ONLY if the plate encloses the drift-
    # relevant points. The two FREE caller fields `plate_center`/`plan_halfwidth` are not
    # otherwise cross-checked against the wall positions, so an UNDER-COVERING plate would flip
    # the verdict to feasible=true for an over-limit building (the plate-anchored gates under-
    # state the twist; the plate-independent `util_trans` is twist-blind). Enforce the checkable
    # proxy WALLS ⊆ plate (see `_plate_encloses_walls`) and REFUSE with a DISTINCT, more-
    # debuggable `status = :geometry_inconsistent` (vs `:geometry_required` for a missing plate).
    # Wall positions are density-independent, so `walls_opt` carries the true geometry here.
    # FEM tier returns `true` (unaffected); the Phase 10 unified-FEM survivor check (true
    # geometry) remains the final authority, incl. the residual walls ⊆ plate ⊂ occupants.
    if !_plate_encloses_walls(p.evaluator, walls_opt, active_opt, half_lengths_opt)
        reval = (ok = false, worst_util = Inf,
                 failing = (story = 0, direction = :none, mode = :geometry_inconsistent,
                            drift = Inf, util = Inf))
        return merge(result, (status = :geometry_inconsistent, feasible = false,
                              revalidation = reval))
    end
    tol = 1.0 + SURVIVOR_DRIFT_UTIL_TOL
    revalidation = try
        # Throwing direct path on the actual design load: a genuinely singular selected
        # layout fails closed here (not just via the sweeps below).
        # Same active-ID mask as the enclosure gate above (Guard F2): the survivor re-validation
        # runs on the optimizer's selected layout (density-removed candidates included), so it
        # must skip the SAME removed walls — otherwise a removed outside wall would re-introduce
        # the spurious enclosure fail here.
        res = evaluate_lateral(p.evaluator, walls_opt, p.loads;
                               active_ids=active_opt, wall_half_lengths=half_lengths_opt)
        dc  = direction_complete_interstory_drift(p.evaluator, walls_opt, p.loads;
                                                  active_ids=active_opt, wall_half_lengths=half_lengths_opt)
        eig = eigenstructure_stability(p.evaluator, walls_opt, p.loads, p.drift_limit;
                                       active_ids=active_opt, wall_half_lengths=half_lengths_opt)

        # (1) EXACT MAX-CORNER interstory drift over the four TRUE occupant corners (ASCE
        # 7-22 §12.12.1, edges incl. diaphragm rotation per §12.8.6.5): the physical drift
        # bound, carrying the failing principal DIRECTION. Torsion enters directly and uncapped.
        drift_worst = 0.0
        drift_rec = (story = 0, direction = :none, mode = :drift, drift = 0.0, util = 0.0)
        for s in axes(dc.corner_drift, 1), d in axes(dc.corner_drift, 2)
            u = dc.corner_drift[s, d] / p.drift_limit
            if u > drift_worst
                drift_worst = u
                drift_rec = (story = s, direction = dc.directions[d], mode = :drift,
                             drift = dc.corner_drift[s, d], util = u)
            end
        end
        # (2) Eigenstructure stability floors (translational + condensed torsional).
        eig_worst = 0.0
        eig_rec = (story = 0, direction = :none, mode = :eigen, drift = 0.0, util = 0.0)
        for s in eachindex(eig.util_trans)
            if eig.util_trans[s] > eig_worst
                eig_worst = eig.util_trans[s]
                eig_rec = (story = s, direction = :none, mode = :eig_translational,
                           drift = 0.0, util = eig.util_trans[s])
            end
            if eig.util_tors[s] > eig_worst
                eig_worst = eig.util_tors[s]
                eig_rec = (story = s, direction = :none, mode = :eig_torsional,
                           drift = 0.0, util = eig.util_tors[s])
            end
        end
        # (3) Torsional-amplification ratio gate: δ_max/δ_avg ≤ torsion_limit, with δ_max now
        # EXACT over the four TRUE corners anchored at `plate_center` (`_torsion_amplification`
        # 4-arg). crit5 showed this ratio is the check that independently rejects an eccentric
        # service core (ratio ≫ torsion_limit).
        tors_worst = 0.0
        tors_rec = (story = 0, direction = :none, mode = :torsion, drift = 0.0, util = 0.0)
        for s in eachindex(res.torsion)
            u = res.torsion[s] / p.torsion_limit
            if u > tors_worst
                tors_worst = u
                tors_rec = (story = s, direction = :none, mode = :torsion,
                            drift = res.torsion[s], util = u)
            end
        end
        # (4) Per-wall in-plane shear (demand from the evaluator, capacity from the ACI proxy).
        shear_worst = 0.0
        shear_rec = (story = 0, direction = :none, mode = :shear, drift = 0.0, util = 0.0)
        for (i, c) in enumerate(p.candidates)
            ρ = clamp(result.minimizer[i], p.ρ_min, 1.0)
            t = ρ * c.t_max
            cap = wall_shear_capacity_si(c.fc, c.fy, c.lw, t, c.ρt, c.height)
            demand = wall_shear_demand(res, c.id)   # `nothing` ⇒ withheld / unvalidated
            u = demand === nothing ? Inf : abs(demand) / max(cap.ϕVn, 1e-6)
            if u > shear_worst
                shear_worst = u
                shear_rec = (story = c.story, direction = :none,
                             mode = (demand === nothing ? :shear_withheld : :shear),
                             drift = 0.0, util = u)
            end
        end

        worst_util = max(drift_worst, eig_worst, tors_worst, shear_worst)
        # Priority-ordered failing record (only consulted when !ok): drift first so a
        # drift-direction mechanism reports its DIRECTION (preserving the near-dead-Y
        # contract where the translational floor and the +Y corner drift tie exactly), then
        # the eigen floors, then the restored torsion ratio, then shear.
        failing = drift_worst > tol ? drift_rec :
                  eig_worst   > tol ? eig_rec   :
                  tors_worst  > tol ? tors_rec  :
                  shear_worst > tol ? shear_rec :
                  drift_rec
        (ok = worst_util <= tol, worst_util = worst_util, failing = failing)
    catch e
        e isa SingularStiffnessError || rethrow()
        (ok = false, worst_util = Inf,
         failing = (story = 0, direction = :singular, mode = :singular, drift = Inf, util = Inf))
    end

    revalidation.ok || return merge(result,
        (status = :infeasible, feasible = false, revalidation = revalidation))
    return merge(result, (feasible = true, revalidation = revalidation))
end
