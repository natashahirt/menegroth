# Top-level initialization for BuildingStructure

"""
    initialize!(struc; loads, material, floor_type, floor_opts, tributary_axis,
                cell_groupings, slab_group_ids, braced_by_slabs, wall_thickness)

Initialize all structural components of a BuildingStructure.

# Arguments
- `loads::GravityLoads`: Unfactored service loads for cells (default: `GravityLoads()`)
- `material`: Material for slab sizing and self-weight (default: NWC_4000)
- `floor_type`: Floor type (:auto, :one_way, :two_way, :flat_plate, :vault, etc.)
- `floor_opts`: Typed floor options (`AbstractFloorOptions` subtype, default: `FlatPlateOptions()`)
- `tributary_axis`: Override tributary area partitioning (default: `nothing` → auto)
- `cell_groupings`: How to group cells into slabs:
  - `:auto` (default): Use floor type options (e.g., FlatPlateOptions.grouping)
  - `:individual`: One slab per cell
  - `:by_floor`: Group all cells on each floor
  - `Vector{Vector{Int}}`: Explicit cell index groupings
- `slab_group_ids`: Optional per-cell slab design group ids
- `braced_by_slabs`: If true (default), beams supporting slabs get Lb=0
- `wall_thickness`: Pier thickness for skeleton `:walls` edges, already in the
  structure length type. Required when that group is non-empty; `nothing`
  (default) is valid only when there are no wall edges. [`DesignParameters`](@ref)
  has no wall thickness. `nothing` with a `:walls` group throws on purpose.
  There is no default thickness. Threaded into [`initialize_members!`](@ref).
  After members are built, [`assert_story_walls_enclosed!`](@ref) checks every
  story that has walls. That check is the existing axis-aligned plate box
  (`plate_center ± plan_halfwidth`). A wall center that sits in an L-notch
  inside the box — inside the bounding box, outside the floor polygon — is
  the pre-existing contract and is not rejected here. `Wall.story` is
  0-based; [`to_wall_line`](@ref) sets `WallLine.story = Wall.story + 1`.
"""
function initialize!(struc::BuildingStructure; 
                     loads::GravityLoads=GravityLoads(),
                     material::AbstractMaterial=NWC_4000,
                     floor_type::Symbol=:auto,
                     floor_opts::StructuralSizer.AbstractFloorOptions=StructuralSizer.FlatPlateOptions(),
                     scoped_floor_overrides::Vector{ScopedFloorOverride}=ScopedFloorOverride[],
                     tributary_axis=nothing,
                     col_I_factor::Real = 0.70,  # ACI 318-11 §10.10.4.1
                     cell_groupings::Union{Symbol, Vector{Vector{Int}}}=:auto,
                     slab_group_ids::Union{Nothing, AbstractVector}=nothing,
                     braced_by_slabs::Bool=true,
                     wall_thickness=nothing)
    skel = struc.skeleton
    
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    
    # Slabs: cells → slabs
    initialize_cells!(struc; loads=loads)
    initialize_slabs!(struc; material=material, floor_type=floor_type,
                      floor_opts=floor_opts, cell_groupings=cell_groupings,
                      slab_group_ids=slab_group_ids,
                      scoped_floor_overrides=scoped_floor_overrides,
                      col_I_factor=col_I_factor)
    
    # Framing: segments → members
    initialize_segments!(struc)
    update_bracing!(struc; braced_by_slabs=braced_by_slabs)
    initialize_members!(struc; wall_thickness=wall_thickness)
    
    # Compute slab coloring for concurrent sizing
    compute_slab_parallel_batches!(struc)

    # Plate enclosure for every story that has walls. No-op when walls is empty.
    # The check is the existing axis-aligned plate box. A center in an L-notch
    # inside that box is the pre-existing contract (bbox, not the floor polygon).
    assert_story_walls_enclosed!(struc)
    
    @debug "Initialized BuildingStructure" cells=length(struc.cells) slabs=length(struc.slabs) segments=length(struc.segments) beams=length(struc.beams) columns=length(struc.columns) struts=length(struc.struts) walls=length(struc.walls) slab_batches=length(struc.slab_parallel_batches)
    return struc
end
