# Geometry loading, transcribed-section alignment, and floor-system parameters.
# No building is designed.

using Test

include(joinpath(@__DIR__, "..", "src", "slab_design_factors", "study.jl"))

@testset "Slab Design Factors plans" begin
    if !isdir(SDF_ROOT)
        @test_skip "Slab Design Factors geometries are not beside this repo"
    else
        @testset "a parametric plan keeps its beam lines" begin
            plan = load_plan("grid/x0y0")
            @test length(plan.xy) == 9
            @test length(plan.lines) == 12
            @test length(plan.columns) == 9
            @test isempty(plan.sections)
            skel = plan_skeleton(plan)
            @test length(skel.groups_edges[:beams]) == 12
            @test length(skel.groups_edges[:columns]) == 9
            @test :floor in keys(skel.groups_faces)
            @test !isempty(skel.groups_faces[:floor])
        end

        @testset "transcribed sections are one per beam line" begin
            office = load_plan("validation/office")
            @test length(office.sections) == length(office.lines) == 252
            @test count(isnothing, office.sections) == 16
            school = load_plan("validation/school")
            warehouse = load_plan("validation/warehouse")
            @test length(school.sections) == 298
            @test length(warehouse.sections) == 131
            @test length(office.holes) == 12
            office_skel = plan_skeleton(office)
            @test length(office_skel.openings) == 12
            @test w_name(18, 35) == "W18X35"
            @test w_name(6, 8.5) == "W6X8.5"
            @test canonical_w("W18x35") == "W18X35"
            @test canonical_w("w30X90.0") == "W30X90"
        end

        @testset "loads follow the thesis occupancies" begin
            @test plan_loads("validation/office").ll == 60.0
            @test plan_loads("validation/school").ll == 50.0
            @test plan_loads("validation/warehouse").ll == 250.0
            @test plan_loads("validation/office").sdl == 20.0
            @test plan_loads("grid/x1y1").occupancy == "parametric"
            @test plan_loads("grid/x1y1").ll == 60.0
        end

        @testset "a rectangle's tributaries cover the floor once" begin
            for system in (:one_way, :two_way)
                row = tributary_balance("grid/x0y0", system)
                @test row.polygon_m2 ≈ row.gross_m2 rtol = 1e-6
                @test row.beam_m2 ≈ row.polygon_m2 rtol = 1e-6
                @test row.net_m2 ≈ row.gross_m2 rtol = 1e-6
                @test row.beam_kN ≈ row.cell_kN rtol = 1e-6
                # Edges parallel to a one-way span carry no width. Two-way reaches every edge.
                system == :two_way && @test row.n_bare == 0
            end
        end

        @testset "skewed one-way edges keep their whole strip" begin
            row = tributary_balance("special/star_8x12", :one_way)
            @test row.beam_m2 ≈ row.net_m2 rtol = 1e-9
        end

        @testset "faces filled by openings are void" begin
            # 4 of the warehouse floor faces are openings; two-way sizing used to
            # throw on their zero span.
            # Support-level beams are gone. The floor tributary still covers the
            # floor; the cell count is 49.
            row = tributary_balance("validation/warehouse", :two_way)
            @test row.n_cells == 49
            @test row.polygon_m2 ≈ row.net_m2 rtol = 1e-6
            @test row.beam_m2 ≈ row.polygon_m2 rtol = 1e-9
            @test row.beam_kN ≈ row.cell_kN rtol = 1e-6
        end

        @testset "a star joint is split onto the beam it meets" begin
            plan = load_plan("star/e10c2")
            skel = plan_skeleton(plan)
            # An unsplit plan would have one edge per line. The joint adds more.
            @test length(skel.groups_edges[:beams]) > length(plan.lines)
        end

        @testset "a grillage covers each rectangular panel" begin
            function _xy(skel, v)
                c = Meshes.coords(skel.vertices[v])
                return (ustrip(u"m", c.x), ustrip(u"m", c.y))
            end
            function _panel_area(skel, face, nξ, nη)
                poly = [_xy(skel, Int(v)) for v in skel.face_vertex_indices[face]]
                corners = StructuralSynthesizer._panel_corners(poly)
                length(corners) == 4 || return nothing
                pieces = StructuralSynthesizer.grillage_piece_profiles(corners, nξ, nη)
                area = sum(StructuralSizer.tributary_profile_area(
                    hypot(p.b[1] - p.a[1], p.b[2] - p.a[2]), p.positions, p.widths)
                           for p in pieces)
                return area, StructuralSizer.polygon_area_m(corners)
            end
            plan = load_plan("grid/x0y0")
            skel = plan_skeleton(plan)
            n_rect = 0
            for face in skel.groups_faces[:floor]
                got = _panel_area(skel, face, 2, 2)
                got === nothing && continue
                n_rect += 1
                @test got[1] ≈ got[2] rtol = 1e-6
            end
            @test n_rect == 4
            rhombus = plan_skeleton(load_plan("special/rhombus_8x12"))
            n_quad = 0
            for face in rhombus.groups_faces[:floor]
                got = _panel_area(rhombus, face, 2, 2)
                got === nothing && continue
                n_quad += 1
                @test got[1] ≈ got[2] rtol = 1e-4
            end
            @test n_quad >= 1
        end

        @testset "the three systems build" begin
            for system in SYSTEMS
                params = system_parameters("validation/office", system)
                @test params.loads.floor_LL == 60.0u"psf"
                @test params.loads.floor_SDL == 20.0u"psf"
            end
            deck = system_parameters("validation/warehouse", :deck)
            @test deck.floor.deck_profile == "3VLI"
            @test deck.floor.live_deflection_limit == 1 / 360
            @test deck.floor.superimposed_deflection_limit == 1 / 240
            @test deck.beams.composite
            @test deck.beams.composite_shored == false
            @test deck.loads.floor_LL == 250.0u"psf"
            @test uconvert(u"lb/ft^3", DECK_FILL.ρ) ≈ 145.0u"lb/ft^3" atol = 0.1u"lb/ft^3"
        end
    end
end
