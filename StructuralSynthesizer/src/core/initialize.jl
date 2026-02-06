# Top-level initialization for BuildingStructure

"""
    initialize!(struc; material, floor_type, floor_kwargs, cell_groupings, slab_group_ids, braced_by_slabs)

Initialize all structural components of a BuildingStructure.

# Arguments
- `material`: Material for slab sizing and self-weight (default: NWC_4000)
- `floor_type`: Floor type (:auto, :one_way, :two_way, :flat_plate, :pt_banded, :vault, etc.)
- `floor_kwargs`: Extra kwargs forwarded to StructuralSizer's internal span-based sizing helper (e.g. `(lambda=10.0,)` for vaults)
- `cell_groupings`: How to group cells into slabs:
  - `:auto` (default): Use floor type options (e.g., FlatPlateOptions.grouping)
  - `:individual`: One slab per cell
  - `:by_floor`: Group all cells on each floor
  - `Vector{Vector{Int}}`: Explicit cell index groupings
- `slab_group_ids`: Optional per-cell slab design group ids; cells/slabs with the same id are sized together (enveloped)
- `braced_by_slabs`: If true (default), beams supporting slabs get Lb=0 (top flange braced)
"""
function initialize!(struc::BuildingStructure; 
                     material::AbstractMaterial=NWC_4000,
                     floor_type::Symbol=:auto,
                     floor_kwargs::NamedTuple=NamedTuple(),
                     cell_groupings::Union{Symbol, Vector{Vector{Int}}}=:auto,
                     slab_group_ids::Union{Nothing, AbstractVector}=nothing,
                     braced_by_slabs::Bool=true)
    skel = struc.skeleton
    
    find_faces!(skel)
    # Slabs: cells → slabs (material only needed for slabs)
    initialize_cells!(struc)
    initialize_slabs!(struc; material=material, floor_type=floor_type, floor_kwargs=floor_kwargs, cell_groupings=cell_groupings, slab_group_ids=slab_group_ids)
    
    # Framing: segments → members
    # 1. Initialize segments with Lb=L (conservative default)
    initialize_segments!(struc)
    # 2. Update Lb for slab-supported beams (Lb=0 if top flange braced)
    update_bracing!(struc; braced_by_slabs=braced_by_slabs)
    # 3. Create members from segments (uses updated Lb values)
    initialize_members!(struc)
    
    n_members = length(struc.beams) + length(struc.columns) + length(struc.struts)
    @debug "Initialized BuildingStructure" cells=length(struc.cells) slabs=length(struc.slabs) segments=length(struc.segments) beams=length(struc.beams) columns=length(struc.columns) struts=length(struc.struts)
    return struc
end
