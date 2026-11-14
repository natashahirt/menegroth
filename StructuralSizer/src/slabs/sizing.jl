# =============================================================================
# Slab Sizing API (structure-based)
# =============================================================================
#
# Public hierarchy:
#   size_slabs!   → size all slabs in a BuildingStructure
#   size_slab!    → size one slab (debugging / scripting)
#
# Internal:
#   _size_slab!   → type-dispatched implementation hook (unit-test friendly)
#
# Method-specific pipelines (e.g. size_flat_plate!) are internal and called from _size_slab!.
#
# =============================================================================

# Register trace contracts for slab sizing entrypoints.
# NOTE: Docstrings conflict with `@traced` (Julia doc macro ordering), so we register manually.
TRACE_REGISTRY[(:size_slabs!, :slab)] =
    TracedFunctionMeta(:size_slabs!, :slab,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)
TRACE_REGISTRY[(:size_slab!, :slab)] =
    TracedFunctionMeta(:size_slab!, :slab,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

"""
    size_slabs!(struc; options, column_opts=nothing, max_iterations=10, verbose=false) -> struc

Size/design all slabs in `struc` using the floor type stored on each slab.

- Uses the **type system** via `floor_type(slab.floor_type)` for dispatch.
- Accepts any `AbstractFloorOptions` subtype for configuration.
"""
function size_slabs!(
    struc;
    options::AbstractFloorOptions = FlatPlateOptions(),
    column_opts = nothing,
    max_iterations::Int = 10,
    verbose::Bool = false,
    fire_rating::Real = 0.0,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    emit!(tc, :slab, "size_slabs!", "", :enter;
          n_slabs=length(struc.slabs),
          options_type=string(typeof(options)),
          has_column_opts=!isnothing(column_opts),
          max_iterations=max_iterations)
    # ─── Validate: flat plate/slab require RC columns; one_way/vault accept RC or PixelFrame ───
    has_flat_plate_slab = any(s -> s.floor_type in (:flat_plate, :flat_slab), struc.slabs)
    if has_flat_plate_slab && !isnothing(column_opts)
        if column_opts isa PixelFrameColumnOptions
            emit!(tc, :slab, "size_slabs!", "", :failure;
                  reason="flat_plate_requires_rc_columns",
                  column_opts_type=string(typeof(column_opts)))
            throw(ArgumentError(
                "Flat plate/slab requires reinforced concrete columns. " *
                "PixelFrame columns are not supported for beamless slab systems."))
        end
        if !(column_opts isa ConcreteColumnOptions)
            emit!(tc, :slab, "size_slabs!", "", :failure;
                  reason="flat_plate_requires_rc_columns",
                  column_opts_type=string(typeof(column_opts)))
            throw(ArgumentError(
                "Flat plate/slab requires reinforced concrete columns. " *
                "Steel columns are not supported for beamless slab systems."))
        end
    end
    has_concrete_slab = any(s -> floor_type(s.floor_type) isa AbstractConcreteSlab, struc.slabs)
    if has_concrete_slab && !isnothing(column_opts) && !has_flat_plate_slab
        if !(column_opts isa ConcreteColumnOptions) && !(column_opts isa PixelFrameColumnOptions)
            emit!(tc, :slab, "size_slabs!", "", :failure;
                  reason="concrete_slab_requires_concrete_or_pixelframe_columns",
                  column_opts_type=string(typeof(column_opts)))
            throw(ArgumentError(
                "Concrete slab floor systems require ConcreteColumnOptions or PixelFrameColumnOptions, " *
                "got $(typeof(column_opts)). Steel columns are not supported with concrete slabs."))
        end
    end

    # Pre-build column P-M cache once if flat-plate slabs exist (expensive P-M diagrams)
    _col_cache = nothing
    if any(s -> s.floor_type in (:flat_plate, :flat_slab), struc.slabs)
        _col_cache = _precompute_flat_plate_col_cache(column_opts)
    end

    # Use parallel batches if available and multi-threaded
    batches = hasproperty(struc, :slab_parallel_batches) ? struc.slab_parallel_batches : nothing
    use_parallel = Threads.nthreads() > 1 && !isnothing(batches) && !isempty(batches)

    if use_parallel
        emit!(tc, :slab, "size_slabs!", "", :decision; parallel=true, n_batches=length(batches))
        for batch in batches
            tasks = map(batch) do slab_idx
                Threads.@spawn size_slab!(struc, slab_idx; options=options,
                    column_opts=column_opts, max_iterations=max_iterations,
                    verbose=verbose, _col_cache=_col_cache, fire_rating=fire_rating, tc=tc)
            end
            fetch.(tasks)
        end
    else
        emit!(tc, :slab, "size_slabs!", "", :decision; parallel=false)
        for slab_idx in eachindex(struc.slabs)
            size_slab!(struc, slab_idx; options=options, column_opts=column_opts,
                       max_iterations=max_iterations, verbose=verbose,
                       _col_cache=_col_cache, fire_rating=fire_rating, tc=tc)
        end
    end
    emit!(tc, :slab, "size_slabs!", "", :exit)
    return struc
end

"""Pre-build the column P-M capacity cache for flat plate design (shared across all slabs).
Returns `nothing` for NLP strategy (no catalog to cache)."""
function _precompute_flat_plate_col_cache(column_opts)
    col_opts = isnothing(column_opts) ? ConcreteColumnOptions() : column_opts
    col_opts isa ConcreteColumnOptions || return nothing
    col_opts.sizing_strategy == :nlp && return nothing

    cat = isnothing(col_opts.custom_catalog) ?
        rc_column_catalog(col_opts.section_shape, col_opts.catalog) :
        col_opts.custom_catalog

    checker = ACIColumnChecker(;
        include_slenderness = col_opts.include_slenderness,
        include_biaxial = col_opts.include_biaxial,
        fy_ksi = ustrip(ksi, col_opts.rebar_material.Fy),
        Es_ksi = ustrip(ksi, col_opts.rebar_material.E),
        max_depth = col_opts.max_depth,
    )

    cache = create_cache(checker, length(cat))
    precompute_capacities!(checker, cache, cat, col_opts.material, col_opts.objective)
    return cache
end

"""
    prepare_floor_design_workspace(request) -> FloorDesignWorkspace

Prepare read-only data that may be shared across compatible floor requests.
"""
function prepare_floor_design_workspace(request::FloorDesignRequest)
    cache = request.system isa Union{FlatPlate, FlatSlab} ?
        _precompute_flat_plate_col_cache(request.column_options) :
        nothing
    return FloorDesignWorkspace(cache)
end

"""
    size_slab!(struc, slab_idx; options, kwargs...) -> FloorDesignOutcome

Size/design a single slab in `struc` by index. Intended for debugging and scripting.

This is the low-level mutating kernel used by owning-package adapters. Its
return value always uses the normalized floor-design outcome contract.
"""
function size_slab!(
    struc,
    slab_idx::Int;
    options::AbstractFloorOptions = FlatPlateOptions(),
    column_opts = nothing,
    max_iterations::Int = 10,
    verbose::Bool = false,
    _col_cache = nothing,
    fire_rating::Real = 0.0,
    defer_asap_process::Bool = false,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    slab = struc.slabs[slab_idx]
    ft = floor_type(slab.floor_type)
    emit!(tc, :slab, "size_slab!", string(slab_idx), :enter;
          floor_type=string(slab.floor_type),
          dispatch_type=string(typeof(ft)),
          options_type=string(typeof(options)))
    raw_result = _size_slab!(ft, struc, slab, slab_idx;
                             options=options, column_opts=column_opts,
                             max_iterations=max_iterations, verbose=verbose,
                             _col_cache=_col_cache, fire_rating=fire_rating,
                             defer_asap_process=defer_asap_process, tc=tc)
    outcome = _floor_design_outcome(raw_result, slab)
    emit!(tc, :slab, "size_slab!", string(slab_idx), :exit;
          result_type=string(typeof(outcome)),
          status=string(outcome.status))
    return outcome
end

"""
    size_slab!(struc, request::FloorDesignRequest; kwargs...) -> FloorDesignOutcome

Execute a normalized request against a mutable working structure. The owning
package is responsible for running this kernel on isolated state and installing
only successful proposals.
"""
function size_slab!(
    struc,
    request::FloorDesignRequest;
    verbose::Bool = false,
    _col_cache = nothing,
    defer_asap_process::Bool = true,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    slab_idx = request.source.index
    slab_idx <= length(struc.slabs) ||
        throw(BoundsError(struc.slabs, slab_idx))
    actual_system = floor_type(struc.slabs[slab_idx].floor_type)
    typeof(actual_system) === typeof(request.system) ||
        throw(ArgumentError(
            "floor source $slab_idx resolves to $(typeof(actual_system)), " *
            "but the request declares $(typeof(request.system))",
        ))
    return size_slab!(
        struc,
        slab_idx;
        options = request.options,
        column_opts = request.column_options,
        max_iterations = request.max_iterations,
        verbose = verbose,
        _col_cache = _col_cache,
        fire_rating = request.fire_rating,
        defer_asap_process = defer_asap_process,
        tc = tc,
    )
end

# =============================================================================
# Internal dispatch hook
# =============================================================================

"""Reject floor types without a sizing implementation."""
function _size_slab!(
    system::AbstractFloorSystem,
    struc,
    slab,
    slab_idx;
    kwargs...,
)
    throw(UnsupportedFloorSystemError(typeof(system)))
end

function _floor_design_outcome(raw_result, slab)
    iterations = raw_result isa NamedTuple ? get(raw_result, :iterations, 0) : 0

    if raw_result isa AbstractFloorResult
        proposal = FloorDesignProposal(
            slab.result,
            hasproperty(slab, :design_details) ? slab.design_details : raw_result,
            hasproperty(slab, :drop_panel) ? slab.drop_panel : nothing,
            FloorCellLoadUpdate[],
            FloorSupportUpdate[],
        )
        return FloorDesignOutcome(
            FLOOR_DESIGN_SUCCEEDED,
            proposal,
            raw_result,
            FloorDesignDiagnostic[],
            iterations,
        )
    end

    if raw_result isa NamedTuple && get(raw_result, :converged, false)
        proposal = FloorDesignProposal(
            slab.result,
            hasproperty(slab, :design_details) ? slab.design_details : raw_result,
            hasproperty(slab, :drop_panel) ? slab.drop_panel : nothing,
            FloorCellLoadUpdate[],
            FloorSupportUpdate[],
        )
        return FloorDesignOutcome(
            FLOOR_DESIGN_SUCCEEDED,
            proposal,
            raw_result,
            FloorDesignDiagnostic[],
            iterations,
        )
    end

    reason = raw_result isa NamedTuple ?
        String(get(raw_result, :failure_reason, "design_failed")) :
        "design_failed"
    failing_check = raw_result isa NamedTuple ?
        String(get(raw_result, :failing_check, "")) :
        ""
    status = reason == "non_convergence" ?
        FLOOR_DESIGN_NOT_CONVERGED :
        FLOOR_DESIGN_INFEASIBLE
    message = isempty(failing_check) ? reason : "$reason ($failing_check)"
    return FloorDesignOutcome{Nothing, typeof(raw_result)}(
        status,
        nothing,
        raw_result,
        [FloorDesignDiagnostic(Symbol(reason), message)],
        iterations,
    )
end

# =============================================================================
# Concrete: Flat plate (full design pipeline)
# =============================================================================

"""Dispatch `_size_slab!` for flat plate slabs: runs the full ACI 318 Ch 8 design pipeline."""
function _size_slab!(::FlatPlate, struc, slab, slab_idx;
                     options::AbstractFloorOptions = FlatPlateOptions(),
                     column_opts = nothing,
                     max_iterations::Int = 10,
                     verbose::Bool = false,
                     _col_cache = nothing,
                     fire_rating::Real = 0.0,
                     defer_asap_process::Bool = false,
                     tc::Union{Nothing, TraceCollector} = nothing)
    col_opts = isnothing(column_opts) ? ConcreteColumnOptions() : column_opts
    fp_opts = options isa FlatSlabOptions ? options.base : options
    method = fp_opts.method

    verbose && @info "Sizing flat plate slab $slab_idx" cells=length(slab.cell_indices) method=typeof(method)

    result = size_flat_plate!(struc, slab, col_opts;
                              method=method,
                              opts=fp_opts,
                              max_iterations=max_iterations,
                              verbose=verbose,
                              _col_cache=_col_cache,
                              slab_idx=slab_idx,
                              fire_rating=fire_rating,
                              defer_asap_process=defer_asap_process,
                              tc=tc)
    
    # Handle non-convergence gracefully
    if hasproperty(result, :converged) && !result.converged
        @warn "Flat plate slab $slab_idx did not converge" check=result.failing_check iters=result.iterations h=result.h_final
        hasproperty(slab, :design_details) && (slab.design_details = result)
        return result
    end
    
    slab.result = result.slab_result
    # Preserve the full design output (column P-M, integrity, transfer, ρ′)
    # so downstream consumers don't lose the detail.
    hasproperty(slab, :design_details) && (slab.design_details = result)
    return result
end

# =============================================================================
# Concrete: Flat slab (with drop panels — shared pipeline with FlatPlate)
# =============================================================================

"""Dispatch `_size_slab!` for flat slabs with drop panels: shared pipeline with `FlatPlate`."""
function _size_slab!(::FlatSlab, struc, slab, slab_idx;
                     options::AbstractFloorOptions = FlatSlabOptions(),
                     column_opts = nothing,
                     max_iterations::Int = 10,
                     verbose::Bool = false,
                     _col_cache = nothing,
                     fire_rating::Real = 0.0,
                     defer_asap_process::Bool = false,
                     tc::Union{Nothing, TraceCollector} = nothing)
    col_opts = isnothing(column_opts) ? ConcreteColumnOptions() : column_opts

    fs_opts = options isa FlatSlabOptions ? options : FlatSlabOptions(base = options)
    fp_opts = as_flat_plate_options(fs_opts)
    method = fp_opts.method

    verbose && @info "Sizing flat slab (with drop panels) $slab_idx" cells=length(slab.cell_indices) method=typeof(method)

    # Build drop panel geometry from options + slab geometry
    # This will be passed as a keyword to size_flat_plate! which propagates it
    # through the pipeline hooks.
    drop_panel = _build_drop_panel_geometry(fs_opts, struc, slab)

    # Use the shared flat plate design pipeline with drop panel injection
    result = size_flat_plate!(struc, slab, col_opts;
                              method=method,
                              opts=fp_opts,
                              max_iterations=max_iterations,
                              verbose=verbose,
                              _col_cache=_col_cache,
                              slab_idx=slab_idx,
                              drop_panel=drop_panel,
                              fire_rating=fire_rating,
                              defer_asap_process=defer_asap_process,
                              tc=tc)
    
    # Always persist drop panel geometry (pipeline adjusts it for ACI compliance
    # even when the overall design doesn't converge)
    slab.drop_panel = result.drop_panel

    # Handle non-convergence gracefully
    if hasproperty(result, :converged) && !result.converged
        @warn "Flat slab $slab_idx did not converge" check=result.failing_check iters=result.iterations h=result.h_final
        hasproperty(slab, :design_details) && (slab.design_details = result)
        return result
    end
    
    slab.result = result.slab_result
    # Preserve the full design output (column P-M, integrity, transfer, ρ′)
    hasproperty(slab, :design_details) && (slab.design_details = result)
    
    return result
end

"""
    _build_drop_panel_geometry(opts::FlatSlabOptions, struc, slab) -> DropPanelGeometry

Construct drop panel geometry from FlatSlabOptions and slab geometry.

Auto-sizes dimensions when not explicitly provided:
- `h_drop`: Smallest standard lumber depth satisfying ACI 8.2.4(a)
- `a_drop`: ACI minimum extent of l/6 from column center
"""
function _build_drop_panel_geometry(opts::FlatSlabOptions, struc, slab)
    return _build_drop_panel_geometry(opts, slab)
end

"""Construct normalized drop-panel geometry without a building dependency."""
function _build_drop_panel_geometry(opts::FlatSlabOptions, slab)
    # Get representative span lengths for drop panel sizing
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    
    # Get slab thickness estimate (for h_drop auto-sizing)
    # Use a rough initial estimate: ln/36 for interior (flat slab minimum)
    # The pipeline will refine this iteratively
    h_est = l1 / 36
    
    # h_drop: user-specified or auto-size to smallest standard depth ≥ h/4
    if !isnothing(opts.h_drop)
        h_drop = opts.h_drop
    else
        h_drop = auto_size_drop_depth(h_est)
    end
    
    # a_drop: user-specified ratio or ACI minimum (l/6)
    ratio = isnothing(opts.a_drop_ratio) ? (1.0 / 6.0) : opts.a_drop_ratio
    a_drop_1 = ratio * l1
    a_drop_2 = ratio * l2
    
    # Normalize to consistent units
    h_drop_m = uconvert(u"m", h_drop)
    a1_m = uconvert(u"m", a_drop_1)
    a2_m = uconvert(u"m", a_drop_2)
    
    return DropPanelGeometry(h_drop_m, a1_m, a2_m)
end

"""
    auto_size_drop_depth(h_slab) -> Length

Select the smallest standard lumber depth satisfying ACI 8.2.4(a):
h_drop ≥ h_slab / 4.

Standard depths (with 3/4" plyform): 2.25", 4.25", 6.25", 8.0".
"""
function auto_size_drop_depth(h_slab::Length)
    min_proj = h_slab / 4
    min_proj_inch = ustrip(u"inch", min_proj)
    
    for d in STANDARD_DROP_DEPTHS_INCH
        if d >= min_proj_inch
            return d * u"inch"
        end
    end
    
    # If none of the standard depths work, use the largest + extra
    @warn "No standard drop depth satisfies ACI 8.2.4(a) for h_slab=$(h_slab). Using minimum projection."
    return uconvert(u"inch", min_proj)
end

# =============================================================================
# Concrete: one-way and two-way slabs on beams
# =============================================================================

"""Rib spacing stored on the slab, when the topping spans rib to rib."""
function _slab_topping_span(slab)
    details = hasproperty(slab, :design_details) ? slab.design_details : nothing
    details === nothing && return nothing
    hasproperty(details, :topping_span) || return nothing
    return details.topping_span
end

"""Service dead and live on a slab: the greatest pressure among its cells."""
function _slab_service_pressures(struc, slab, slab_idx)
    isempty(slab.cell_indices) && throw(ArgumentError("Slab $slab_idx has no cells."))
    sdl = maximum(struc.cells[i].sdl for i in slab.cell_indices)
    live = maximum(struc.cells[i].live_load for i in slab.cell_indices)
    return sdl, live
end

function _install_span_result!(struc, slab, result)
    sw = self_weight(result)
    for i in slab.cell_indices
        struc.cells[i].self_weight = sw
    end
    slab.result = result
    return result
end

"""Concrete from floor options, when the options name one."""
function _options_concrete(opts)
    if opts isa FlatSlabOptions
        return opts.base.material.concrete
    elseif hasproperty(opts, :material) && opts.material isa ReinforcedConcreteMaterial
        return opts.material.concrete
    elseif hasproperty(opts, :material) && opts.material isa Concrete
        return opts.material
    end
    return NWC_4000
end

"""
Merge `options.support` with the condition the beams and the adjacent bays
actually give. The thicker one is used, so an explicit cantilever stays a
cantilever and a single bay is not credited with continuity it does not have.
"""
function _with_one_way_support(struc, slab, slab_idx, options)
    options isa OneWayOptions || return options
    derived = _slab_span_support(struc, slab)
    use = thicker_support(options.support, derived)
    use == options.support && return options
    @warn "one-way slab $slab_idx spans as $use, so its thickness does not use $(options.support)"
    return OneWayOptions(options.material, options.cover, options.bar_size, use)
end

"""
Table 9.5(a) condition of a slab (ACI 318-11, corpus: aci-318-11, page 131):
the thickest condition among its cells. A single bay with a support at each
end is simply supported.
"""
function _slab_span_support(struc, slab)
    cond = nothing
    for cell_idx in slab.cell_indices
        ends = _cell_span_ends(struc, slab, cell_idx)
        this = one_way_support_condition(ends[1], ends[2])
        cond = cond === nothing ? this : thicker_support(cond, this)
    end
    return something(cond, SIMPLE)
end

"""Length of an unframed opening's cantilever on this slab, or `nothing`."""
_opening_cantilever_span(::Any, ::Any) = nothing

"""The two ends of a cell's span: `:free`, `:supported`, or `:continuous`."""
function _cell_span_ends(struc, slab, cell_idx)
    cell = struc.cells[cell_idx]
    skel = struc.skeleton
    face = cell.face_idx
    verts = skel.face_vertex_indices[face]
    edges = skel.face_edge_indices[face]
    length(verts) == length(edges) || throw(ArgumentError(
        "face $face has $(length(verts)) vertices and $(length(edges)) edges"))
    axis = (Float64(cell.spans.axis[1]), Float64(cell.spans.axis[2]))
    xy = [_plan_xy(skel.vertices[v]) for v in verts]
    c = (sum(p[1] for p in xy) / length(xy), sum(p[2] for p in xy) / length(xy))
    pos, neg = :free, :free
    n = length(edges)
    for i in 1:n
        a, b = xy[i], xy[mod1(i + 1, n)]
        dx, dy = b[1] - a[1], b[2] - a[2]
        L = hypot(dx, dy)
        L < 1e-9 && continue
        # A span end faces the span. An edge running with the span is a side.
        abs((dx / L) * axis[1] + (dy / L) * axis[2]) > 0.5 && continue
        mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
        side = (mid[1] - c[1]) * axis[1] + (mid[2] - c[2]) * axis[2]
        abs(side) < 1e-9 && continue
        kind = _span_end_kind(struc, slab, edges[i], face)
        if side > 0
            pos = _stronger_end(pos, kind)
        else
            neg = _stronger_end(neg, kind)
        end
    end
    # An edge more than 60° off the normal of the span is skipped above.
    # On a skewed bay every beam can be that oblique, so both ends stay
    # :free even though the beams are there. Credit the beams by which
    # side of the cell they sit on. Continuity still requires an edge the
    # span actually ends on, so this fallback is support only.
    # ACI 318-11 Table 9.5(a) (corpus: aci-318-11, page 131): two supports
    # and no continuity is a simple span; one support is a cantilever.
    (pos == :free && neg == :free) || return (pos, neg)
    left = false
    right = false
    for i in 1:n
        _span_end_kind(struc, slab, edges[i], face) == :free && continue
        a, b = xy[i], xy[mod1(i + 1, n)]
        mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
        side = (mid[1] - c[1]) * axis[1] + (mid[2] - c[2]) * axis[2]
        if side > 1e-6
            right = true
        elseif side < -1e-6
            left = true
        end
    end
    left && right && return (:supported, :supported)
    left && return (:supported, :free)
    right && return (:free, :supported)
    return (pos, neg)
end

_coord_m(x::Unitful.Length) = Float64(ustrip(u"m", x))
_coord_m(x::Real) = Float64(x)
_plan_xy(v) = (p = Meshes.coords(v); (_coord_m(p.x), _coord_m(p.y)))

function _span_end_kind(struc, slab, edge, face)
    skel = struc.skeleton
    supported = false
    for g in (:beams, :walls, :joists, :secondary)
        edge in get(skel.groups_edges, g, Int[]) && (supported = true)
    end
    supported || return :free
    other = nothing
    for (f, es) in enumerate(skel.face_edge_indices)
        f == face && continue
        edge in es && (other = f)
    end
    other === nothing && return :supported
    ci = findfirst(c -> c.face_idx == other, struc.cells)
    ci === nothing && return :supported
    # The slab running past the beam is continuous whether or not the next
    # bay was grouped into this slab.
    struc.cells[ci].floor_type in (:unknown, :grade) ? :supported : :continuous
end

_stronger_end(a, b) = (_end_rank(a) >= _end_rank(b) ? a : b)
_end_rank(s) = s == :continuous ? 2 : s == :supported ? 1 : 0

"""
    _size_slab!(::OneWay, ...) -> CIPSlabResult

Minimum one-way thickness on the panel's primary span, ACI 318-11 Table 9.5(a)
(corpus: aci-318-11, page 131). The analysis method is recorded on
`slab.design_details`. Bars are not sized here.
"""
function _size_slab!(::OneWay, struc, slab, slab_idx;
                     options::AbstractFloorOptions = OneWayOptions(),
                     verbose::Bool = false,
                     kwargs...)
    sdl, live = _slab_service_pressures(struc, slab, slab_idx)
    span = _slab_topping_span(slab)
    span === nothing && (span = slab.spans.primary)
    options = _with_one_way_support(struc, slab, slab_idx, options)
    support = hasproperty(options, :support) ? options.support : nothing
    verbose && @info "Sizing one-way slab $slab_idx" span = span support = support
    result = _size_span_floor(OneWay(), span, sdl, live;
                               material = _options_concrete(options), options = options)
    Lc = _opening_cantilever_span(struc, slab)
    if Lc !== nothing
        cant_opts = OneWayOptions(options.material, options.cover, options.bar_size, CANTILEVER)
        cant = _size_span_floor(OneWay(), Lc, sdl, live;
                                 material = _options_concrete(options), options = cant_opts)
        if total_depth(cant) > total_depth(result)
            @warn "one-way slab $slab_idx has an unframed opening $(Lc) from a support; its thickness is the cantilever"
            result = cant
        end
    end
    installed = _install_span_result!(struc, slab, result)
    dead = installed.self_weight + sdl
    method, reasons = assign_panel_analysis!(OneWay(), struc, slab, dead, live)
    verbose && @info "One-way analysis" method=typeof(method) reasons=reasons
    return installed
end

"""
    _size_slab!(::TwoWay, ...) -> CIPSlabResult

Minimum two-way thickness. `ln` is the longer of the two panel spans and β
is longer over shorter (ACI 318-11 §9.5.3.3, corpus: aci-318-11, page 135).
Beams are sized after the slab, so αfm is not known here and the thickness
is the §9.5.3.3(a) bound. The planned analysis is recorded on
`slab.design_details`.
"""
function _size_slab!(::TwoWay, struc, slab, slab_idx;
                     options::AbstractFloorOptions = FlatPlateOptions(),
                     verbose::Bool = false,
                     kwargs...)
    sdl, live = _slab_service_pressures(struc, slab, slab_idx)
    topping = _slab_topping_span(slab)
    span = topping === nothing ? max(slab.spans.primary, slab.spans.secondary) : topping
    l2 = topping === nothing ? min(slab.spans.primary, slab.spans.secondary) :
         something(get(slab.design_details, :topping_l2, nothing), topping)
    verbose && @info "Sizing two-way slab $slab_idx" span = span l2 = l2
    position = hasproperty(slab, :position) ? slab.position : :edge
    result = _size_span_floor(TwoWay(), span, sdl, live;
                               material = _options_concrete(options), options = options,
                               l2 = l2, position = position)
    installed = _install_span_result!(struc, slab, result)
    dead = installed.self_weight + sdl
    method, reasons = assign_panel_analysis!(TwoWay(), struc, slab, dead, live)
    verbose && @info "Two-way analysis" method=typeof(method) reasons=reasons
    return installed
end

# =============================================================================
# Concrete: Vault (slab-based; 1 cell per slab enforced)
# =============================================================================

"""
    _size_slab!(::Vault, struc, slab, slab_idx; options, verbose) -> VaultResult

Size a vault slab using either analytical evaluation or optimization.

## Mode Selection (automatic)

**Analytical mode**: Both `rise`/`lambda` AND `thickness` are fixed in `VaultOptions`
**Optimization mode**: One or both variables use bounds (default)

## Defaults (optimization mode)
- `lambda_bounds = (10, 20)` → rise ∈ (span/20, span/10)
- `thickness_bounds = (2", 4")`

# See Also
- `VaultOptions` for configuration
- `optimize_vault` for standalone optimization API
"""
function _size_slab!(::Vault, struc, slab, slab_idx;
                     options::AbstractFloorOptions = VaultOptions(),
                     verbose::Bool = false,
                     kwargs...)
    # Validate: vault = 1 cell per slab
    length(slab.cell_indices) == 1 || throw(ArgumentError(
        "Vault slabs must have exactly one cell; got $(length(slab.cell_indices)) in slab $slab_idx."))
    
    cell_idx = only(slab.cell_indices)
    cell = struc.cells[cell_idx]
    vopt = options isa VaultOptions ? options : VaultOptions()

    # Extract geometry and loading
    span = slab.spans.primary
    sdl = cell.sdl
    live = cell.live_load
    
    # ─── Determine mode: analytical vs optimization ───
    has_fixed_rise = !isnothing(vopt.rise) || !isnothing(vopt.lambda)
    has_fixed_thickness = !isnothing(vopt.thickness)
    use_analytical = has_fixed_rise && has_fixed_thickness
    
    if use_analytical
        # ─── ANALYTICAL MODE ───
        verbose && @info "Sizing vault slab $slab_idx (analytical)" span=span
        
        result = _size_span_floor(Vault(), span, sdl, live;
            material = vopt.material,
            options = vopt,
        )
    else
        # ─── OPTIMIZATION MODE ───
        verbose && @info "Sizing vault slab $slab_idx (optimization)" span=span
        
        # Resolve rise: fixed value OR bounds (not both)
        # Priority: rise > lambda > rise_bounds > lambda_bounds (default)
        rise_kwarg = if !isnothing(vopt.rise)
            (; rise = vopt.rise)
        elseif !isnothing(vopt.lambda)
            (; lambda = vopt.lambda)
        elseif !isnothing(vopt.rise_bounds)
            (; rise_bounds = vopt.rise_bounds)
        else
            (; lambda_bounds = vopt.lambda_bounds)  # default
        end
        
        # Resolve thickness: fixed value OR bounds (not both)
        thickness_kwarg = if !isnothing(vopt.thickness)
            (; thickness = vopt.thickness)
        else
            (; thickness_bounds = vopt.thickness_bounds)  # default
        end
        
        opt_result = optimize_vault(
            span, sdl, live;
            rise_kwarg...,
            thickness_kwarg...,
            # Other params (all have defaults in VaultOptions)
            material = vopt.material,
            trib_depth = vopt.trib_depth,
            rib_depth = vopt.rib_depth,
            rib_apex_rise = vopt.rib_apex_rise,
            finishing_load = vopt.finishing_load,
            allowable_stress = vopt.allowable_stress,
            deflection_limit = vopt.deflection_limit,
            check_asymmetric = vopt.check_asymmetric,
            # Optimization params
            objective = vopt.objective,
            solver = vopt.solver,
            n_grid = vopt.n_grid,
            n_refine = vopt.n_refine,
            verbose = verbose,
        )
        
        result = opt_result.result
        
        if isnothing(result)
            @warn "Vault optimization failed for slab $slab_idx" status=opt_result.status
            return nothing
        end
        
        verbose && @info "Vault optimization complete" rise=opt_result.rise thickness=opt_result.thickness
    end

    # Update cell self-weight and slab result
    cell.self_weight = self_weight(result)
    slab.result = result

    return result
end
