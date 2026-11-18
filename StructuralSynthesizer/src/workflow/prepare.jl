# =============================================================================
# Main Entry Point
# =============================================================================

"""
`true` when a composite-deck bay is longer than the profile's longest
published single-span unshored length. The deck then needs fill beams.

Floor cells still carry `floor_type == :unknown` here: `initialize!` has
built their spans, and the slab type is applied later. Grade is the only
cell that is not a deck bay.
"""
function _deck_bay_needs_fill_beams(struc, floor_type, floor_opts)
    floor_type === :composite_deck || return false
    floor_opts isa StructuralSizer.CompositeDeckOptions || return false
    limit = StructuralSizer.max_unshored_simple_span(floor_opts.deck_profile)
    for cell in struc.cells
        cell.floor_type === :grade && continue
        cell.spans.primary > limit && return true
    end
    return false
end

"""Framing options that place steel fill beams at the schema's joist spacing."""
function _with_deck_fill_beams(opts::NamedTuple, params)
    steel = params.materials.steel
    steel isa StructuralSizer.StructuralSteel || (steel = StructuralSizer.A992_Steel)
    mats = get(opts, :materials, NamedTuple())
    mats isa NamedTuple || (mats = NamedTuple())
    return merge(opts, (materials = merge(mats, (steel = steel,)),))
end

"""Center-to-center rib spacing the top slab spans, or `nothing`."""
function _rib_topping_center(opts::NamedTuple)
    raw = if haskey(opts, :module_spacing)
        opts.module_spacing
    elseif haskey(opts, :spacing)
        opts.spacing
    else
        return nothing
    end
    vals = raw isa Union{Tuple, AbstractVector} ? raw : (raw,)
    isempty(vals) && return nothing
    return maximum(v -> v isa Unitful.Length ? v : v * u"m", vals)
end

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
    # A module grid that cannot be a waffle becomes one-way joists before the
    # floor type and the rib layout are read. ACI 318-11 §8.13.4.
    opts = isempty(framing_opts) ? params.framing_opts : framing_opts
    opts, _ = _qualify_module_framing(opts, params)
    floor_opts = resolve_floor_options(params)
    floor_type = _infer_floor_type(floor_opts)
    # Resolve framing before the support check. Joists are materialized
    # after `initialize!`, so a ribbed floor has to be told they are coming.
    plan = _rib_layout_opts(opts)
    grillage_planned = plan.grillage
    # Rib bay counts set the topping span of a `:bays` grillage.
    rib_bays = plan.layout === :bays ? (Int(opts.n_xi), Int(opts.n_eta)) : nothing
    joists_planned = floor_type in (:one_way, :two_way) &&
        (haskey(opts, :spacing) || haskey(opts, :beam_options) || grillage_planned)
    # A waffle's top slab spans the rib module, not the beam bay.
    # `spacing` is a tributary joist; `module_spacing` is a grillage.
    topping_span = joists_planned ? _rib_topping_center(opts) : nothing

    # A drawn slab edge becomes centerlines once. Column resizing then moves
    # the slab border, not the grid.
    params.geometry_is_centerline || apply_facade_setback!(struc)

    initialize!(struc; loads=params.loads, floor_type=floor_type,
                material=_primary_material(floor_opts),
                floor_opts=floor_opts,
                scoped_floor_overrides=params.scoped_floor_overrides,
                # ACI 318-11 §10.10.4.1 — scoped-override cells inherit the global column cracking factor
                col_I_factor = params.column_I_factor,
                tributary_axis=params.tributary_axis,
                plan_axis=isnothing(params.lateral) ? (1.0, 0.0) : params.lateral.plan_axis,
                wall_thickness=params.wall_thickness,
                topping_span=topping_span,
                rib_bays=rib_bays,
                joists_planned=joists_planned)

    # A composite deck spans between beams. When the bay is longer than the
    # profile's published single-span unshored length, the girders are too
    # far apart, so fill beams are added at the steel-joist spacing.
    if _deck_bay_needs_fill_beams(struc, floor_type, floor_opts) &&
            _resolve_level_material(opts, :steel, :beam) === nothing
        opts = _with_deck_fill_beams(opts, params)
    end

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
    populate_levels!(struc; opts=opts)
    # Joists exist now, so a deck they cross is spanned at their spacing.
    _record_deck_spans!(struc)
    if joists_planned && !any(b -> b isa Beam && is_joist(b), struc.beams)
        throw(ArgumentError(
            "framing options asked for joists, but none were created. " *
            "A one-way or two-way floor cannot treat missing ribs as supports."))
    end

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
    empty!(struc.stage_diagnostics)
    empty!(struc.frame_section_floors)
    if params.lateral !== nothing
        prepare_lateral_model!(struc, params.lateral)
    end

    to_asap!(struc; params=params)
    
    snapshot!(struc)
    return struc
end
