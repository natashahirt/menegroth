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
)
    # ─── Validate: concrete slabs require concrete columns ───
    has_concrete_slab = any(s -> floor_type(s.floor_type) isa AbstractConcreteSlab, struc.slabs)
    if has_concrete_slab && !isnothing(column_opts) && !(column_opts isa ConcreteColumnOptions)
        throw(ArgumentError(
            "Concrete slab floor systems require ConcreteColumnOptions, " *
            "got $(typeof(column_opts)). Steel columns are not supported " *
            "with concrete slabs."
        ))
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
        for batch in batches
            tasks = map(batch) do slab_idx
                Threads.@spawn size_slab!(struc, slab_idx; options=options,
                    column_opts=column_opts, max_iterations=max_iterations,
                    verbose=verbose, _col_cache=_col_cache, fire_rating=fire_rating)
            end
            fetch.(tasks)
        end
    else
        for slab_idx in eachindex(struc.slabs)
            size_slab!(struc, slab_idx; options=options, column_opts=column_opts,
                       max_iterations=max_iterations, verbose=verbose,
                       _col_cache=_col_cache, fire_rating=fire_rating)
        end
    end
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
    size_slab!(struc, slab_idx; options, kwargs...) -> Any

Size/design a single slab in `struc` by index. Intended for debugging and scripting.
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
)
    slab = struc.slabs[slab_idx]
    ft = floor_type(slab.floor_type)
    return _size_slab!(ft, struc, slab, slab_idx;
                      options=options, column_opts=column_opts,
                      max_iterations=max_iterations, verbose=verbose,
                      _col_cache=_col_cache, fire_rating=fire_rating)
end

# =============================================================================
# Internal dispatch hook
# =============================================================================

"""Fallback `_size_slab!`: no-op for floor types without a sizing implementation."""
_size_slab!(::AbstractFloorSystem, struc, slab, slab_idx; verbose::Bool=false, kwargs...) = begin
    verbose && @debug "Skipping slab (no sizing implementation)" slab_idx floor_type=slab.floor_type
    return nothing
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
                     fire_rating::Real = 0.0)
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
                              fire_rating=fire_rating)
    
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
                     fire_rating::Real = 0.0)
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
                              fire_rating=fire_rating)
    
    # Handle non-convergence gracefully
    if hasproperty(result, :converged) && !result.converged
        @warn "Flat slab $slab_idx did not converge" check=result.failing_check iters=result.iterations h=result.h_final
        hasproperty(slab, :design_details) && (slab.design_details = result)
        return result
    end
    
    # Set slab.result and drop_panel geometry (may have been adjusted by pipeline)
    slab.result = result.slab_result
    slab.drop_panel = result.drop_panel
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
