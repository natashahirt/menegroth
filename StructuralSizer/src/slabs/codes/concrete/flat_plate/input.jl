const FlatPlateLength = typeof(1.0u"m")
const FlatPlateArea = typeof(1.0u"m^2")
const FlatPlatePressure = typeof(1.0u"kPa")

"""Normalized span geometry for a floor-design kernel."""
struct FlatPlateSpanInput
    primary::FlatPlateLength
    secondary::FlatPlateLength
    axis::NTuple{2, Float64}
    isotropic::FlatPlateLength
end

"""Normalized geometry and topology required by DDM, EFM, and slab FEA."""
struct FlatPlateTopologyInput{F}
    vertex_coords::Matrix{Float64}
    face_vertex_indices::Vector{Vector{Int}}
    face_edge_indices::Vector{Vector{Int}}
    edge_indices::Vector{Tuple{Int, Int}}
    faces::Vector{F}
end

"""Read-only geometry wrapper matching the kernel's coordinate interface."""
struct FlatPlateCoordinateInput
    vertex_coords::Matrix{Float64}
end

"""Internal topology view used by the existing numerical routines."""
struct FlatPlateTopologyState{F}
    geometry::FlatPlateCoordinateInput
    face_vertex_indices::Vector{Vector{Int}}
    face_edge_indices::Vector{Vector{Int}}
    edge_indices::Vector{Tuple{Int, Int}}
    faces::Vector{F}
end

"""Normalized cell declaration consumed by flat-plate design."""
struct FlatPlateCellInput
    face_idx::Int
    position::Symbol
    area::FlatPlateArea
    sdl::FlatPlatePressure
    live_load::FlatPlatePressure
    self_weight::FlatPlatePressure
    spans::FlatPlateSpanInput
end

"""Private mutable cell state; never crosses the package boundary."""
mutable struct FlatPlateCellState
    face_idx::Int
    position::Symbol
    area::FlatPlateArea
    sdl::FlatPlatePressure
    live_load::FlatPlatePressure
    self_weight::FlatPlatePressure
    spans::FlatPlateSpanInput
end

"""
    FlatPlateFloorInput

Normalized floor declaration, including neighboring floors needed by DDM.

`wall_segments` are the plan lines, in metres, of walls that meet this floor.
The design kernel has no wall objects and no stories, so these segments are
resolved on the building and carried in. Empty means the floor has no
wall support.
"""
struct FlatPlateFloorInput
    cell_indices::Vector{Int}
    spans::FlatPlateSpanInput
    floor_type::Symbol
    result::Union{Nothing, AbstractFloorResult}
    drop_panel::Union{Nothing, DropPanelGeometry}
    wall_segments::Vector{Tuple{NTuple{2,Float64},NTuple{2,Float64}}}
end

function FlatPlateFloorInput(
    cell_indices, spans, floor_type, result, drop_panel,
)
    FlatPlateFloorInput(
        cell_indices, spans, floor_type, result, drop_panel,
        Tuple{NTuple{2,Float64},NTuple{2,Float64}}[],
    )
end

"""Read-only support above the design joint for EFM stiffness distribution."""
struct FlatPlateAboveSupportInput
    c1::Union{Nothing, FlatPlateLength}
    c2::Union{Nothing, FlatPlateLength}
    shape::Symbol
    θ::Float64
    length::FlatPlateLength
    concrete::Union{Nothing, Concrete}
end

"""Private mutable support base used by the iterative design kernel."""
mutable struct FlatPlateSupportBaseState
    L::FlatPlateLength
    section::Union{Nothing, AbstractSection}
end

"""Private upper-support state used by the numerical kernel."""
struct FlatPlateAboveSupportState
    c1::Union{Nothing, FlatPlateLength}
    c2::Union{Nothing, FlatPlateLength}
    shape::Symbol
    θ::Float64
    base::FlatPlateSupportBaseState
    concrete::Union{Nothing, Concrete}
end

"""Normalized immutable support declaration."""
struct FlatPlateSupportInput
    source_index::Int
    vertex_idx::Int
    c1::Union{Nothing, FlatPlateLength}
    c2::Union{Nothing, FlatPlateLength}
    shape::Symbol
    θ::Float64
    story::Int
    position::Symbol
    corner_kind::Symbol
    corner_angle::Float64
    boundary_edge_dirs::Vector{NTuple{2, Float64}}
    boundary_inward_normals::Vector{NTuple{2, Float64}}
    structural_offset::NTuple{2, Float64}
    length::FlatPlateLength
    section::Union{Nothing, AbstractSection}
    concrete::Union{Nothing, Concrete}
    tributary_cell_indices::Set{Int}
    tributary_cell_areas::Dict{Int, Float64}
    column_above::Union{Nothing, FlatPlateAboveSupportInput}
end

"""Private mutable support state; all iterative growth is confined here."""
mutable struct FlatPlateSupportState
    source_index::Int
    base::FlatPlateSupportBaseState
    vertex_idx::Int
    c1::Union{Nothing, FlatPlateLength}
    c2::Union{Nothing, FlatPlateLength}
    shape::Symbol
    θ::Float64
    concrete::Union{Nothing, Concrete}
    story::Int
    position::Symbol
    corner_kind::Symbol
    corner_angle::Float64
    boundary_edge_dirs::Vector{NTuple{2, Float64}}
    boundary_inward_normals::Vector{NTuple{2, Float64}}
    structural_offset::NTuple{2, Float64}
    tributary_cell_indices::Set{Int}
    tributary_cell_areas::Dict{Int, Float64}
    column_above::Union{Nothing, FlatPlateAboveSupportState}
end

"""
    FlatPlateDesignInput

Complete immutable numerical input for one flat-plate or flat-slab design.

All quantities use coherent SI units. The input contains no Synthesizer object,
Asap building model, live cache, or mutable declaration.
"""
struct FlatPlateDesignInput{F}
    floor_index::Int
    topology::FlatPlateTopologyInput{F}
    cells::Vector{FlatPlateCellInput}
    floors::Vector{FlatPlateFloorInput}
    supports::Vector{FlatPlateSupportInput}
end

"""Private numerical workspace assembled from a normalized input."""
mutable struct FlatPlateKernelState{F}
    skeleton::FlatPlateTopologyState{F}
    cells::Vector{FlatPlateCellState}
    slabs::Vector{FlatPlateFloorInput}
    columns::Vector{FlatPlateSupportState}
    _analysis_caches::Dict{Int, Dict{Symbol, Any}}
end

function FlatPlateKernelState(input::FlatPlateDesignInput{F}) where {F}
    topology = input.topology
    skeleton = FlatPlateTopologyState(
        FlatPlateCoordinateInput(copy(topology.vertex_coords)),
        [copy(indices) for indices in topology.face_vertex_indices],
        [copy(indices) for indices in topology.face_edge_indices],
        copy(topology.edge_indices),
        deepcopy(topology.faces),
    )
    cells = FlatPlateCellState[
        FlatPlateCellState(
            cell.face_idx,
            cell.position,
            cell.area,
            cell.sdl,
            cell.live_load,
            cell.self_weight,
            cell.spans,
        )
        for cell in input.cells
    ]
    columns = FlatPlateSupportState[
        FlatPlateSupportState(
            support.source_index,
            FlatPlateSupportBaseState(support.length, deepcopy(support.section)),
            support.vertex_idx,
            support.c1,
            support.c2,
            support.shape,
            support.θ,
            support.concrete,
            support.story,
            support.position,
            support.corner_kind,
            support.corner_angle,
            copy(support.boundary_edge_dirs),
            copy(support.boundary_inward_normals),
            support.structural_offset,
            copy(support.tributary_cell_indices),
            copy(support.tributary_cell_areas),
            isnothing(support.column_above) ? nothing : FlatPlateAboveSupportState(
                support.column_above.c1,
                support.column_above.c2,
                support.column_above.shape,
                support.column_above.θ,
                FlatPlateSupportBaseState(support.column_above.length, nothing),
                support.column_above.concrete,
            ),
        )
        for support in input.supports
    ]
    return FlatPlateKernelState(
        skeleton,
        cells,
        FlatPlateFloorInput[
            FlatPlateFloorInput(
                copy(floor.cell_indices),
                floor.spans,
                floor.floor_type,
                deepcopy(floor.result),
                deepcopy(floor.drop_panel),
                copy(floor.wall_segments),
            )
            for floor in input.floors
        ],
        columns,
        Dict{Int, Dict{Symbol, Any}}(),
    )
end
