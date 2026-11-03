# =============================================================================
# Main Entry Point
# =============================================================================

"""
    prepare!(struc::BuildingStructure, params::DesignParameters;
             framing_opts::NamedTuple = NamedTuple()) -> struc

Initialize a structure for design: set up cells, slabs, members, estimate
column sizes, build the Asap analysis model, and snapshot the pristine state.

This is the geometry-only step — no member sizing. Call `design_building` or
run pipeline stages individually after `prepare!`.

# Framing options (`framing_opts`)
Drives framing auto-generation above each slab via [`populate_levels!`](@ref)
(plan `joists-roles-materials`, Phase 5). The explicit `framing_opts` kwarg wins
when non-empty; otherwise the value falls back to `params.framing_opts` (so the
REST API / `DesignParameters` can carry framing through a single design call).
Empty by default, which is a strict no-op for the standard flat-plate /
flat-slab / beam-supported flows. Recognized keys (all optional):
- `framing_opts.materials`: `NamedTuple` of member materials by key
  (`:steel`, `:timber`, `:concrete`, `:beam`).
- `framing_opts.spacing`: center-to-center joist spacing for the opts-schema slab
  types.
- `framing_opts.level_N`: `NamedTuple` schema for framing level `N ≥ 2`.

See [`populate_levels!`](@ref) for the full contract.

# Example
```julia
prepare!(struc, params)
size_slabs!(struc, params)          # just slabs
snapshot!(struc, :post_slab)        # save intermediate state

# Try different column options on the same slab result
for col_opts in [ConcreteColumnOptions(), ConcreteColumnOptions(material = NWC_6000)]
    restore!(struc, :post_slab)
    size_columns!(struc, col_opts)
end
```
"""
function prepare!(struc::BuildingStructure, params::DesignParameters;
                  framing_opts::NamedTuple = NamedTuple())
    floor_opts = resolve_floor_options(params)
    floor_type = _infer_floor_type(floor_opts)
    
    initialize!(struc; loads=params.loads, floor_type=floor_type,
                floor_opts=floor_opts,
                scoped_floor_overrides=params.scoped_floor_overrides,
                # ACI 318-11 §10.10.4.1 — scoped-override cells inherit the global column cracking factor
                col_I_factor = params.column_I_factor,
                tributary_axis=params.tributary_axis,
                plan_axis=isnothing(params.lateral) ? (1.0, 0.0) : params.lateral.plan_axis,
                wall_thickness=params.wall_thickness)

    # Auto-generate the framing hierarchy above each slab (plan
    # `joists-roles-materials`, Phase 5). Runs immediately after
    # `initialize_members!` (invoked inside `initialize!`) and before
    # `to_asap!`, so any generated joists/secondary members are already present
    # when the analysis model is built.
    #
    # Options resolve with the explicit `framing_opts` kwarg taking precedence
    # (when non-empty) over `params.framing_opts`. The kwarg preserves every
    # existing caller; the `params` field lets the REST API / `DesignParameters`
    # carry framing through a single `design_building(struc, params)` call
    # (`routes.jl` passes no kwarg). An empty result stays a strict no-op for
    # flat-plate/flat-slab/beam-supported systems.
    opts = isempty(framing_opts) ? params.framing_opts : framing_opts
    populate_levels!(struc; opts=opts)

    fc = _get_design_fc(params)
    fp_opts = floor_opts isa StructuralSizer.FlatSlabOptions ? floor_opts.base : floor_opts
    col_cap = hasproperty(fp_opts, :max_column_size) ? fp_opts.max_column_size : nothing
    # The floor's span/15 switch also sets the starting estimate, so the two agree.
    col_start = hasproperty(fp_opts, :column_span_minimum) && !fp_opts.column_span_minimum ?
        :axial : :span
    estimate_column_sizes!(struc; fc=fc, input_is_centerline=params.geometry_is_centerline,
                           start=col_start, max_size=col_cap)

    # Set column shape for flat plate/slab when RC circular (punching, stiffness, output)
    if floor_type in (:flat_plate, :flat_slab)
        col_opts = params.columns
        if col_opts isa ConcreteColumnOptions && col_opts.section_shape == :circular
            for col in struc.columns
                col.shape = :circular
            end
        end
    end

    # Walls as the seismic system are validated before the model is built.
    # Releases stay on the material defaults. A gravity-only building skips this.
    struc.ordinary_wall_result = nothing
    if params.lateral !== nothing
        prepare_lateral_model!(struc, params.lateral)
    end

    to_asap!(struc; params=params)
    
    snapshot!(struc)
    return struc
end
