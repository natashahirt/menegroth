# A solid head is the rib bays around one column. It grows by one bay in the
# direction of a failing check, and the two-way section is d/2 outside that
# outline (ACI 318-11 §11.11.1.2, corpus: aci-318-11, page 200).

using Test
using Unitful
using StructuralSizer

const SSH = StructuralSizer

"""A 4 m square of 1 m modules, ribs through the origin."""
function _module_grid()
    outline = [(0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)]
    arr = SSH.modular_rib_arrangement(outline, (); angle = 0.0, spacing = (1.0, 1.0),
                                      origin = (0.0, 0.0))
    return outline, arr
end

@testset "solid heads on a rib arrangement" begin
    outline, arr = _module_grid()
    d = 0.2u"m"

    @testset "a corner, an edge, and an interior head match the rectangular section" begin
        corner = SSH.seed_column_head(arr, (0.0, 0.0))
        @test length(corner.bays) == 1
        sec = SSH.column_head_section(arr, corner, d; free_loops = (outline,))
        geom = SSH.punching_geometry(1.0u"m", 1.0u"m", d; position = :corner)
        @test sec.closed == false
        @test sec.properties.b0 ≈ geom.b0
        @test sec.area ≈ geom.b1 * geom.b2

        edge = SSH.seed_column_head(arr, (2.0, 0.0))
        @test length(edge.bays) == 2
        sec = SSH.column_head_section(arr, edge, d; free_loops = (outline,))
        geom = SSH.punching_geometry(1.0u"m", 2.0u"m", d; position = :edge)
        @test sec.closed == false
        @test sec.properties.b0 ≈ geom.b0
        @test sec.area ≈ geom.b1 * geom.b2

        inner = SSH.seed_column_head(arr, (2.0, 2.0))
        @test length(inner.bays) == 4
        sec = SSH.column_head_section(arr, inner, d; free_loops = (outline,))
        geom = SSH.punching_geometry(2.0u"m", 2.0u"m", d; position = :interior)
        @test sec.closed
        @test sec.properties.b0 ≈ geom.b0
        @test sec.area ≈ geom.b1 * geom.b2
        @test all(t -> t === :convex, sec.turns)
    end

    @testset "growth adds the bays facing the failure, and stops at another head" begin
        bay = SSH.seed_column_head(arr, (1.5, 1.5))
        @test length(bay.bays) == 1
        ell = SSH.grow_column_head(arr, bay, (1.0, 1.0))
        @test length(ell.bays) == 3
        sec = SSH.column_head_section(arr, ell, d; free_loops = (outline,))
        @test sec.closed
        @test count(==( :reentrant), sec.turns) == 1
        @test ustrip(u"m^2", sec.area) > 3.0

        west = SSH.seed_column_head(arr, (1.0, 2.0))
        east = SSH.seed_column_head(arr, (3.0, 2.0))
        @test isempty(intersect(west.bays, east.bays))
        @test_throws ArgumentError SSH.grow_column_head(arr, west, (1.0, 0.0); taken = east.bays)
        # The corner head's only bays lie up and to the right. Back toward the
        # corner there is no module, so that direction does not grow.
        corner = SSH.seed_column_head(arr, (0.0, 0.0))
        @test_throws ArgumentError SSH.grow_column_head(arr, corner, (-1.0, -1.0))
    end

    @testset "a head against the slab edge cannot grow past it" begin
        corner = SSH.seed_column_head(arr, (0.0, 0.0))
        head = corner
        for _ in 1:3
            head = SSH.grow_column_head(arr, head, (1.0, 0.0); free_loops = (outline,))
        end
        @test_throws ArgumentError SSH.grow_column_head(arr, head, (1.0, 0.0);
                                                       free_loops = (outline,))
    end

    @testset "no direction grows one ring, the next whole module" begin
        # On a rectangular grid the ring is the corner, edge, or interior
        # head one module larger each way.
        corner = SSH.grow_column_head(arr, SSH.seed_column_head(arr, (0.0, 0.0)), nothing)
        @test length(corner.bays) == 4
        sec = SSH.column_head_section(arr, corner, d; free_loops = (outline,))
        geom = SSH.punching_geometry(2.0u"m", 2.0u"m", d; position = :corner)
        @test sec.properties.b0 ≈ geom.b0
        @test all(t -> t !== :reentrant, sec.turns)

        edge = SSH.grow_column_head(arr, SSH.seed_column_head(arr, (2.0, 0.0)), nothing)
        @test length(edge.bays) == 8
        # The ring reaches both side edges of this 4 m slab, so only the
        # inner face is a section.
        sec = SSH.column_head_section(arr, edge, d; free_loops = (outline,))
        @test sec.properties.b0 ≈ 4.0u"m"

        inner = SSH.grow_column_head(arr, SSH.seed_column_head(arr, (2.0, 2.0)), nothing)
        @test length(inner.bays) == length(arr.bays)
        @test_throws ArgumentError SSH.grow_column_head(arr, inner, nothing)

        # A ring that would touch another head, even at one corner, is refused.
        diagonal = SSH.seed_column_head(arr, (2.5, 2.5))
        @test length(diagonal.bays) == 1
        @test isempty(intersect(corner.bays, diagonal.bays))
        @test_throws ArgumentError SSH.grow_column_head(arr, corner, nothing;
                                                       taken = diagonal.bays)
    end

    @testset "a failing rib grows one bay in its own direction" begin
        col = (position = :interior, c1 = 20.0u"inch", c2 = 20.0u"inch", shape = :rectangular)
        web = 4 * 6.0u"inch" * 14.0u"inch"
        function head_check(Vu_rib, outward)
            rib = (Vu = Vu_rib, bw = 6.0u"inch", d = 14.0u"inch", joist = nothing,
                   outward = outward)
            return SSH.check_solid_head_punching(
                col, 5.0u"kip", 0.0u"kip" * u"ft", 16.0u"inch", 18.0u"inch", 4000.0u"psi",
                [rib];
                b0 = 80.0u"inch", web_area = web, head_width = 40.0u"inch",
                side_long = 40.0u"inch", side_short = 40.0u"inch", position = :interior)
        end
        east = head_check(400.0u"kip", (1.0, 0.0))
        north = head_check(800.0u"kip", (0.0, 1.0))
        @test east.governing === :rib_one_way && !east.ok
        @test north.governing === :rib_one_way && !north.ok
        @test east.Vu ≈ 400.0u"kip"
        @test north.Vu ≈ 800.0u"kip"
        seeded = SSH.seed_column_head(arr, (1.5, 1.5))
        @test length(seeded.bays) == 1
        grown_east = SSH.grow_checked_column_head(arr, seeded, east)
        grown_north = SSH.grow_checked_column_head(arr, seeded, north)
        heavier = SSH.grow_checked_column_head(arr, seeded, north)
        @test length(grown_east.bays) == 2
        @test length(grown_north.bays) == 2
        @test grown_east.bays != grown_north.bays
        @test heavier.bays == grown_north.bays
        again = SSH.grow_checked_column_head(arr, grown_east, east)
        @test length(again.bays) == 3
        @test issubset(grown_east.bays, again.bays)

        passing = head_check(1.0u"kip", (1.0, 0.0))
        @test passing.ok
        @test SSH.grow_checked_column_head(arr, seeded, passing).bays == seeded.bays

        # No named direction: one ring all the way around, corners included.
        unnamed = head_check(400.0u"kip", nothing)
        @test unnamed.governing === :rib_one_way && unnamed.direction === nothing
        ring = SSH.grow_checked_column_head(arr, seeded, unnamed)
        @test length(ring.bays) == 9
        @test issubset(seeded.bays, ring.bays)

        no_demand = (ok = false, direction = (1.0, 0.0), Vu = 0.0u"N")
        @test SSH.grow_checked_column_head(arr, seeded, no_demand).bays == seeded.bays
    end

    @testset "the solved head stops when the ratio does not fall" begin
        seeded = SSH.seed_column_head(arr, (1.5, 1.5))
        function check_at(head)
            n = length(head.bays)
            ratio = n == 1 ? 2.0 : n == 2 ? 1.5 : 1.6
            return (ok = false, direction = (1.0, 0.0), Vu = 1.0u"N", ratio = ratio)
        end
        held = SSH.resolve_column_head(arr, seeded, check_at)
        @test held.stop === :ratio
        @test held.steps == 1
        @test length(held.head.bays) == 2
        @test held.check.ratio ≈ 1.5

        passing = _ -> (ok = true, direction = nothing, Vu = 1.0u"N", ratio = 0.4)
        stayed = SSH.resolve_column_head(arr, seeded, passing)
        @test stayed.stop === :passed && stayed.steps == 0
        @test stayed.head.bays == seeded.bays

        # No direction grows a ring, and the ring is kept only if the ratio falls.
        ringed = head -> (ok = false, direction = nothing, Vu = 1.0u"N",
                          ratio = 2.0 / length(head.bays))
        grew = SSH.resolve_column_head(arr, seeded, ringed)
        @test grew.steps >= 1
        @test length(grew.head.bays) >= 9
        flat = _ -> (ok = false, direction = nothing, Vu = 1.0u"N", ratio = 1.2)
        held = SSH.resolve_column_head(arr, seeded, flat)
        @test held.stop === :ratio
        @test held.head.bays == seeded.bays
        none = _ -> (ok = false, direction = nothing, Vu = 0.0u"N", ratio = 1.2)
        @test SSH.resolve_column_head(arr, seeded, none).stop === :no_demand

        corner = SSH.seed_column_head(arr, (0.0, 0.0))
        east = head -> (ok = false, direction = (1.0, 0.0), Vu = 1.0u"N",
                        ratio = 3.0 - 0.1 * length(head.bays))
        blocked = SSH.resolve_column_head(arr, corner, east; free_loops = (outline,))
        @test blocked.stop === :blocked
        @test blocked.steps == 3

        hog = (ok = false, governing = :rib_hogging, direction = (0.0, 1.0),
               Vu = 0.0u"N", Mu = 1.0u"N*m", ratio = 1.4)
        grown = SSH.grow_checked_column_head(arr, seeded, hog)
        @test length(grown.bays) == length(seeded.bays) + 1
        quiet = (ok = false, governing = :rib_hogging, direction = (0.0, 1.0),
                 Vu = 0.0u"N", Mu = 0.0u"N*m", ratio = 1.4)
        @test SSH.grow_checked_column_head(arr, seeded, quiet).bays == seeded.bays
    end

    @testset "a column outside the ribs is refused" begin
        @test_throws ArgumentError SSH.seed_column_head(arr, (5.0, 5.0))
    end

    @testset "parallel ribs of one head share its width" begin
        corner = SSH.seed_column_head(arr, (0.0, 0.0))
        widths = SSH.solid_edge_widths(arr, [corner])
        @test length(widths) == 4
        @test all(w -> w ≈ 0.5, values(widths))
        east = SSH.grow_column_head(arr, corner, (1.0, 0.0))
        wider = SSH.solid_edge_widths(arr, [east])
        @test any(w -> abs(w - 2 / 3) < 1e-9, values(wider))
        @test maximum(values(wider)) > maximum(values(widths))
        panel = SSH.IsoParametricPanel(((0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)))
        grid = SSH.WaffleRibGrid(panel, 4, 4; solid_head = 0.25)
        @test any(w -> w ≈ 0.5, SSH.solid_piece_widths(grid))
        neighbour = SSH.seed_column_head(arr, (1.0, 0.0))
        @test_throws ArgumentError SSH.solid_edge_widths(arr, [corner, neighbour])
    end
end
