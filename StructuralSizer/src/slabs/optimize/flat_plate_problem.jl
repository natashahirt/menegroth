# ==============================================================================
# Flat Plate NLP Problem Definition
# ==============================================================================
#
# Grid-search optimization for flat plate slab + column sizing.
#
# Decision variables: x = [h_in, c_in]
#   h_in: slab thickness (inches)
#   c_in: square column dimension (inches)
#
# At each grid point the evaluator:
#   1. Computes DDM moments for (h, c)
#   2. Checks punching shear for every column position type
#   3. Checks one-way shear
#   4. Sweeps candidate bar sizes (#4–#8):
#      a. Designs all strip reinforcement for that bar size
#      b. Checks two-way deflection with actual provided As
#      c. Scores (concrete + rebar) by the chosen objective
#   5. Returns the best feasible (bar_size, objective) or infeasible
#
# Reference: ACI 318-11 Chapters 9, 10, 11, 13
# ==============================================================================

# ==============================================================================
# Problem Struct
# ==============================================================================

"""
    FlatPlateNLPProblem <: AbstractNLPProblem

2D grid-search optimization for flat plate slab + column sizing.

Variables: `[h, c]` in inches (slab thickness, square column size).
For each grid point the evaluator runs all ACI 318 checks and sweeps
candidate bar sizes to find the best rebar/thickness trade-off.

# Constructor
```julia
problem = FlatPlateNLPProblem(struc, slab, columns, opts;
                              h_max=12u"inch", c_max=24u"inch")
```
"""
struct FlatPlateNLPProblem <: AbstractNLPProblem
    # Material
    material::ReinforcedConcreteMaterial
    fc          # Pressure  – concrete strength
    fy          # Pressure  – rebar yield
    Es          # Pressure  – rebar modulus
    Ecs         # Pressure  – concrete modulus (density-aware Ec)
    γ_concrete  # Density   – concrete mass density
    λ::Float64  # lightweight concrete factor

    # Panel geometry
    l1          # Length – span in analysis direction
    l2          # Length – tributary width

    # Loads (from first cell)
    sdl         # Pressure – superimposed dead load
    qL          # Pressure – live load

    # Column info (per supporting column)
    column_positions::Vector{Symbol}
    column_trib_ft2::Vector{Float64}   # tributary area in ft² (for Vu calc)
    column_height_sum_m::Float64       # Σ column heights [m] (for column volume)

    # DDM moment coefficients
    c_neg_ext::Float64
    c_neg_int::Float64
    c_pos::Float64

    # Design parameters
    cover       # Length
    bar_dia     # Length
    φ_flexure::Float64
    φ_shear::Float64
    deflection_limit::Symbol

    # Variable bounds (inches)
    h_bounds_in::Tuple{Float64, Float64}
    c_bounds_in::Tuple{Float64, Float64}

    # Rebar sweep
    bar_sizes::Vector{Int}

    # Objective
    objective::AbstractObjective
end

# ==============================================================================
# Convenience Constructor (Unitful inputs → stripped internals)
# ==============================================================================

"""
    FlatPlateNLPProblem(struc, slab, columns, opts; kwargs...)

Build a flat-plate NLP problem from a `BuildingStructure`, `Slab`,
supporting columns, and design options.

# Keyword Arguments
- `h_max::Length`: Upper bound on slab thickness (default: ACI min + 6")
- `c_min::Length`: Lower bound on column size (default: span/15)
- `c_max::Length`: Upper bound on column size (default: `opts.max_column_size`)
- `bar_sizes::Vector{Int}`: Candidate bar sizes (default: [4,5,6,7,8])
"""
function FlatPlateNLPProblem(
    struc, slab, columns, opts::FlatPlateOptions;
    h_max::Union{Length, Nothing} = nothing,
    c_min::Union{Length, Nothing} = nothing,
    c_max::Union{Length, Nothing} = nothing,
    bar_sizes::Vector{Int} = [4, 5, 6, 7, 8],
)
    mat = opts.material
    fc  = mat.concrete.fc′
    fy  = mat.rebar.Fy
    Es  = mat.rebar.E
    γ_c = mat.concrete.ρ
    λ   = isnothing(opts.λ) ? mat.concrete.λ : opts.λ
    wc_pcf = ustrip(pcf, γ_c)
    Ecs = Ec(fc, wc_pcf)

    l1 = slab.spans.primary
    l2 = slab.spans.secondary

    # Loads from first cell
    cell = struc.cells[first(slab.cell_indices)]
    sdl  = uconvert(psf, cell.sdl)
    qL_v = uconvert(psf, cell.live_load)

    # Column info
    col_positions = Symbol[col.position for col in columns]
    col_trib_ft2  = Float64[
        ustrip(u"ft^2", sum(values(col.tributary_cell_areas); init=0.0) * u"m^2")
        for col in columns
    ]
    col_h_sum_m = sum(ustrip(u"m", col.base.L) for col in columns)

    # DDM coefficients from panel type
    cells = [struc.cells[idx] for idx in slab.cell_indices]
    has_ext = any(c -> c.position in [:corner, :edge], cells)
    if has_ext
        c_neg_ext = 0.26;  c_pos = 0.52;  c_neg_int = 0.70
    else
        c_neg_ext = 0.65;  c_pos = 0.35;  c_neg_int = 0.65
    end

    # Design parameters
    cover   = opts.cover
    bar_dia = bar_diameter(opts.bar_size)

    # Bounds
    ln_max   = max(l1, l2)
    has_edge = any(p != :interior for p in col_positions)
    h_aci    = min_thickness(FlatPlate(), ln_max; discontinuous_edge=has_edge)
    h_min_in = isnothing(opts.min_h) ? ustrip(u"inch", h_aci) : ustrip(u"inch", opts.min_h)
    h_max_in = isnothing(h_max)     ? h_min_in + 6.0          : ustrip(u"inch", h_max)

    c_span   = estimate_column_size_from_span(ln_max)
    c_min_in = isnothing(c_min) ? ustrip(u"inch", c_span)              : ustrip(u"inch", c_min)
    c_max_in = isnothing(c_max) ? ustrip(u"inch", opts.max_column_size) : ustrip(u"inch", c_max)

    FlatPlateNLPProblem(
        mat, fc, fy, Es, Ecs, γ_c, λ,
        l1, l2, sdl, qL_v,
        col_positions, col_trib_ft2, col_h_sum_m,
        c_neg_ext, c_neg_int, c_pos,
        cover, bar_dia,
        opts.φ_flexure, opts.φ_shear, opts.deflection_limit,
        (h_min_in, h_max_in), (c_min_in, c_max_in),
        bar_sizes,
        opts.objective,
    )
end

# ==============================================================================
# AbstractNLPProblem Interface
# ==============================================================================

"""Flat plate optimization has 2 decision variables: `[h, c]`."""
n_variables(::FlatPlateNLPProblem) = 2

"""Return `(lb, ub)` bound vectors in inches for `[h, c]`."""
function variable_bounds(p::FlatPlateNLPProblem)
    lb = [p.h_bounds_in[1], p.c_bounds_in[1]]
    ub = [p.h_bounds_in[2], p.c_bounds_in[2]]
    return (lb, ub)
end

"""Return midpoint initial guess `[h₀, c₀]` in inches."""
function initial_guess(p::FlatPlateNLPProblem)
    h0 = (p.h_bounds_in[1] + p.h_bounds_in[2]) / 2
    c0 = (p.c_bounds_in[1] + p.c_bounds_in[2]) / 2
    return [h0, c0]
end

"""Return variable name strings for the flat plate optimization."""
variable_names(::FlatPlateNLPProblem) = ["h_in", "c_in"]

# ==============================================================================
# Objective Conversion
# ==============================================================================
# evaluate() returns the full composite objective (concrete + steel), so the
# grid solver's _convert_objective should be identity.

"""Identity conversion — `evaluate()` already returns the composite objective."""
_convert_objective(::MinVolume, ::FlatPlateNLPProblem, v::Float64) = v
_convert_objective(::MinWeight, ::FlatPlateNLPProblem, v::Float64) = v
_convert_objective(::MinCarbon, ::FlatPlateNLPProblem, v::Float64) = v
_convert_objective(::MinCost,   ::FlatPlateNLPProblem, v::Float64) = v

# ==============================================================================
# Core Evaluate (called at every grid point)
# ==============================================================================

"""
    evaluate(p::FlatPlateNLPProblem, x) -> (feasible, objective, result)

Evaluate a single (h, c) grid point.  Runs DDM moments, punching shear,
one-way shear, an inner rebar sweep (with deflection check per bar size),
and returns the best feasible configuration.
"""
function evaluate(p::FlatPlateNLPProblem, x::Vector{Float64})
    h_in, c_in = x
    h = h_in * u"inch"
    c = c_in * u"inch"

    # ── Effective depth ──
    d = effective_depth(h; cover=p.cover, bar_diameter=p.bar_dia)
    if ustrip(u"inch", d) <= 0.5
        return (false, Inf, nothing)
    end

    # ── Loads ──
    sw  = slab_self_weight(h, p.γ_concrete)
    qD  = uconvert(psf, p.sdl) + sw
    qL  = uconvert(psf, p.qL)
    qu  = max(factored_pressure(default_combo, qD, qL),
              factored_pressure(strength_1_4D, qD, qL))

    # ── DDM moments ──
    l1 = uconvert(u"ft", p.l1)
    l2 = uconvert(u"ft", p.l2)
    c_ft = uconvert(u"ft", c)
    ln = clear_span(l1, c_ft)

    if ustrip(u"ft", ln) <= 0
        return (false, Inf, nothing)
    end

    M0        = total_static_moment(qu, l2, ln)
    M_neg_ext = p.c_neg_ext * M0
    M_neg_int = p.c_neg_int * M0
    M_pos     = p.c_pos * M0

    # ── Column-level demands (preallocated) ──
    n_col = length(p.column_positions)
    T_M = typeof(uconvert(kip * u"ft", M0))
    T_F = typeof(uconvert(kip, qu * l2 * ln / 2))

    col_moments = Vector{T_M}(undef, n_col)
    col_shears  = Vector{T_F}(undef, n_col)
    unbal_mom   = Vector{T_M}(undef, n_col)

    for i in 1:n_col
        is_ext = (p.column_positions[i] != :interior)
        M   = is_ext ? M_neg_ext : M_neg_int
        Mub = is_ext ? M : zero(M)

        A_trib_ft2 = p.column_trib_ft2[i]
        Vu = if A_trib_ft2 > 0
            uconvert(kip, qu * A_trib_ft2 * u"ft^2")
        else
            uconvert(kip, qu * l2 * ln / 2)
        end

        col_moments[i] = uconvert(kip * u"ft", M)
        col_shears[i]  = Vu
        unbal_mom[i]   = uconvert(kip * u"ft", Mub)
    end
    Vu_max = uconvert(kip, qu * l2 * ln / 2)

    moment_results = MomentAnalysisResult(
        uconvert(kip * u"ft", M0),
        uconvert(kip * u"ft", M_neg_ext),
        uconvert(kip * u"ft", M_neg_int),
        uconvert(kip * u"ft", M_pos),
        qu, qD, qL,
        l1, l2, ln, c_ft,
        col_moments, col_shears, unbal_mom, Vu_max,
    )

    # ── Punching shear check (every column) ──
    for i in 1:n_col
        col_proxy = (c1=c, c2=c, position=p.column_positions[i])
        punch = check_punching_for_column(
            col_proxy, col_shears[i], unbal_mom[i], d, h, p.fc;
            λ=p.λ, φ_shear=p.φ_shear,
        )
        if !punch.ok
            return (false, Inf, nothing)
        end
    end

    # ── One-way shear check ──
    shear = check_one_way_shear(moment_results, d, p.fc;
                                λ=p.λ, φ_shear=p.φ_shear)
    if !shear.ok
        return (false, Inf, nothing)
    end

    # ── Inner rebar sweep ──
    best_obj    = Inf
    best_result = nothing

    spans      = (primary=p.l1, secondary=p.l2)
    col_proxies = [(position=p.column_positions[i],) for i in 1:n_col]

    for bar_sz in p.bar_sizes
        rebar = _evaluate_rebar_for_size(p, moment_results, h, d, bar_sz)

        # Deflection check with actual provided As
        defl = check_two_way_deflection(
            moment_results, h, d, p.fc, p.fy, p.Es, p.Ecs,
            spans, p.γ_concrete, col_proxies;
            limit_type = p.deflection_limit,
            As_provided = rebar.As_pos_cs,
        )

        if !defl.ok
            continue
        end

        obj = _flat_plate_objective(p, h, c, rebar)
        if obj < best_obj
            best_obj = obj
            best_result = (
                bar_size    = bar_sz,
                rebar       = rebar,
                deflection  = defl,
                objective   = obj,
            )
        end
    end

    if isnothing(best_result)
        return (false, Inf, nothing)
    end

    result = (
        h_in  = h_in,
        c_in  = c_in,
        h     = h,
        c     = c,
        d     = d,
        bar_size       = best_result.bar_size,
        total_As       = best_result.rebar.total_As,
        As_pos_cs      = best_result.rebar.As_pos_cs,
        deflection     = best_result.deflection,
        moment_results = moment_results,
        objective      = best_result.objective,
    )

    return (true, best_result.objective, result)
end

# ==============================================================================
# Internal: Rebar Evaluation for a Given Bar Size
# ==============================================================================

"""
    _evaluate_rebar_for_size(p, moment_results, h, d, bar_size) -> NamedTuple

Design all strip reinforcement using a specific bar size and return
total steel area + the positive-column-strip As (for deflection check).
"""
function _evaluate_rebar_for_size(p::FlatPlateNLPProblem, moment_results, h, d, bar_size)
    l2 = moment_results.l2
    cs_w = l2 / 2   # column strip width
    ms_w = l2 / 2   # middle strip width

    # ACI 8.10.5 transverse distribution
    strip_designs = [
        # (Mu,                                    width,  label)
        (1.00 * moment_results.M_neg_ext, cs_w, :cs_ext_neg),
        (0.60 * moment_results.M_pos,     cs_w, :cs_pos),
        (0.75 * moment_results.M_neg_int, cs_w, :cs_int_neg),
        (0.40 * moment_results.M_pos,     ms_w, :ms_pos),
        (0.25 * moment_results.M_neg_int, ms_w, :ms_int_neg),
    ]

    total_As = 0.0u"inch^2"
    As_pos_cs = 0.0u"inch^2"

    for (Mu, width, label) in strip_designs
        As_reqd  = required_reinforcement(Mu, width, d, p.fc, p.fy)
        # Section inadequate — return Inf to signal infeasible point
        if isinf(As_reqd)
            return (total_As=Inf*u"inch^2", As_pos_cs=Inf*u"inch^2")
        end
        As_min   = minimum_reinforcement(width, h, p.fy)
        As_design = max(As_reqd, As_min)

        bars = select_bars_for_size(As_design, width, bar_size)
        total_As += bars.As_provided

        if label == :cs_pos
            As_pos_cs = bars.As_provided
        end
    end

    return (total_As=total_As, As_pos_cs=As_pos_cs)
end

# ==============================================================================
# Internal: Composite Objective (Concrete + Steel)
# ==============================================================================

"""
    _flat_plate_objective(p, h, c, rebar) -> Float64

Compute the composite objective for a flat-plate grid point.
Accounts for both slab concrete, column concrete, and rebar steel.
"""
function _flat_plate_objective(p::FlatPlateNLPProblem, h, c, rebar)
    # Slab concrete volume (per panel)
    V_slab = ustrip(u"m", h) * ustrip(u"m", p.l1) * ustrip(u"m", p.l2)

    # Column concrete volume (c² × Σ column heights)
    c_m = ustrip(u"m", c)
    V_col = c_m^2 * p.column_height_sum_m

    V_conc = V_slab + V_col   # m³

    # Steel volume ≈ total As × span length (approximate)
    V_steel = ustrip(u"m^2", rebar.total_As) * ustrip(u"m", p.l1)  # m³

    obj = p.objective
    ρ_c = ustrip(u"kg/m^3", p.material.concrete.ρ)
    ρ_s = ustrip(u"kg/m^3", p.material.rebar.ρ)

    if obj isa MinVolume
        return V_conc + V_steel
    elseif obj isa MinWeight
        return V_conc * ρ_c + V_steel * ρ_s
    elseif obj isa MinCarbon
        return V_conc * ρ_c * p.material.concrete.ecc +
               V_steel * ρ_s * p.material.rebar.ecc
    elseif obj isa MinCost
        cc = p.material.concrete.cost
        cs = p.material.rebar.cost
        (isnan(cc) || isnan(cs)) &&
            error("MinCost requires both concrete.cost and rebar.cost to be set")
        return V_conc * ρ_c * cc + V_steel * ρ_s * cs
    else
        error("Unsupported objective: $(typeof(obj))")
    end
end

