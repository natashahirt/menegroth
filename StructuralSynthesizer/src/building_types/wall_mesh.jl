# =============================================================================
# Wall mesh identity
# =============================================================================
# A pier is one straight wall in one story. It owns the shell triangles meshed
# from that wall. An assembly is the piers on one story whose ends meet.
# The triangles are filled by `to_asap!`; until then `WallMesh()` is empty.

"""Shell triangles that belong to one wall pier."""
struct WallPierMesh
    "Index into `BuildingStructure.walls`."
    wall_index::Int
    shells::Vector{Asap.ShellTri3}
end

"""
Piers on one story that share corners.

`joined` is true when more than one pier meets. A joined assembly is recorded
so the cut can sum it. Designing it is refused until the ordinary-wall flange
width is taken from the code.
"""
struct WallAssembly
    "0-based story, matching `Wall.story`."
    story::Int
    "Indices into `BuildingStructure.walls`, sorted."
    wall_indices::Vector{Int}
    joined::Bool
end

"""
Pier triangles and story assemblies for the current `to_asap!` mesh.

Empty until `to_asap!` runs. Rebuilt on every `to_asap!`.
"""
struct WallMesh
    piers::Vector{WallPierMesh}
    assemblies::Vector{WallAssembly}
end

WallMesh() = WallMesh(WallPierMesh[], WallAssembly[])

"""
    WallMesh(shells_by_wall, assemblies) -> WallMesh

`shells_by_wall[i]` is the triangles of `walls[i]`. Every triangle is `:wall`
and appears in exactly one pier. Every wall index appears in exactly one assembly.
A pier with no triangles throws: a wall that was not meshed is not an empty demand.
"""
function WallMesh(shells_by_wall::Vector{<:AbstractVector{<:Asap.ShellTri3}},
                  assemblies::Vector{WallAssembly})
    seen = Set{UInt64}()
    piers = WallPierMesh[]
    for (i, shells) in enumerate(shells_by_wall)
        isempty(shells) && throw(ArgumentError(
            "WallMesh: wall $i has no shell triangles. A pier with no mesh " *
            "cannot be given a demand."))
        owned = Asap.ShellTri3[]
        for sh in shells
            sh.id === :wall || throw(ArgumentError(
                "WallMesh: wall $i owns a shell with id $(sh.id). Pier shells are :wall."))
            id = objectid(sh)
            id in seen && throw(ArgumentError(
                "WallMesh: one shell triangle is owned by two piers."))
            push!(seen, id)
            push!(owned, sh)
        end
        push!(piers, WallPierMesh(i, owned))
    end
    covered = Int[]
    for asm in assemblies
        append!(covered, asm.wall_indices)
    end
    sort!(covered)
    covered == collect(1:length(shells_by_wall)) || throw(ArgumentError(
        "WallMesh: assemblies cover wall indices $(covered), expected " *
        "1:$(length(shells_by_wall)). Each pier belongs to one assembly."))
    return WallMesh(piers, assemblies)
end
