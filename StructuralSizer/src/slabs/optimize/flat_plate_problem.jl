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

"""Column fields read by Eq. (13-7) and §13.6.3.3 classification."""
const _NLP_EQ137_COLUMN_FIELDS = (:vertex_idx, :position, :c1, :c2, :θ, :shape,
                                  :structural_offset, :boundary_edge_dirs, :story)

"""Cell fields read by Eq. (13-7) (face and service loads)."""
const _NLP_EQ137_CELL_FIELDS = (:face_idx, :sdl, :live_load, :self_weight)

"""Immutable copy of the `fields` that `obj` has (arrays copied)."""
function _nlp_freeze(obj, fields)
    ks = Tuple(k for k in fields if hasproperty(obj, k))
    vals = map(ks) do k
        v = getproperty(obj, k)
        v isa AbstractArray ? copy(v) : v
    end
    return NamedTuple{ks}(vals)
end

"""True when `obj` has exactly the `fields` frozen in `fz`, with equal values."""
function _nlp_frozen_matches(obj, fz, fields)::Bool
    n = 0
    for k in fields
        hasproperty(obj, k) || continue
        n += 1
        haskey(fz, k) || return false
        isequal(getproperty(obj, k), fz[k]) || return false
    end
    return n == length(fz)
end

"""
Frozen view of what Eq. (13-7) reads from `struc` and `columns`:
`(view, frozen_columns)`.

`view` has the duck-typed `struc` interface the Eq. (13-7) helpers use:
`cells` (face index and loads), `slabs` (the same slab objects, so slab
identity and a neighbour's live `result` thickness still work), `columns`
(frozen sizes, positions, vertices) and, when present, `skeleton` (copied
vertex coordinates and face lists).  A column that appears in both
`struc.columns` and `columns` is frozen once, so identity checks agree.
"""
function _nlp_eq137_snapshot(struc, columns)
    memo = IdDict{Any,Any}()
    freeze(col) = get!(() -> _nlp_freeze(col, _NLP_EQ137_COLUMN_FIELDS), memo, col)
    view = (
        cells = hasproperty(struc, :cells) ?
                Any[_nlp_freeze(c, _NLP_EQ137_CELL_FIELDS) for c in struc.cells] : Any[],
        slabs = hasproperty(struc, :slabs) ? collect(Any, struc.slabs) : Any[],
        columns = hasproperty(struc, :columns) ? Any[freeze(c) for c in struc.columns] : Any[],
    )
    if _eq137_geometry_available(struc)
        skel = struc.skeleton
        view = merge(view, (skeleton = (
            geometry = (vertex_coords = copy(skel.geometry.vertex_coords),),
            face_vertex_indices = [copy(f) for f in skel.face_vertex_indices],
        ),))
    end
    return view, Any[freeze(c) for c in columns]
end

"""Each slab's cell list (copied), for the staleness check."""
_nlp_slab_cells(struc) = hasproperty(struc, :slabs) ?
    [hasproperty(sl, :cell_indices) ? copy(sl.cell_indices) : nothing for sl in struc.slabs] :
    Any[]

"""The design slab's drop panel (`nothing` without one or without a slab)."""
_nlp_drop_panel(slab) =
    (slab !== nothing && hasproperty(slab, :drop_panel)) ? slab.drop_panel : nothing

"""
Fresh Eq. (13-7) maps for `NLPEq137Maps`, built from a frozen copy of the
geometry (`_nlp_eq137_snapshot`) and carrying that copy, plus the design
slab's drop panel at that time (`drop_panel`), so a grid point reads the
drop from the same snapshot as the geometry.
"""
function _nlp_eq137_build(struc, columns, slab = nothing)
    view, cols = _nlp_eq137_snapshot(struc, columns)
    return merge(_eq137_context(view, cols),
                 (struc = view, columns = cols, slab_cells = _nlp_slab_cells(struc),
                  drop_panel = _nlp_drop_panel(slab)))
end

"""
One snapshot of the Eq. (13-7) maps and geometry of `p`, or `nothing`
without geometry.

From `NLPEq137Maps` (one atomic read) when present, else the maps carried
directly by a hand-built `eq137` (missing ones are `nothing`) with its live
`struc` and `columns`.  Callers take one snapshot per `evaluate` and pass
it down, so every column and both directions at a grid point use the same
maps and the same geometry.
"""
function _nlp_eq137_maps(p::FlatPlateNLPProblem)
    eq = p.eq137
    isnothing(eq) && return nothing
    hasproperty(eq, :maps) && return @atomic eq.maps.ctx
    field(k) = hasproperty(eq, k) ? getproperty(eq, k) : nothing
    return (index = field(:index), cell_slab = field(:cell_slab),
            vertex_column = field(:vertex_column), partway = field(:partway),
            struc = eq.struc, columns = eq.columns, slab_cells = nothing,
            drop_panel = _nlp_drop_panel(field(:slab)))
end

"""
True when `struc` / `columns` (and the design `slab`'s drop panel, when
`slab` is given) no longer match the frozen copy in `ctx`.

Compares every slab (identity and cell list), cell (face and loads),
column (frozen fields), vertex coordinate and face list, and the drop
panel, with `isequal`.
This is exact (no hash collisions) and stops at the first difference; with
nothing changed it is one allocation-free pass over those arrays.

The loops run over the frozen copy and check each live index before
reading it (`checkbounds`), so a live array that shrinks during the pass
reads as changed (stale, rebuilt) rather than throwing `BoundsError`.  One
that grows is caught by the length check of the next call.
"""
function _nlp_eq137_differs(ctx, struc, columns, slab = nothing)::Bool
    if slab !== nothing
        isequal(_nlp_drop_panel(slab), get(ctx, :drop_panel, nothing)) || return true
    end
    snap = ctx.struc
    slabs = hasproperty(struc, :slabs) ? struc.slabs : ()
    length(slabs) == length(snap.slabs) == length(ctx.slab_cells) || return true
    for k in eachindex(snap.slabs)
        checkbounds(Bool, slabs, k) || return true
        sl = slabs[k]
        sl === snap.slabs[k] || return true
        cells_k = hasproperty(sl, :cell_indices) ? sl.cell_indices : nothing
        isequal(cells_k, ctx.slab_cells[k]) || return true
    end
    cells = hasproperty(struc, :cells) ? struc.cells : ()
    length(cells) == length(snap.cells) || return true
    for k in eachindex(snap.cells)
        checkbounds(Bool, cells, k) || return true
        _nlp_frozen_matches(cells[k], snap.cells[k], _NLP_EQ137_CELL_FIELDS) || return true
    end
    scols = hasproperty(struc, :columns) ? struc.columns : ()
    for (live, frozen) in ((scols, snap.columns), (columns, ctx.columns))
        length(live) == length(frozen) || return true
        for k in eachindex(frozen)
            checkbounds(Bool, live, k) || return true
            _nlp_frozen_matches(live[k], frozen[k], _NLP_EQ137_COLUMN_FIELDS) || return true
        end
    end
    has_geo = _eq137_geometry_available(struc)
    has_geo == hasproperty(snap, :skeleton) || return true
    if has_geo
        skel = struc.skeleton
        isequal(skel.geometry.vertex_coords, snap.skeleton.geometry.vertex_coords) || return true
        isequal(skel.face_vertex_indices, snap.skeleton.face_vertex_indices) || return true
    end
    return false
end

"""True when the stored Eq. (13-7) maps no longer match `struc`."""
function _nlp_eq137_stale(p::FlatPlateNLPProblem)::Bool
    eq = p.eq137
    (isnothing(eq) || !hasproperty(eq, :maps)) && return false
    return _nlp_eq137_differs(@atomic(eq.maps.ctx), eq.struc, eq.columns, eq.slab)
end

"""
Replace the stored Eq. (13-7) maps when `struc` changed after the problem
was built (`_nlp_eq137_stale`).

Builds a complete new map set and stores it with one atomic write; the old
maps are never mutated, so a thread still holding the previous snapshot
reads consistent (if superseded) data.  Must be called under
`p.trace_lock`, which re-checks staleness there, so one thread rebuilds
while the others wait and then find the maps current.  A problem without
`maps` (hand-built `eq137`) is left as is.  Emits a `:decision` trace
event (`eq137_maps_rebuilt`).
"""
function _nlp_refresh_eq137!(p::FlatPlateNLPProblem, tc)
    _nlp_eq137_stale(p) || return nothing
    eq = p.eq137
    @atomic eq.maps.ctx = _nlp_eq137_build(eq.struc, eq.columns, eq.slab)
    emit!(tc, :slab, "_nlp_refresh_eq137!", "", :decision;
          reason = "eq137_maps_rebuilt")
    return nothing
end

TRACE_REGISTRY[(:_nlp_refresh_eq137!, :slab)] = TracedFunctionMeta(
    :_nlp_refresh_eq137!, :slab, [:decision], nothing, @__FILE__, @__LINE__,
)

"""
Per-call staleness check of `evaluate`.

Skipped while a frozen sweep runs (`_nlp_frozen_sweep`).  Otherwise the
exact comparison (`_nlp_eq137_stale`) runs without the lock: it only reads
`struc` and the atomically published snapshot, so grid-search threads run
it in parallel.  Only when it finds a difference is `p.trace_lock` taken,
where `_nlp_refresh_eq137!` checks again and rebuilds once.
"""
function _nlp_check_eq137!(p::FlatPlateNLPProblem, tc)
    eq = p.eq137
    (isnothing(eq) || !hasproperty(eq, :maps)) && return nothing
    @atomic(eq.maps.sweeps) > 0 && return nothing
    _nlp_eq137_stale(p) || return nothing
    lock(p.trace_lock) do
        _nlp_refresh_eq137!(p, tc)
    end
    return nothing
end

"""
    _nlp_frozen_sweep(f, p::FlatPlateNLPProblem)

Run the grid sweep `f()` with the Eq. (13-7) maps checked once.

Stale maps are rebuilt before the sweep (`_nlp_refresh_eq137!`); during it
`evaluate` skips the per-call check, so the threaded search does no
O(cells + columns) comparison per grid point.  The geometry (`struc`
slabs, cells, columns, skeleton, and the problem's columns) must not be
mutated while the sweep runs.  The exact check runs again afterwards: a
mutation during the sweep means its points were evaluated against
superseded geometry, so a `:failure` trace event
(`eq137_geometry_mutated_during_sweep`) is emitted and an `ErrorException`
is thrown rather than returning that result.  Without `maps` this is
`f()`.
"""
function _nlp_frozen_sweep(f, p::FlatPlateNLPProblem)
    eq = p.eq137
    (isnothing(eq) || !hasproperty(eq, :maps)) && return f()
    buf = isnothing(p.tc) ? nothing :
          TraceCollector(TraceEvent[], p.tc.enabled, p.tc.start_time)
    lock(p.trace_lock) do
        _nlp_refresh_eq137!(p, buf)
    end
    _nlp_flush_trace!(p, buf)
    @atomic eq.maps.sweeps += 1
    result = try
        f()
    finally
        @atomic eq.maps.sweeps -= 1
    end
    if _nlp_eq137_stale(p)
        lock(p.trace_lock) do
            emit!(p.tc, :slab, "_nlp_frozen_sweep", "", :failure;
                  reason = "eq137_geometry_mutated_during_sweep")
        end
        error("FlatPlateNLPProblem: building geometry changed during the grid sweep; " *
              "its Eq. (13-7) results used superseded geometry and are discarded.")
    end
    return result
end

TRACE_REGISTRY[(:_nlp_frozen_sweep, :slab)] = TracedFunctionMeta(
    :_nlp_frozen_sweep, :slab, [:failure], nothing, @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_nlp_transfer_moment, :slab)] = TracedFunctionMeta(
    :_nlp_transfer_moment, :slab, [:fallback, :failure], nothing, @__FILE__, @__LINE__,
)

TRACE_REGISTRY[(:_nlp_support_moment, :slab)] = TracedFunctionMeta(
    :_nlp_support_moment, :slab, [:fallback], nothing, @__FILE__, @__LINE__,
)

"""
Positional fallback of `_nlp_transfer_moment` / `_nlp_support_moment`:
trace it, and warn once when the column is missing from stored geometry
(a data mismatch, not the geometry-free test constructor).
"""
function _nlp_trace_positional(p::FlatPlateNLPProblem, i::Int, stage::String, tc)
    reason = if isnothing(p.eq137)
        "no_geometry_position"
    else
        _eq137_warn_once(:nlp_column_not_in_geometry,
            "FlatPlateNLPProblem: column index exceeds the stored Eq. (13-7) columns; using the position tag for that column.")
        "column_not_in_geometry"
    end
    emit!(tc, :slab, stage, "nlp_col_$(i)", :fallback;
          reason = reason, position = String(p.column_positions[i]))
    return nothing
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
Transfer moment at NLP column `i` along `span_axis`.

With a stored building this is `_eq137_transfer_moment`: Eq. (13-7) where
the slab is continuous on both sides of the column in this direction,
0.3 M0 where it is not (ACI 318-11 §13.6.3.6, corpus: aci-318-11, page 255).
An edge column is exterior only perpendicular to the edge.

Without a stored building (positional constructor, `eq137 === nothing`)
the column `position` is the fallback: non-interior gets 0.3 M0 in both
directions, interior gets the equal-span Eq. (13-7) envelope.  The same
fallback is used for a column index beyond the stored columns.  Either
emits a `:fallback` trace event.  On the fallback, a negative service
`qD` / `qL` returns NaN with a `:failure` event (`negative_service_load`);
the geometry path does the same inside `_eq137_transfer_moment`.
`c_trial` is the decision-variable column size on the slab under design.
`maps` is the `_nlp_eq137_maps` snapshot `evaluate` took for this grid
point; its frozen `struc` and `columns` are the geometry read here.
"""
function _nlp_transfer_moment(p::FlatPlateNLPProblem, i::Int,
                              qD::Pressure, qL::Pressure, l2::Length, ln::Length,
                              span_axis, c_trial::Length, M0;
                              design_drop::Pressure = 0.0psf, tc = p.tc,
                              maps = _nlp_eq137_maps(p))
    if isnothing(p.eq137) || i > length(maps.columns)
        _nlp_trace_positional(p, i, "_nlp_transfer_moment", tc)
        if _eq137_negative_input(qD, qL)
            # ACI 318-11 §13.6.1.5 (corpus: aci-318-11, page 252): gravity
            # loads only.  Rejected like a non-finite demand.
            emit!(tc, :slab, "_nlp_transfer_moment", "nlp_col_$(i)", :failure;
                  reason = "negative_service_load")
            return NaN * kip * u"ft"
        end
        if p.column_positions[i] != :interior
            return 0.3 * M0
        end
        return governing_interior_unbalanced_moment(qD, qL, l2, ln, qD, qL, l2, ln)
    end
    return _eq137_transfer_moment(
        maps.struc, p.eq137.slab, maps.columns[i], span_axis,
        qD, qL, l2, ln, M0;
        c_override = c_trial, extra_columns = maps.columns,
        index = maps.index, vertex_column = maps.vertex_column,
        cell_slab = maps.cell_slab, partway = maps.partway,
        design_drop = design_drop, γ = p.γ_concrete, tc = tc,
    )
end

"""
Negative flexural moment at NLP column `i` along `span_axis`.

With a stored building this is `_ddm_support_moment`, the DDM flexural
assignment (ACI 318-11 §13.6.3.3, corpus: aci-318-11, page 254) classified
by the same panel geometry as `_nlp_transfer_moment`, including the
geometry/tag disagreement envelope.  Without one, the column `position` is
the fallback: non-interior is an exterior support.  As for the transfer
moment, the fallback emits a `:fallback` trace event.  `maps` is the
same per-grid-point snapshot (maps and geometry).
"""
function _nlp_support_moment(p::FlatPlateNLPProblem, i::Int, span_axis,
                             M_neg_ext, M_neg_int; tc = p.tc,
                             maps = _nlp_eq137_maps(p))
    if isnothing(p.eq137) || i > length(maps.columns)
        _nlp_trace_positional(p, i, "_nlp_support_moment", tc)
        return p.column_positions[i] != :interior ? M_neg_ext : M_neg_int
    end
    return _ddm_support_moment(maps.struc, maps.columns[i], span_axis,
                               M_neg_ext, M_neg_int; index = maps.index,
                               vertex_column = maps.vertex_column,
                               partway = maps.partway, tc = tc)
end

"""
    evaluate(p::FlatPlateNLPProblem, x) -> (feasible, objective, result)

Evaluate a single (h, c) grid point.  Runs DDM moments, punching shear,
one-way shear, an inner rebar sweep (with deflection check per bar size),
and returns the best feasible configuration.

Fallbacks raised here go to `p.tc`.  The grid search calls `evaluate` on
many threads, so each call buffers its events and merges them under
`p.trace_lock`, keeping one copy of each distinct event.  Stale Eq. (13-7)
maps are first replaced (`_nlp_check_eq137!`: a lock-free exact check,
the lock only to rebuild; skipped inside a frozen sweep,
`_nlp_frozen_sweep`); the point is then evaluated against one snapshot
(`_nlp_eq137_maps`) of the maps and of the frozen geometry they were built
from, so a mutation of `struc` during the call cannot mix old maps with
new coordinates, faces or column sizes, and Mub and Muy see the same
geometry.  Outside a frozen sweep the mutation is picked up by the next
call.
"""
function evaluate(p::FlatPlateNLPProblem, x::Vector{Float64})
    buf = isnothing(p.tc) ? nothing :
          TraceCollector(TraceEvent[], p.tc.enabled, p.tc.start_time)
    try
        _nlp_check_eq137!(p, buf)
        return _evaluate_point(p, x, buf, _nlp_eq137_maps(p))
    finally
        _nlp_flush_trace!(p, buf)
    end
end

"""Merge one `evaluate` call's buffered events into `p.tc`, dropping repeats."""
function _nlp_flush_trace!(p::FlatPlateNLPProblem, buf)
    (isnothing(buf) || isempty(buf.events)) && return nothing
    lock(p.trace_lock) do
        for e in buf.events
            key = (e.layer, e.stage, e.element_id, e.event_type, e.data)
            key in p.trace_seen && continue
            push!(p.trace_seen, key)
            push!(p.tc.events, e)
        end
    end
    return nothing
end

"""
`evaluate` body for one grid point; trace events go to `tc`, Eq. (13-7)
lookups use the `maps` snapshot.
"""
function _evaluate_point(p::FlatPlateNLPProblem, x::Vector{Float64}, tc, maps)
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
    # Drop-panel projection is dead load on qD, factored with D.
    # Kept separately so a neighbour that falls back to trial self-weight
    # is not also charged the design slab's drop.
    # The drop is read from the `maps` snapshot, so a grid point sees the
    # drop that was current with the geometry it reads.
    q_drop = 0.0psf
    drop_panel = isnothing(maps) ? nothing : get(maps, :drop_panel, nothing)
    if !isnothing(drop_panel)
        q_drop = _eq137_drop_service(drop_panel, p.l1 * p.l2, p.γ_concrete)
        qD = uconvert(psf, qD + q_drop)
    end
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

    # Secondary-axis static moment: ACI 318-11 §13.6.2.2 Eq. (13-4)
    # (corpus: aci-318-11, page 253) with ℓ1 ↔ ℓ2 swapped.
    ln2 = clear_span(l2, c_ft)
    if ustrip(u"ft", ln2) <= 0
        return (false, Inf, nothing)
    end
    M0_y = total_static_moment(qu, l1, ln2)

    # ── Column-level demands (preallocated) ──
    n_col = length(p.column_positions)
    T_M = typeof(uconvert(kip * u"ft", M0))
    T_F = typeof(uconvert(kip, qu * l2 * ln / 2))

    col_moments = Vector{T_M}(undef, n_col)
    col_shears  = Vector{T_F}(undef, n_col)
    unbal_mom   = Vector{T_M}(undef, n_col)
    unbal_mom_y = Vector{T_M}(undef, n_col)

    # Primary axis of the panel.  Without stored geometry the NLP is one
    # panel and both directions use that panel's own spans.
    span_axis = isnothing(p.eq137) ? (1.0, 0.0) : p.eq137.span_axis
    span_axis_y = (-span_axis[2], span_axis[1])

    for i in 1:n_col
        # ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254): exterior-
        # negative at an exterior support, interior-negative at an interior
        # one.  Classified along this axis by the same panel geometry as the
        # transfer moment below, which is what DDM does.
        M   = _nlp_support_moment(p, i, span_axis, M_neg_ext, M_neg_int;
                                  tc = tc, maps = maps)
        # Transfer is direction-aware.  Eq. (13-7) (corpus: aci-318-11,
        # page 258) where the slab continues on both sides of this column
        # along the axis; §13.6.3.6 0.3 M0 (page 255) where it does not.
        # An edge column is exterior only perpendicular to the edge.
        # Without stored geometry, `position` is the fallback (a corner is
        # exterior both ways).  `c` is the trial column size.
        Mub = _nlp_transfer_moment(p, i, qD, qL, l2, ln, span_axis, c, M0;
                                   design_drop = q_drop, tc = tc, maps = maps)
        Muy = _nlp_transfer_moment(p, i, qD, qL, l1, ln2, span_axis_y, c, M0_y;
                                   design_drop = q_drop, tc = tc, maps = maps)

        A_trib_ft2 = p.column_trib_ft2[i]
        Vu = if A_trib_ft2 > 0
            uconvert(kip, qu * A_trib_ft2 * u"ft^2")
        else
            uconvert(kip, qu * l2 * ln / 2)
        end

        col_moments[i] = uconvert(kip * u"ft", M)
        col_shears[i]  = Vu
        unbal_mom[i]   = uconvert(kip * u"ft", Mub)
        unbal_mom_y[i] = uconvert(kip * u"ft", Muy)
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
            λ=p.λ, φ_shear=p.φ_shear, Muy=unbal_mom_y[i],
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
        rebar = _evaluate_rebar_for_size(p, moment_results, h, d, bar_sz, c, unbal_mom_y)
        if isinf(ustrip(u"inch^2", rebar.total_As))
            return (false, Inf, nothing)
        end

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
    _evaluate_rebar_for_size(p, moment_results, h, d, bar_size, c, unbal_mom_y) -> NamedTuple

Design all strip reinforcement using a specific bar size and return
total steel area + the positive-column-strip As (for deflection check).
`c` is the square NLP column size; `unbal_mom_y` is the perpendicular-axis
unbalanced moment (not stored on `MomentAnalysisResult`). Transfer `As`
from `governing_transfer_reinforcement` is added; Inf is infeasible.
"""
function _evaluate_rebar_for_size(p::FlatPlateNLPProblem, moment_results, h, d, bar_size,
                                  c, unbal_mom_y)
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

    # ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250): fraction of
    # unbalanced moment transferred by flexure. Inf = section_inadequate
    # (same sentinel as `_run_final_design`). Square `c` matches evaluate's
    # col_proxy — punching swap is a no-op; transfer As was the miss.
    n_col = length(p.column_positions)
    for i in 1:n_col
        gov = governing_transfer_reinforcement(
            moment_results.unbalanced_moments[i], unbal_mom_y[i],
            c, c, h, d, p.fc, p.fy;
            position = p.column_positions[i],
            free_edge_parallel = :c2)
        if transfer_section_inadequate(gov.As)
            return (total_As=Inf*u"inch^2", As_pos_cs=Inf*u"inch^2")
        end
        total_As += gov.As
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
        # Strip typed `ecc` once at the NLP boundary — JuMP needs bare Float64.
        ecc_c = ustrip(u"kgCO2e/kg", p.material.concrete.ecc)
        ecc_s = ustrip(u"kgCO2e/kg", p.material.rebar.ecc)
        return V_conc * ρ_c * ecc_c + V_steel * ρ_s * ecc_s
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

