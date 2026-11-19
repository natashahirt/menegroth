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
- `plan_axis`: First plan axis of the building (default `(1.0, 0.0)`, global X).
  Cell short spans are auto-detected along it and its perpendicular. Pass
  `params.lateral.plan_axis` so the floors span on the axes the lateral stage uses.
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
  story that has walls. A wall center must lie on that story's floor faces.
  The axis-aligned plate box is still what drift uses; it is not this check.
  `Wall.story` is 0-based; [`to_wall_line`](@ref) sets `WallLine.story = Wall.story + 1`.
- `park_wall_overlaps`: when `true` (default), columns and beams that lie inside
  a wall move to `:absent` before members are built
  ([`park_wall_overlaps!`](@ref)). `false` keeps them as members.
"""
function initialize!(struc::BuildingStructure; 
                     loads::GravityLoads=GravityLoads(),
                     material::AbstractMaterial=NWC_4000,
                     floor_type::Symbol=:auto,
                     floor_opts::StructuralSizer.AbstractFloorOptions=StructuralSizer.FlatPlateOptions(),
                     scoped_floor_overrides::Vector{ScopedFloorOverride}=ScopedFloorOverride[],
                     tributary_axis=nothing,
                     plan_axis::NTuple{2, <:Real}=(1.0, 0.0),
                     col_I_factor::Real = 0.70,  # ACI 318-11 §10.10.4.1
                     cell_groupings::Union{Symbol, Vector{Vector{Int}}}=:auto,
                     slab_group_ids::Union{Nothing, AbstractVector}=nothing,
                     braced_by_slabs::Bool=true,
                     wall_thickness=nothing,
                     topping_span=nothing,
                     rib_bays=nothing,
                     joists_planned::Bool=false,
                     park_wall_overlaps::Bool=true)
    skel = struc.skeleton
    
    find_faces!(skel)
    # Beam-supported floors get trimmers and headers before cells are cut,
    # because the new beams change the faces. Flat plate, flat slab, waffle,
    # and vault openings are left unframed.
    frame_slab_openings!(skel; floor_type=floor_type, plan_axis=plan_axis,
                         tributary_axis=tributary_axis, joists_planned=joists_planned)
    rebuild_geometry_cache!(skel)
    # A column or beam inside a wall is the wall's. It leaves its group for
    # :absent before cells, tributaries, and members are built.
    park_wall_overlaps && park_wall_overlaps!(skel)
    
    # Slabs: cells → slabs
    initialize_cells!(struc; loads=loads, plan_axis=plan_axis)
    initialize_slabs!(struc; material=material, floor_type=floor_type,
                      floor_opts=floor_opts, tributary_axis=tributary_axis,
                      cell_groupings=cell_groupings,
                      slab_group_ids=slab_group_ids,
                      scoped_floor_overrides=scoped_floor_overrides,
                      col_I_factor=col_I_factor,
                      topping_span=topping_span,
                      rib_bays=rib_bays,
                      joists_planned=joists_planned)
    
    # Framing: segments → members
    initialize_segments!(struc)
    update_bracing!(struc; braced_by_slabs=braced_by_slabs)
    initialize_members!(struc; wall_thickness=wall_thickness, plan_axis=plan_axis)
    assert_one_way_slabs_supported(struc; joists_planned=joists_planned)
    
    # Compute slab coloring for concurrent sizing
    compute_slab_parallel_batches!(struc)

    # Every wall center on its story's floor faces. No-op when walls is empty.
    assert_story_walls_enclosed!(struc)
    
    @debug "Initialized BuildingStructure" cells=length(struc.cells) slabs=length(struc.slabs) segments=length(struc.segments) beams=length(struc.beams) columns=length(struc.columns) struts=length(struc.struts) walls=length(struc.walls) slab_batches=length(struc.slab_parallel_batches)
    return struc
end

"""
    assert_one_way_slabs_supported(struc)

Throw `ArgumentError` when a `:one_way` slab has a cell with no `:beams` or
`:walls` edge on its boundary. A one-way slab spans between line supports;
on columns alone it is a two-way (flat plate) system, so the input is invalid.
"""
function assert_one_way_slabs_supported(struc::BuildingStructure; joists_planned::Bool=false)
    # Ribs are added after this check. A planned joist spacing is the support.
    joists_planned && return nothing
    skel = struc.skeleton
    support_edges = union(Set(get(skel.groups_edges, :beams, Int[])),
                          Set(get(skel.groups_edges, :walls, Int[])))
    unsupported = Int[]
    for slab in struc.slabs
        slab.floor_type === :one_way || continue
        for cell_idx in slab.cell_indices
            face_idx = struc.cells[cell_idx].face_idx
            any(in(support_edges), skel.face_edge_indices[face_idx]) || push!(unsupported, face_idx)
        end
    end
    isempty(unsupported) && return nothing
    throw(ArgumentError(
        "floor_type :one_way needs beams or walls to span between, but face(s) " *
        "$(sort!(unique!(unsupported))) have no :beams or :walls edge. Add beams, " *
        "or use :flat_plate / :flat_slab for column-only supports."))
end
