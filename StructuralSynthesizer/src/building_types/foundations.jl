# =============================================================================
# Supports and Foundations
# =============================================================================

"""
Per-support analysis data (one support node location).

Column dimensions (`c1`, `c2`, `shape`) are carried here so that
`support_demands` can propagate them directly onto `FoundationDemand`.
"""
mutable struct Support{T, F, M, L}
    vertex_idx::Int             # Index into skeleton.vertices
    node_idx::Int               # Index into asap_model.nodes  
    forces::NTuple{3, F}        # (Fx, Fy, Fz) reaction forces
    moments::NTuple{3, M}       # (Mx, My, Mz) reaction moments
    foundation_type::Symbol     # :spread, :combined, :pile, etc.
    c1::L                       # Column dim 1 (or diameter for :circular)
    c2::L                       # Column dim 2 (= c1 for circular)
    shape::Symbol               # :rectangular or :circular
end

"""
    Support(vertex_idx, node_idx; forces, moments, foundation_type, c1, c2, shape) -> Support

Keyword constructor with sensible defaults (zero reactions, 18″ square column, spread footing).
"""
function Support(vertex_idx::Int, node_idx::Int; 
                 forces=(0.0u"kN", 0.0u"kN", 0.0u"kN"),
                 moments=(0.0u"kN*m", 0.0u"kN*m", 0.0u"kN*m"),
                 foundation_type=:spread,
                 c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
    F = typeof(forces[1])
    M = typeof(moments[1])
    L = typeof(c1)
    Support{typeof(1.0u"m"), F, M, L}(
        vertex_idx, node_idx, forces, moments, foundation_type,
        c1, c2, shape)
end

"""Return the full 6-DOF reaction tuple `(Fx, Fy, Fz, Mx, My, Mz)` for a support."""
function reactions(s::Support)
    return (s.forces..., s.moments...)
end

"""Physical foundation element (one or more supports share a foundation)."""
mutable struct Foundation{T, R<:AbstractFoundationResult}
    support_indices::Vector{Int}  # Indices into struc.supports
    wall_indices::Vector{Int}     # Grade walls on this footing. Empty for a column footing.
    result::R
    foundation_type::Symbol
    group_id::Union{UInt64, Nothing}
    volumes::MaterialVolumes  # concrete + rebar materials → volumes
end

"""
    Foundation(support_indices, result; foundation_type, group_id, volumes) -> Foundation

Construct a `Foundation` linking one or more supports to a sizing result.
"""
function Foundation(support_indices::Vector{Int}, result::R;
                    foundation_type=:spread, group_id=nothing,
                    volumes::MaterialVolumes=MaterialVolumes(),
                    wall_indices::Vector{Int}=Int[]) where {R<:AbstractFoundationResult}
    T = typeof(result.B)
    Foundation{T, R}(support_indices, wall_indices, result, foundation_type, group_id, volumes)
end

"""Single-support foundation convenience: wraps the index in a vector."""
Foundation(support_idx::Int, result::R; kwargs...) where {R<:AbstractFoundationResult} = 
    Foundation([support_idx], result; kwargs...)

"""Concrete volume of the foundation (delegates to the sizing result)."""
concrete_volume(f::Foundation) = StructuralSizer.concrete_volume(f.result)

"""Steel volume of the foundation (delegates to the sizing result)."""
steel_volume(f::Foundation) = StructuralSizer.steel_volume(f.result)

"""Optimization grouping for similar foundations (pure grouping logic)."""
mutable struct FoundationGroup
    hash::UInt64
    foundation_indices::Vector{Int}
end

"""Create an empty `FoundationGroup` with the given hash key."""
FoundationGroup(hash::UInt64) = FoundationGroup(hash, Int[])
