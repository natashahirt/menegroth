# Columns and beams inside a wall are parked in :absent. The wall is the
# support there.

using Test
using Unitful
using Meshes
using StructuralSynthesizer
using StructuralSizer

const SSyn = StructuralSynthesizer

function _endpoints(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    m(x) = ustrip(u"m", x)
    return (m(c1.x), m(c1.y), m(c1.z)), (m(c2.x), m(c2.y), m(c2.z))
end

"""One 6 m bay, two 3 m stories, the story-1 beam along y = 0 claimed as a wall."""
function _one_wall_bay()
    skel = gen_medium_office(6.0u"m", 6.0u"m", 3.0u"m", 1, 1, 2)
    beams = skel.groups_edges[:beams]
    on_line = [e for e in skel.stories[1].edges if e in beams &&
               all(p -> abs(p[2]) < 1e-6, _endpoints(skel, e))]
    eidx = only(on_line)
    filter!(!=(eidx), beams)
    push!(get!(skel.groups_edges, :walls, Int[]), eidx)
    return skel
end

function _initialized(skel; kwargs...)
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:flat_plate,
        material=NWC_4000,
        floor_opts=FlatPlateOptions(material=RC_4000_60),
        wall_thickness=0.30u"m", kwargs...)
    return struc
end

@testset "Members inside a wall are parked" begin
    skel = _one_wall_bay()
    n_columns = length(skel.groups_edges[:columns])
    struc = _initialized(skel)
    absent = get(skel.groups_edges, :absent, Int[])
    ends = [_endpoints(skel, e) for e in absent]

    # The wall runs from z = 3 to z = 6 along y = 0. The two columns in that
    # story at x = 0 and x = 6 are inside it. The columns below only touch it.
    parked_columns = [p for p in ends if abs(p[1][3] - p[2][3]) > 1.0]
    @test length(parked_columns) == 2
    @test all(p -> abs(p[1][2]) < 1e-6 && min(p[1][3], p[2][3]) ≈ 3.0, parked_columns)
    @test length(skel.groups_edges[:columns]) == n_columns - 2
    @test length(struc.columns) == n_columns - 2

    # The roof beam on the wall's top line is the wall's top edge.
    parked_beams = [p for p in ends if abs(p[1][3] - p[2][3]) <= 1e-6]
    @test length(parked_beams) == 1
    @test all(z -> z ≈ 6.0, (parked_beams[1][1][3], parked_beams[1][2][3]))
    @test length(struc.walls) == 1

    # The switch keeps them as members.
    kept = _one_wall_bay()
    struc_kept = _initialized(kept; park_wall_overlaps=false)
    @test isempty(get(kept.groups_edges, :absent, Int[]))
    @test length(struc_kept.columns) == n_columns
end

@testset "A beam is parked only where walls cover all of it" begin
    # Beam from x = 0 to x = 6 at z = 3. Walls are boxes on y = 0.
    vc = [0.0 0.0 3.0; 6.0 0.0 3.0]
    skel = (edge_indices = [(1, 2)],)
    wall(a, b; z0 = 3.0, z1 = 6.0) = (a = a, b = b, z0 = z0, z1 = z1)
    inbeam(walls) = SSyn._beam_in_wall(skel, 1, vc, walls)
    @test inbeam([wall((0.0, 0.0), (6.0, 0.0))])
    # Two walls that meet cover it together.
    @test inbeam([wall((0.0, 0.0), (3.0, 0.0)), wall((3.0, 0.0), (6.0, 0.0))])
    # Half covered stays a beam.
    @test !inbeam([wall((0.0, 0.0), (3.0, 0.0))])
    # A wall on the same grid line, past the beam's end, does not cover it.
    # The wall covers its own segment, not the line beyond its ends.
    @test !inbeam([wall((6.0, 0.0), (12.0, 0.0))])
    # A parallel wall off the line, and a wall at another height, do not count.
    @test !inbeam([wall((0.0, 0.5), (6.0, 0.5))])
    @test !inbeam([wall((0.0, 0.0), (6.0, 0.0); z0 = 6.0, z1 = 9.0)])
    # The wall's top line counts: a wall from z = 0 to z = 3 below the beam.
    @test inbeam([wall((0.0, 0.0), (6.0, 0.0); z0 = 0.0, z1 = 3.0)])

    # A column at x = 3 on the wall overlaps it. One that ends at the wall's
    # base only touches it.
    cvc = [3.0 0.0 3.0; 3.0 0.0 6.0; 3.0 0.0 0.0]
    cskel = (edge_indices = [(1, 2), (3, 1)],)
    w = [wall((0.0, 0.0), (6.0, 0.0))]
    @test SSyn._column_in_wall(cskel, 1, cvc, w)
    @test !SSyn._column_in_wall(cskel, 2, cvc, w)
    # Off the line by more than the tolerance.
    off = [3.0 0.01 3.0; 3.0 0.01 6.0]
    @test !SSyn._column_in_wall((edge_indices = [(1, 2)],), 1, off, w)
end
