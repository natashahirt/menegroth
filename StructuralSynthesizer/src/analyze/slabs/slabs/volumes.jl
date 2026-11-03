
"""Write group results back into `struc.slabs` and update cell self-weights."""
function _apply_slab_results!(struc, slab_specs, group_results, group_sw, group_spans, group_material,
                              primary_material, opts::StructuralSizer.AbstractFloorOptions)
    for spec in slab_specs
        gid = spec.group_id
        result = group_results[gid]
        sw_service = group_sw[gid]
        spans_gov = group_spans[gid]
        material_eff = get(group_material, gid, primary_material)

        # Propagate structural data to cells
        for c_idx in spec.cell_indices
            cell = struc.cells[c_idx]
            cell.self_weight = sw_service
            cell.floor_type = spec.floor_type
        end

        # Derive slab position from its cells (most exterior wins)
        slab_position = _derive_slab_position(struc, spec.cell_indices)

        # Compute floor area and material volumes
        floor_area = sum(struc.cells[i].area for i in spec.cell_indices)
        volumes = _compute_slab_volumes(result, floor_area, material_eff, opts)

        slab = Slab(spec.cell_indices, result, spans_gov; 
                    floor_type=spec.floor_type, position=slab_position, 
                    group_id=gid, volumes=volumes)
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
                              primary_material=nothing)
    for i in eachindex(struc.slabs)
        _update_one_slab_volume!(struc, i, options; primary_material)
    end
    return struc
end

"""Extract primary material from floor options for volume calculations."""
_primary_material(opts::StructuralSizer.FlatPlateOptions) = opts.material.concrete
_primary_material(opts::StructuralSizer.FlatSlabOptions)  = opts.base.material.concrete
_primary_material(opts::StructuralSizer.OneWayOptions)    = opts.material.concrete
_primary_material(opts::StructuralSizer.VaultOptions)     = opts.material
_primary_material(::StructuralSizer.AbstractFloorOptions) = StructuralSizer.NWC_4000

