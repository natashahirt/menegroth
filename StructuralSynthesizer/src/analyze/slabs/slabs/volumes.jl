
"""
Write group results back into `struc.slabs` and update cell self-weights.
`group_opts[gid]` are the options the group was sized with (override, or the
floor type's defaults), so volumes and topping bars use the same material.
"""
function _apply_slab_results!(struc, slab_specs, group_results, group_sw, group_spans, group_material,
                              group_opts; group_toppings = nothing)
    for spec in slab_specs
        gid = spec.group_id
        result = group_results[gid]
        sw_service = group_sw[gid]
        spans_gov = group_spans[gid]
        material_eff = group_material[gid]
        vol_opts = group_opts[gid]

        # Propagate structural data to cells
        for c_idx in spec.cell_indices
            cell = struc.cells[c_idx]
            cell.self_weight = sw_service
            cell.floor_type = spec.floor_type
        end

        # Derive slab position from its cells (most exterior wins)
        slab_position = _derive_slab_position(struc, spec.cell_indices)

        floor_area = sum(struc.cells[i].area for i in spec.cell_indices)
        volumes = _compute_slab_volumes(result, floor_area, material_eff, vol_opts)

        slab = Slab(spec.cell_indices, result, spans_gov; 
                    floor_type=spec.floor_type, position=slab_position, 
                    group_id=gid, volumes=volumes)
        topping = group_toppings === nothing ? nothing : get(group_toppings, gid, nothing)
        if topping !== nothing && spec.floor_type in (:one_way, :two_way)
            bar_opts = vol_opts isa StructuralSizer.OneWayOptions ||
                       vol_opts isa StructuralSizer.TwoWayOptions ? vol_opts :
                       StructuralSizer.OneWayOptions()
            bars_for(ln, n, inner) = n === nothing ? nothing : StructuralSizer.one_way_topping_bars(
                StructuralSizer.total_depth(result), ln,
                sw_service + spec.sdl_gov, spec.live_gov,
                bar_opts.material.concrete, bar_opts.material.rebar;
                n_spans = n, cover = bar_opts.cover, bar_size = bar_opts.bar_size,
                inner_layer = inner)
            # Both directions: each family of ribs has a slab spanning the other.
            # The primary direction is the outer layer. One-way joists leave
            # both `nothing` here; detailing designs them from the placed joists.
            details = (
                topping_span = topping.span, topping_l2 = topping.l2,
                topping_n = topping.n_spans, topping_n_l2 = topping.n_l2,
                topping_side = topping.side, topping_side_l2 = topping.side_l2,
                topping_cover = bar_opts.cover,
                topping_bars = bars_for(topping.span, topping.n_spans, false),
                topping_bars_l2 = bars_for(topping.l2, topping.n_l2, true),
            )
            existing = slab.design_details
            slab.design_details = existing isa NamedTuple ? merge(existing, details) : details
        end
        push!(struc.slabs, slab)
    end
end

"""Derive slab position from its cells (corner > edge > interior)."""
function _derive_slab_position(struc, cell_indices)
    positions = [struc.cells[i].position for i in cell_indices]
    # Priority: corner > edge > interior
    :corner in positions && return :corner
    :edge in positions && return :edge
    return :interior
end

"""Compute material volumes for a slab from its result and floor area."""
function _compute_slab_volumes(result::R, floor_area, primary_mat, opts::StructuralSizer.AbstractFloorOptions) where R<:AbstractFloorResult
    mat_map = StructuralSizer.result_materials(result, primary_mat, opts)
    
    # Compute volumes: material → total volume
    volumes = MaterialVolumes()
    for mat_sym in StructuralSizer.materials(result)
        mat = mat_map[mat_sym]
        vol_per_area = StructuralSizer.volume_per_area(result, mat_sym)
        volumes[mat] = vol_per_area * floor_area
    end
    return volumes
end

"""
    update_slab_volumes!(struc; options, primary_material=nothing)

Recompute material volumes for all slabs based on their current results.

Call this after `size_slabs!` to update the volumes with accurate material
quantities (including reinforcement) for EC calculations.

# Example
```julia
size_slabs!(struc; options=opts)
update_slab_volumes!(struc; options=opts)
ec = compute_building_ec(struc)
```
"""
function update_slab_volumes!(struc::BuildingStructure; 
                              options::StructuralSizer.AbstractFloorOptions=StructuralSizer.FlatPlateOptions(),
                              slab_options::Union{Nothing, AbstractVector}=nothing,
                              primary_material=nothing)
    for i in eachindex(struc.slabs)
        opts_i = slab_options === nothing ? options : slab_options[i]
        _update_one_slab_volume!(struc, i, opts_i; primary_material)
    end
    return struc
end

"""Extract primary material from floor options for volume calculations."""
_primary_material(opts::StructuralSizer.FlatPlateOptions) = opts.material.concrete
_primary_material(opts::StructuralSizer.FlatSlabOptions)  = opts.base.material.concrete
_primary_material(opts::StructuralSizer.OneWayOptions)    = opts.material.concrete
_primary_material(opts::StructuralSizer.TwoWayOptions)    = opts.material.concrete
_primary_material(opts::StructuralSizer.VaultOptions)     = opts.material
_primary_material(::StructuralSizer.AbstractFloorOptions) = StructuralSizer.NWC_4000

