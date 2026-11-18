# Fail before solver construction when a continuous problem does not implement
# the requested public objective. Equivalent optima are not enough: accepting
# an objective implies that the reported objective has that objective's scale.
function _require_nlp_objective(objective, supported::Tuple; problem::AbstractString)
    any(T -> objective isa T, supported) || throw(ArgumentError(
        "$problem does not support objective=$(nameof(typeof(objective))); " *
        "expected one of $(nameof.(supported))"))
    return objective
end

# ==============================================================================
# RC Column NLP Problem
# ==============================================================================
# Continuous optimization problem for RC column sizing.
# Interfaces with src/optimize/continuous_nlp.jl via AbstractNLPProblem.
#
# Design variables: [b, h, ρg] (width, depth in inches, reinforcement ratio)
# Objective: Minimize cross-sectional area (∝ volume)
# Constraints: ACI 318 P-M interaction, slenderness, reinforcement limits

using Unitful
using Asap: kip, ksi, to_kip, to_kipft, to_inches, to_sqinches

"""
Largest longitudinal bar count a rectangular NLP column may be built with.

Practical layout cap, not an ACI limit. Shared by the placeable-steel
constraint in [`constraint_fns`](@ref) and by
[`_build_nlp_trial_section`](@ref), so the solver cannot ask for more steel
than the built section can carry.
"""
const RC_COLUMN_NLP_MAX_BARS = 32

"""Tie bar number of NLP-built rectangular sections (the `RCColumnSection` default)."""
const RC_COLUMN_NLP_TIE_BAR = 4

"""
    _rc_nlp_delta_ns(Cm, stab) -> Float64

Nonsway moment magnifier for the column NLP.

ACI 318-11 §10.10.6 Eq. (10-12) (corpus: aci-318-11, p. 155):

    δns = Cm / (1 − Pu/(0.75 Pc)) ≥ 1

`stab` is Pu/(0.75 Pc). The equation is undefined at and beyond
`stab = 1`. Past a magnifier of 15 the hyperbola is replaced by its
tangent, so δns keeps rising as the section gets more slender,
including through that pole. A constant stand-in has no gradient.
"""
function _rc_nlp_delta_ns(Cm::Float64, stab::Float64)
    Cm_use = max(Cm, 1e-6)
    δ_switch = 15.0
    gap_switch = Cm_use / δ_switch
    gap = 1.0 - stab
    if gap >= gap_switch
        return max(Cm_use / gap, 1.0)
    end
    slope = δ_switch^2 / Cm_use
    return δ_switch + slope * (gap_switch - gap)
end

# ==============================================================================
# Problem Type
# ==============================================================================

"""
    RCColumnNLPProblem <: AbstractNLPProblem

Continuous optimization problem for RC column sizing.

Implements the `AbstractNLPProblem` interface for use with `optimize_continuous`.
Treats column dimensions (b, h) and reinforcement ratio (ρg) as continuous
design variables, finding the minimum-area section that satisfies ACI 318.

# Design Variables
- `x[1]` = b: Column width (inches)
- `x[2]` = h: Column depth (inches)  
- `x[3]` = ρg: Longitudinal reinforcement ratio (dimensionless, 0.01-0.08)

# Constraints
- P-M interaction: utilization ≤ 1.0
- Biaxial interaction (if Muy > 0): Bresler load contour ≤ 1.0
- Placeable steel: ρg·b·h / (`RC_COLUMN_NLP_MAX_BARS`·A_bar) ≤ 1.0

# Usage
```julia
demand = RCColumnDemand(1; Pu=500.0, Mux=200.0)  # kip, kip-ft
geometry = ConcreteMemberGeometry(4.0u"m"; k=1.0)
opts = NLPColumnOptions(material=NWC_5000)

problem = RCColumnNLPProblem(demand, geometry, opts)
result = optimize_continuous(problem; solver=:ipopt)

b_opt, h_opt, ρ_opt = result.minimizer
```
"""
struct RCColumnNLPProblem <: AbstractNLPProblem
    demand::RCColumnDemand
    # Every load case the section must satisfy. One entry for a single demand.
    # Exact duplicates are dropped. The scalars below are the start guess only.
    cases::Vector{RCColumnDemand}
    geometry::ConcreteMemberGeometry
    opts::NLPColumnOptions
    
    # Material tuple for P-M calculations (cached for efficiency)
    mat::NamedTuple{(:fc, :fy, :Es, :εcu), NTuple{4, Float64}}
    
    # Cached demand values in ACI units (kip, kip-ft)
    Pu_kip::Float64
    Mux_kipft::Float64
    Muy_kipft::Float64
    
    # Bounds in inches
    b_min::Float64
    b_max::Float64
end

"""Key of the forces one NLP case constrains. Exact duplicates share a key."""
function _rc_nlp_case_key(d::RCColumnDemand)
    return (
        Float64(to_kip(d.Pu)), Float64(to_kipft(d.Mux)), Float64(to_kipft(d.Muy)),
        Float64(to_kipft(d.M1x)), Float64(to_kipft(d.M2x)),
        Float64(to_kipft(d.M1y)), Float64(to_kipft(d.M2y)),
        Float64(d.βdns), d.transverse_load,
    )
end

"""Drop exact duplicate cases. Order of the first occurrence is kept."""
function _unique_rc_nlp_cases(cases)
    seen = Set{Tuple}()
    out = RCColumnDemand[]
    for d in cases
        k = _rc_nlp_case_key(d)
        k in seen && continue
        push!(seen, k)
        push!(out, d)
    end
    isempty(out) && throw(ArgumentError("RC column NLP needs at least one load case"))
    return out
end

function _assemble_rc_column_nlp(cases::Vector{RCColumnDemand}, demand::RCColumnDemand,
                                 geometry::ConcreteMemberGeometry, opts::NLPColumnOptions,
                                 Pu_kip::Float64, Mux_kipft::Float64, Muy_kipft::Float64)
    mat = to_material_tuple(opts.material, fy_ksi(opts.rebar_material), Es_ksi(opts.rebar_material))
    b_min = ustrip(u"inch", opts.min_dim)
    b_max = ustrip(u"inch", opts.max_dim)
    return RCColumnNLPProblem(
        demand, cases, geometry, opts, mat,
        Pu_kip, Mux_kipft, Muy_kipft,
        b_min, b_max,
    )
end

"""
    RCColumnNLPProblem(demand, geometry, opts)

Construct an RC column NLP problem from one demand, or from every case of an
[`RCColumnDemandSet`](@ref). A set keeps a separate constraint row for each
case. The stored `Pu`/`Mu` scalars are the largest compression and the largest
absolute moments, and they are used only to start the solver.
"""
function RCColumnNLPProblem(
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions
)
    return _assemble_rc_column_nlp(
        RCColumnDemand[demand], demand, geometry, opts,
        Float64(to_kip(demand.Pu)), Float64(to_kipft(demand.Mux)), Float64(to_kipft(demand.Muy)))
end

function RCColumnNLPProblem(
    set::RCColumnDemandSet,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions,
)
    cases = _unique_rc_nlp_cases(set.cases)
    Pu = maximum(Float64(to_kip(d.Pu)) for d in cases)
    Mux = maximum(abs(Float64(to_kipft(d.Mux))) for d in cases)
    Muy = maximum(abs(Float64(to_kipft(d.Muy))) for d in cases)
    rep = cases[argmax([Float64(to_kip(d.Pu)) for d in cases])]
    return _assemble_rc_column_nlp(cases, rep, geometry, opts, Pu, Mux, Muy)
end


# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

"""Number of design variables: b, h, ρg."""
n_variables(::RCColumnNLPProblem) = 3

"""Variable bounds for RC column NLP: [b_min, b_min, 0.01] to [b_max, b_max, ρ_max]."""
function variable_bounds(p::RCColumnNLPProblem)
    lb = [p.b_min, p.b_min, 0.01]   # ACI min ρ = 0.01
    ub = [p.b_max, p.b_max, p.opts.ρ_max]  # Practical ρ limit (default 0.06)
    return (lb, ub)
end

"""Clamp a square side to the column bounds and pair it with ρg = 0.04."""
function _square_column_start(c_unclamped::Float64, p::RCColumnNLPProblem)
    c0 = clamp(c_unclamped, p.b_min, p.b_max)
    return [c0, c0, 0.04]
end

"""
    axial_only_initial_guess(p::RCColumnNLPProblem) -> Vector{Float64}

Square start from axial load only: `Ag ≈ Pu / (0.40 · f'c)`, `ρg = 0.04`.

This is a solver start, not an ACI capacity. `Pu_kip` is kip and `mat.fc`
is ksi, so `Pu / f'c` is in². Zero or negative axial load falls back to
`b_min`. `size_rc_column_nlp` solves from this start as well as from
[`initial_guess`](@ref).
"""
function axial_only_initial_guess(p::RCColumnNLPProblem)
    # Same 0.40 axial start as before the moment term. Not a code equation.
    Ag_axial = p.Pu_kip / (0.40 * p.mat.fc)
    c0 = sqrt(max(Ag_axial, p.b_min^2))
    return _square_column_start(c0, p)
end

"""Initial guess from a square axial-plus-moment start at midrange ρ.

The guess is not a design strength. `Pu_kip` is kip and `mat.fc` is ksi,
so `Pu / f'c` is in². `Mux_kipft` and `Muy_kipft` are kip-ft and are
converted to kip-in before dividing by ksi and inches. Ipopt is local, so
[`size_rc_column_nlp`](@ref) also starts from [`axial_only_initial_guess`](@ref)
and keeps the better acceptable section.
"""
function initial_guess(p::RCColumnNLPProblem)
    # Starting guess only — not an ACI capacity. 0.40 is the existing
    # axial start, not a code equation. The moment term is the same kind
    # of start: it is not a design strength.
    # Ag ≈ Pu / (0.40 · f'c) + 6 · Mu / (f'c · h_est)
    # Mu = max(|Mux|, |Muy|), in kip-in; h_est is the axial-only side, in.
    Ag_axial = p.Pu_kip / (0.40 * p.mat.fc)
    h_est = sqrt(max(Ag_axial, p.b_min^2))
    Ag_est = Ag_axial
    if h_est > 0 && p.mat.fc > 0
        Mu_kipin = 12.0 * max(abs(p.Mux_kipft), abs(p.Muy_kipft))
        Ag_est += 6.0 * Mu_kipin / (p.mat.fc * h_est)
    end
    c0 = sqrt(max(Ag_est, p.b_min^2))
    return _square_column_start(c0, p)
end

"""Human-readable variable names for solver output."""
variable_names(::RCColumnNLPProblem) = ["b (in)", "h (in)", "ρg"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

"""Objective function: gross area with ρ weighting per objective type (ACI 318)."""
function objective_fn(p::RCColumnNLPProblem, x::Vector{Float64})
    b, h, ρ = x
    Ag = b * h  # Gross area (sq in)
    
    # Objective depends on what we're minimizing
    obj = p.opts.objective
    
    # Every RC objective must couple ρ so the solver gets a gradient signal
    # to trade off reinforcement ratio against section size.  Without ρ in
    # the objective, ∂obj/∂ρ = 0 and Ipopt treats ρ as slack.
    
    if obj isa MinVolume
        # Gross area with constructability penalty for high reinforcement.
        # Factor (1 + 2ρ) gives ∂obj/∂ρ = 2Ag > 0 so the solver prefers
        # moderate ρ (1–3%) unless higher ρ is needed to meet P-M demands.
        # At ρ=0.01 penalty is 2%; at ρ=0.06 it's 12%.  Without this,
        # area minimization always pegs ρ at the upper bound.
        value = Ag * (1 + 2.0 * ρ)
    elseif obj isa MinWeight
        # Total weight per unit length: concrete + steel (density-weighted).
        # Steel is ~3.3× denser, so there is a genuine tradeoff: smaller Ag
        # saves weight but higher ρ adds weight.  The solver finds the optimum.
        γ_concrete = ustrip(pcf, p.opts.material.ρ)
        γ_steel = ustrip(pcf, p.opts.rebar_material.ρ)
        value = Ag * ((1 - ρ) * γ_concrete + ρ * γ_steel)
    elseif obj isa MinCost
        isnan(p.opts.material.cost) && error("MinCost requires material.cost to be set (concrete has cost=NaN)")
        isnan(p.opts.rebar_material.cost) && error("MinCost requires material.cost to be set (rebar has cost=NaN)")
        ρ_c_kgft3 = ustrip(u"kg/ft^3", p.opts.material.ρ)
        ρ_s_kgft3 = ustrip(u"kg/ft^3", p.opts.rebar_material.ρ)
        cost_c_vol = p.opts.material.cost * ρ_c_kgft3
        cost_s_vol = p.opts.rebar_material.cost * ρ_s_kgft3
        value = Ag * ((1 - ρ) * cost_c_vol + ρ * cost_s_vol)
    elseif obj isa MinCarbon
        ρ_c_kgft3 = ustrip(u"kg/ft^3", p.opts.material.ρ)
        ρ_s_kgft3 = ustrip(u"kg/ft^3", p.opts.rebar_material.ρ)
        # Strip typed `ecc` once at the NLP boundary — JuMP needs bare Float64.
        ecc_concrete = ustrip(u"kgCO2e/kg", p.opts.material.ecc)      * ρ_c_kgft3
        ecc_steel    = ustrip(u"kgCO2e/kg", p.opts.rebar_material.ecc) * ρ_s_kgft3
        value = Ag * ((1 - ρ) * ecc_concrete + ρ * ecc_steel)
    else
        # Default: gross area with ρ penalty (same as MinVolume)
        value = Ag * (1 + 2.0 * ρ)
    end
    
    # Optional: penalize non-square sections
    if p.opts.prefer_square > 0
        aspect = max(b/h, h/b)
        value *= (1 + p.opts.prefer_square * (aspect - 1))
    end
    
    return value
end

# ==============================================================================
# AbstractNLPProblem Interface: Constraints
# ==============================================================================

"""P-M rows for one case, before the shared placeable-steel row. Biaxial only when Muy > 0, matching a single-demand problem."""
function _rc_nlp_case_row_count(d::RCColumnDemand)
    return to_kipft(d.Muy) > 1e-6 ? 2 : 1
end

"""Number of constraints: each case's P-M rows, then one placeable-steel row."""
function n_constraints(p::RCColumnNLPProblem)
    return sum(_rc_nlp_case_row_count, p.cases; init = 0) + 1
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::RCColumnNLPProblem)
    names = String[]
    several = length(p.cases) > 1
    for (i, d) in enumerate(p.cases)
        tag = several ? " case $i" : ""
        if to_kipft(d.Muy) > 1e-6
            push!(names, "P-Mx utilization$tag", "biaxial utilization$tag")
        else
            push!(names, "P-M utilization$tag")
        end
    end
    push!(names, "placeable steel")
    return names
end

"""
    _rc_column_nlp_fit_bars(b, h, opts) -> Float64

Smooth upper bound on the perimeter bar count that fits a `b × h` section
(inches), capped at `RC_COLUMN_NLP_MAX_BARS`. Bars sit `cover + d_tie + d_b/2`
from each face at a center-to-center pitch of at least `d_b` plus the
ACI 318-19 §25.2.3 clear spacing (corpus: aci-318-19, p. 469). A face of
center-line length `L` holds at most `L/pitch − 1` bars between its corners,
so the four faces hold at most `2(L_b + L_h)/pitch`. The proportional split
in `_generate_bar_positions` can place fewer; [`_nlp_trial_bar_count`](@ref)
caps at the count that actually builds.
"""
function _rc_column_nlp_fit_bars(b, h, opts::NLPColumnOptions)
    db = ustrip(u"inch", rebar(opts.bar_size).diameter)
    edge = ustrip(u"inch", opts.cover) +
           ustrip(u"inch", rebar(RC_COLUMN_NLP_TIE_BAR).diameter) + db / 2
    pitch = db + _required_clear_spacing_in(db, DEFAULT_AGGREGATE_SIZE)
    L_b = max(b - 2 * edge, 0.0)
    L_h = max(h - 2 * edge, 0.0)
    return min(Float64(RC_COLUMN_NLP_MAX_BARS), 2 * (L_b + L_h) / pitch)
end

"""
    _rc_column_placeable_steel_util(b, h, ρ, opts) -> Float64

Required steel over the most steel the built section can carry:
`ρ·b·h / (n_fit · A_bar)` with `n_fit` from [`_rc_column_nlp_fit_bars`](@ref).
`b`, `h` in inches, `ρ` dimensionless, `A_bar` in in², so the ratio is
dimensionless. Values above 1.0 mean [`_build_nlp_trial_section`](@ref) would
cap the bar count and place less steel than `ρ` asks for.
"""
function _rc_column_placeable_steel_util(b, h, ρ, opts::NLPColumnOptions)
    A_bar = ustrip(u"inch^2", rebar(opts.bar_size).A)
    return ρ * b * h / (_rc_column_nlp_fit_bars(b, h, opts) * A_bar)
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::RCColumnNLPProblem)
    nc = n_constraints(p)
    lb = fill(-Inf, nc)   # No lower bound
    ub = fill(1.0, nc)    # utilization ≤ 1.0
    return (lb, ub)
end

"""
    constraint_fns(p::RCColumnNLPProblem, x) -> Vector{Float64}

One smooth ACI 318 P-M row per load case (and a biaxial row when that case
has Muy > 0), then the placeable-steel ratio
([`_rc_column_placeable_steel_util`](@ref)). Cases are not folded into one
smooth maximum: below the balance point a lower axial load can govern.
"""
function constraint_fns(p::RCColumnNLPProblem, x::Vector{Float64})
    b, h, ρ = x
    rows = Float64[]
    for d in p.cases
        append!(rows, _rc_rect_nlp_case_rows(p, b, h, ρ, d))
    end
    push!(rows, _rc_column_placeable_steel_util(b, h, ρ, p.opts))
    return rows
end

"""P-M rows for one case. The placeable-steel row is added once, by [`constraint_fns`](@ref)."""
function _rc_rect_nlp_case_rows(p::RCColumnNLPProblem, b, h, ρ, demand::RCColumnDemand)
    Pu_kip = Float64(to_kip(demand.Pu))
    Mux_kipft = Float64(to_kipft(demand.Mux))
    Muy_kipft = Float64(to_kipft(demand.Muy))

    # Face to bar centroid (inches), the same edge distance the built section uses.
    bar = rebar(p.opts.bar_size)
    db = ustrip(u"inch", bar.diameter)
    As_bar = ustrip(u"inch^2", bar.A)
    cover = ustrip(u"inch", p.opts.cover) +
            ustrip(u"inch", rebar(RC_COLUMN_NLP_TIE_BAR).diameter) + db / 2.0

    # Slenderness. Both axes are magnified with the simplified stiffness of
    # ACI 318-19 §6.6.4.4.4(a) (corpus: aci-318-19, printed page 79) so this
    # row stays differentiable. The as-built checker applies the §6.2.5.1
    # neglect test and the §6.2.5.3 cap (δns ≤ 1.4) with the section's real EI.
    Mux_design = Mux_kipft
    Muy_design = Muy_kipft
    stab = 0.0
    δ_ratio = 0.0
    if p.opts.include_slenderness
        Ec_ksi = 57.0 * sqrt(p.mat.fc * 1000.0)
        Lu_in = ustrip(u"inch", p.geometry.Lu)
        transverse = demand.transverse_load
        # (Ig, k, end moments). Strong axis first (bending about x).
        axes = (
            (b * h^3 / 12.0, Float64(p.geometry.kx),
             to_kipft(demand.M1x), to_kipft(demand.M2x)),
            (h * b^3 / 12.0, Float64(p.geometry.ky),
             to_kipft(demand.M1y), to_kipft(demand.M2y)),
        )
        for (i, (Ig, k, M1, M2)) in enumerate(axes)
            EI = 0.4 * Ec_ksi * Ig / (1.0 + p.opts.βdns)   # kip·in²
            Pc = π^2 * EI / (max(k, 1e-6) * Lu_in)^2
            Cm = calc_Cm(M1, M2; transverse_load=transverse)
            # ACI 318-19 §6.6.4.5.2. See `_rc_nlp_delta_ns` for the smooth pole.
            stab_i = Pu_kip / (0.75 * max(Pc, 1e-6))
            δns = _rc_nlp_delta_ns(Cm, stab_i)
            ratio_i = δns / SECOND_ORDER_MOMENT_RATIO_LIMIT
            if i == 1
                Mux_design = δns * Mux_kipft
                stab = stab_i
                δ_ratio = ratio_i
            else
                Muy_design = δns * Muy_kipft
                stab = _smooth_max(stab, stab_i; k=80.0)
                δ_ratio = _smooth_max(δ_ratio, ratio_i; k=80.0)
            end
        end
    end

    # Smooth analytical P-M utilization (replaces piecewise-linear P-M diagram)
    util_x = _smooth_rc_pm_util(b, h, ρ, Pu_kip, Mux_design, p.mat;
                                      cover, n_layers=10, tie_type=p.opts.tie_type, As_bar)
    # ACI 318-19 §6.2.5.3: δns ≤ 1.4. Eq. (6.6.4.5.2) is undefined for
    # Pu ≥ 0.75 Pc; that ratio stays in the same row.
    if δ_ratio >= 1.0
        util_x = _smooth_max(util_x, δ_ratio; k=80.0)
    end
    if stab >= 1.0
        util_x = _smooth_max(util_x, stab; k=80.0)
    end

    if Muy_kipft > 1e-6
        # Biaxial: Bresler load contour
        cap = _smooth_rc_pm_capacity(b, h, ρ, Pu_kip, p.mat;
                                           cover, n_layers=10, tie_type=p.opts.tie_type, As_bar)
        φMnx = max(cap.φMn_kipft, 1e-6)
        # Weak axis: bending depth is b, compression-block width is h.
        cap_y = _smooth_rc_pm_capacity(h, b, ρ, Pu_kip, p.mat;
                                       cover, n_layers=10, tie_type=p.opts.tie_type, As_bar)
        φMny = max(cap_y.φMn_kipft, 1e-6)
        util_biax = (abs(Mux_design) / φMnx)^1.5 + (abs(Muy_design) / φMny)^1.5
        if δ_ratio >= 1.0
            util_biax = _smooth_max(util_biax, δ_ratio; k=80.0)
        end
        if stab >= 1.0
            util_biax = _smooth_max(util_biax, stab; k=80.0)
        end
        return [util_x, util_biax]
    else
        return [util_x]
    end
end

# ==============================================================================
# Helper: Build Trial Section from Continuous Variables
# ==============================================================================

"""
    _build_nlp_trial_section(b_in, h_in, ρg, opts) -> Union{RCColumnSection, Nothing}

Build an `RCColumnSection` from continuous design variables (b, h, ρg).

Determines the number of bars to achieve the target ρg and constructs the section.
The count is rounded up to even and capped at `RC_COLUMN_NLP_MAX_BARS`, so the
built section can carry less steel than `ρg` when the cap binds.
Returns `nothing` if the configuration is invalid (e.g., too many bars for dimensions).
"""
function _build_nlp_trial_section(
    b_in::Real, h_in::Real, ρg::Real,
    opts::NLPColumnOptions
)
    return _build_nlp_column_section(
        b_in, h_in, _nlp_trial_bar_count(b_in, h_in, ρg, opts), opts)
end

"""
    _nlp_trial_bar_count(b_in, h_in, ρg, opts) -> Int

Bar count [`_build_nlp_trial_section`](@ref) uses for `ρg` at `b_in × h_in`
(inches): `ceil(ρg·b·h / A_bar)`, at least the tie-type minimum, rounded up
to even, then capped at [`_nlp_max_buildable_bars`](@ref).
"""
function _nlp_trial_bar_count(b_in::Real, h_in::Real, ρg::Real, opts::NLPColumnOptions)
    As_bar = ustrip(u"inch^2", rebar(opts.bar_size).A)
    n_bars = max(_nlp_min_bars(opts), ceil(Int, ρg * b_in * h_in / As_bar))
    # Even count for a symmetric perimeter arrangement
    n_bars = iseven(n_bars) ? n_bars : n_bars + 1
    return min(n_bars, _nlp_max_buildable_bars(b_in, h_in, opts))
end

"""
    _nlp_max_buildable_bars(b_in, h_in, opts) -> Int

Largest even bar count up to `RC_COLUMN_NLP_MAX_BARS` that
[`_build_nlp_column_section`](@ref) accepts at `b_in × h_in` — in practice the
ACI 318-19 §25.2.3 clear-spacing limit. Below the tie-type minimum when not
even that count fits.
"""
function _nlp_max_buildable_bars(b_in::Real, h_in::Real, opts::NLPColumnOptions)
    n_min = _nlp_min_bars(opts)
    for n in RC_COLUMN_NLP_MAX_BARS:-2:n_min
        isnothing(_build_nlp_column_section(b_in, h_in, n, opts)) || return n
    end
    return n_min - 2
end

"""Minimum bar count for the tie type (4 tied, 6 spiral), as in `_validate_column_section`."""
_nlp_min_bars(opts::NLPColumnOptions) = opts.tie_type == :spiral ? 6 : 4

"""
    _build_nlp_column_section(b_in, h_in, n_bars, opts) -> Union{RCColumnSection, Nothing}

Build a `b_in × h_in` (inches) section with `n_bars` of `opts.bar_size`.
Returns `nothing` when the constructor rejects the layout.
"""
function _build_nlp_column_section(
    b_in::Real, h_in::Real, n_bars::Int,
    opts::NLPColumnOptions
)
    n_bars <= RC_COLUMN_NLP_MAX_BARS || return nothing
    try
        return RCColumnSection(
            b = b_in * u"inch",
            h = h_in * u"inch",
            bar_size = opts.bar_size,
            n_bars = n_bars,
            cover = opts.cover,
            tie_type = opts.tie_type,
            tie_bar_size = RC_COLUMN_NLP_TIE_BAR
        )
    catch e
        # Invalid configuration (§25.2.3 spacing, ρg, bar count)
        (e isa ArgumentError || e isa ErrorException) || rethrow()
        return nothing
    end
end

# ==============================================================================
