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
    size_slabs!(struc; options=FloorOptions(), column_opts=nothing, max_iterations=10, verbose=false) -> struc

Size/design all slabs in `struc` using the floor type stored on each slab.

- Uses the **type system** via `floor_type(slab.floor_type)` for dispatch.
- Uses **`FloorOptions`** as the single public configuration surface.
"""
function size_slabs!(
    struc;
    options::FloorOptions = FloorOptions(),
    column_opts = nothing,
    max_iterations::Int = 10,
    verbose::Bool = false,
)
    for slab_idx in eachindex(struc.slabs)
        size_slab!(struc, slab_idx; options=options, column_opts=column_opts,
                   max_iterations=max_iterations, verbose=verbose)
    end
    return struc
end

"""
    size_slab!(struc, slab_idx; options=FloorOptions(), kwargs...) -> Any

Size/design a single slab in `struc` by index. Intended for debugging and scripting.
"""
function size_slab!(
    struc,
    slab_idx::Int;
    options::FloorOptions = FloorOptions(),
    column_opts = nothing,
    max_iterations::Int = 10,
    verbose::Bool = false,
)
    slab = struc.slabs[slab_idx]
    ft = floor_type(slab.floor_type)
    return _size_slab!(ft, struc, slab, slab_idx;
                      options=options, column_opts=column_opts,
                      max_iterations=max_iterations, verbose=verbose)
end

# =============================================================================
# Internal dispatch hook
# =============================================================================

_size_slab!(::AbstractFloorSystem, struc, slab, slab_idx; verbose::Bool=false, kwargs...) = begin
    verbose && @debug "Skipping slab (no sizing implementation)" slab_idx floor_type=slab.floor_type
    return nothing
end

# =============================================================================
# Concrete: Flat plate (full design pipeline)
# =============================================================================

function _analysis_method_from_options(opts::FlatPlateOptions)::FlatPlateAnalysisMethod
    if opts.analysis_method == :ddm
        return DDM()
    elseif opts.analysis_method == :mddm
        return DDM(:simplified)
    elseif opts.analysis_method == :efm
        return EFM()
    else
        throw(ArgumentError("Unknown FlatPlateOptions.analysis_method=$(opts.analysis_method). Expected :ddm, :mddm, or :efm."))
    end
end

function _size_slab!(::FlatPlate, struc, slab, slab_idx;
                     options::FloorOptions = FloorOptions(),
                     column_opts = nothing,
                     max_iterations::Int = 10,
                     verbose::Bool = false)
    # Default column options for concrete flat plates
    col_opts = isnothing(column_opts) ? ConcreteColumnOptions() : column_opts
    method = _analysis_method_from_options(options.flat_plate)

    verbose && @info "Sizing flat plate slab $slab_idx" cells=length(slab.cell_indices) method=typeof(method)

    # Full flat plate design pipeline (updates cell self-weight internally)
    result = size_flat_plate!(struc, slab, col_opts;
                              method=method,
                              opts=options.flat_plate,
                              max_iterations=max_iterations,
                              verbose=verbose)
    
    # Set slab.result to the FlatPlatePanelResult (like Vault does)
    slab.result = result.slab_result
    
    return result
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
                     options::FloorOptions = FloorOptions(),
                     verbose::Bool = false,
                     kwargs...)
    # Validate: vault = 1 cell per slab
    length(slab.cell_indices) == 1 || throw(ArgumentError(
        "Vault slabs must have exactly one cell; got $(length(slab.cell_indices)) in slab $slab_idx."))
    
    cell_idx = only(slab.cell_indices)
    cell = struc.cells[cell_idx]
    vopt = options.vault

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
            options = options,
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
