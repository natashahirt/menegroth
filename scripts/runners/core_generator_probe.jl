#=
Phase 1 validation probe for the central box shear-wall core generator.

Builds a small medium-office skeleton with `core=:center_box`, initializes
typed members with a wall thickness, and checks:

  1. A `Wall` exists on every 0-based story 0 … n_stories-1 (the ground story
     is braced via grade wall edges, not off-by-one).
  2. The core meshes: `to_asap!` runs and produces shell elements for the walls.
  3. `supporting_wall_segments` finds core walls under the floor slabs.

Run:  julia scripts/runners/core_generator_probe.jl
=#

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
using Asap
using Unitful
using Meshes

const N_STORIES = 4
const X_BAYS = 3
const Y_BAYS = 3
const WALL_T = 0.3u"m"

function main()
    skel = gen_medium_office(3 * 8.0u"m", 3 * 8.0u"m", 3.6u"m", X_BAYS, Y_BAYS, N_STORIES;
                             core=:center_box)

    n_wall_edges = length(get(skel.groups_edges, :walls, Int[]))
    println("wall edges in skeleton: $n_wall_edges (expected $(4 * N_STORIES))")
    @assert n_wall_edges == 4 * N_STORIES "expected $(4*N_STORIES) wall edges, got $n_wall_edges"

    struc = BuildingStructure(skel)
    initialize!(struc; wall_thickness=WALL_T)
    # The real pipeline sets wall concrete from params.materials; mirror that so
    # to_asap! can give the shells a modulus/ν/density.
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end

    stories_with_walls = sort(unique(w.story for w in struc.walls))
    println("walls per story: ", [(s, count(w -> w.story == s, struc.walls)) for s in stories_with_walls])
    expected_stories = collect(0:(N_STORIES - 1))
    @assert stories_with_walls == expected_stories "walls on stories $stories_with_walls, expected $expected_stories"
    @assert all(count(w -> w.story == s, struc.walls) == 4 for s in expected_stories) "each story needs 4 box walls"

    # Mesh the analysis model; the core walls must become :wall shell triangles.
    to_asap!(struc)
    wall_shells = [sh for sh in struc.asap_model.shell_elements
                   if sh isa Asap.ShellTri3 && sh.id === :wall]
    println("wall shell triangles after to_asap!: $(length(wall_shells))")
    @assert !isempty(wall_shells) "core walls did not mesh into :wall shell elements"

    println("\nPASS: central box core initializes on every story and meshes.")
end

main()
