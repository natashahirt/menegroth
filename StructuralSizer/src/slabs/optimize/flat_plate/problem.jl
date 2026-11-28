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
    NLPEq137Maps(ctx)

Holder for the Eq. (13-7) lookup maps of a `FlatPlateNLPProblem`.

`ctx` is a NamedTuple `(index, cell_slab, vertex_column, partway, struc,
columns, slab_cells)` that is never mutated.  `struc` and `columns` are a
frozen copy of the geometry the maps were built from
(`_nlp_eq137_snapshot`); `slab_cells` is each slab's cell list at that
time.  A rebuild builds a fresh one and replaces the field atomically
(`_nlp_refresh_eq137!`).  `evaluate` reads the field once per call
(`_nlp_eq137_maps`) and uses only that snapshot, for the maps and the
geometry alike, so concurrent grid-search threads never see a half-built
map and one call never mixes two geometries.

`sweeps` counts the grid sweeps running with frozen geometry
(`_nlp_frozen_sweep`); while it is positive `evaluate` skips its own
staleness check.
"""
mutable struct NLPEq137Maps
    @atomic ctx::NamedTuple
    @atomic sweeps::Int
end

NLPEq137Maps(ctx::NamedTuple) = NLPEq137Maps(ctx, 0)

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

    # Geometry for per-column Eq. (13-7).  `nothing` → position fallback
    # (positional constructors used by tests that have no building).
    # Named tuple `(struc, slab, columns, span_axis, maps)` when built
    # from a BuildingStructure; `maps::NLPEq137Maps` holds the lookup maps
    # and the frozen geometry they were built from, swapped as a whole when
    # `evaluate` finds them stale.  A hand-built tuple may carry `index`,
    # `cell_slab`, `vertex_column`, `partway` directly instead (never
    # rebuilt; geometry read from `struc` / `columns`).
    eq137

    # Trace collector for Eq. (13-7) / §13.6.3.3 fallbacks raised during
    # `evaluate`.  `evaluate` runs on many threads, so events are buffered
    # per grid point and merged under `trace_lock`; `trace_seen` keeps one
    # copy of each distinct fallback (they repeat at every grid point).
    tc::Union{Nothing, TraceCollector}
    trace_lock::ReentrantLock
    trace_seen::Set{Any}
end

"""
Positional constructor without trace state (`tc = nothing`).

With `eq137 = nothing` (tests that have no building geometry) Eq. (13-7)
uses the equal-span collapse of this one panel, still enveloped over
§9.2.1 Eq. (9-1) and Eq. (9-2).
"""
function FlatPlateNLPProblem(
    material, fc, fy, Es, Ecs, γ_concrete, λ,
    l1, l2, sdl, qL,
    column_positions, column_trib_ft2, column_height_sum_m,
    c_neg_ext, c_neg_int, c_pos,
    cover, bar_dia, φ_flexure, φ_shear, deflection_limit,
    h_bounds_in, c_bounds_in, bar_sizes, objective,
    eq137 = nothing, tc::Union{Nothing, TraceCollector} = nothing,
)
    FlatPlateNLPProblem(
        material, fc, fy, Es, Ecs, γ_concrete, λ,
        l1, l2, sdl, qL,
        column_positions, column_trib_ft2, column_height_sum_m,
        c_neg_ext, c_neg_int, c_pos,
        cover, bar_dia, φ_flexure, φ_shear, deflection_limit,
        h_bounds_in, c_bounds_in, bar_sizes, objective,
        eq137, tc, ReentrantLock(), Set{Any}(),
    )
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
- `tc`: Trace collector for fallbacks raised during `evaluate` (default: `nothing`)
"""
function FlatPlateNLPProblem(
    struc, slab, columns, opts::FlatPlateOptions;
    h_max::Union{Length, Nothing} = nothing,
    c_min::Union{Length, Nothing} = nothing,
    c_max::Union{Length, Nothing} = nothing,
    bar_sizes::Vector{Int} = [4, 5, 6, 7, 8],
    tc::Union{Nothing, TraceCollector} = nothing,
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

    # Governing (largest) SDL and live load over the slab's cells, as in
    # `_flat_plate_uniform_pressures` (ENGINEERING JUDGMENT documented there).
    sdl_max, live_max = _slab_service_pressures(struc, slab, "(flat plate)")
    sdl  = uconvert(psf, sdl_max)
    qL_v = uconvert(psf, live_max)

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
    has_edge = slab_discontinuous_edge(struc, slab, columns)
    h_aci    = min_thickness(FlatPlate(), ln_max; discontinuous_edge=has_edge, fy)
    h_min_in = isnothing(opts.min_h) ? ustrip(u"inch", h_aci) : ustrip(u"inch", opts.min_h)
    h_max_in = isnothing(h_max)     ? h_min_in + 6.0          : ustrip(u"inch", h_max)

    c_span   = estimate_column_size_from_span(ln_max)
    c_min_in = isnothing(c_min) ? ustrip(u"inch", c_span)              : ustrip(u"inch", c_min)
    c_max_in = isnothing(c_max) ? ustrip(u"inch", opts.max_column_size) : ustrip(u"inch", c_max)

    # Same lookup the DDM path uses (`_eq137_transfer_moment`).  Stored
    # here because `evaluate` only receives the problem, while `struc` and
    # `slab` exist only in this constructor.  Only h and c change across
    # grid points; if the slabs, cells, columns or skeleton geometry change
    # afterwards, `evaluate` sees that they no longer match the frozen copy
    # and swaps in fresh maps.
    eq137 = (
        struc = struc,
        slab = slab,
        columns = columns,
        span_axis = _get_span_axis(slab),
        maps = NLPEq137Maps(_nlp_eq137_build(struc, columns, slab)),
    )

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
        eq137,
        tc,
    )
end

