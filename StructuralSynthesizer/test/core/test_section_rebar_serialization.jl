using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful

# Rebar coordinates in the frame-element visualization payload must share the
# section polygon's frame (centroid origin, y = width, z = depth) and units, so
# clients can overlay them without extra transforms.
@testset "Section rebar serialization" begin
    du = StructuralSynthesizer.DisplayUnits(:imperial)
    to_in(v) = ustrip(u"inch", v * du.units[:length])

    @testset "Rectangular 6-bar layout (asymmetric about the two axes)" begin
        sec = StructuralSizer.RCColumnSection(b = 16u"inch", h = 16u"inch", bar_size = 8, n_bars = 6)
        pts, dia = StructuralSynthesizer._serialize_section_rebar(sec, du)
        poly = StructuralSynthesizer._serialize_section_polygon(sec, du, 1)
        @test length(pts) == 6
        @test to_in(dia) ≈ 1.0 atol = 0.01
        # Every bar lies inside the polygon's bounding box.
        ymax = maximum(abs(p[1]) for p in poly)
        zmax = maximum(abs(p[2]) for p in poly)
        @test all(abs(p[1]) < ymax && abs(p[2]) < zmax for p in pts)
        # 3 bars on each z-face, none mid-height on the y-faces.
        @test count(p -> p[2] > 0, pts) == 3
        @test count(p -> abs(p[2]) < 1e-9, pts) == 0
    end

    @testset "Circular bars are centred on the origin" begin
        sec = StructuralSizer.RCCircularSection(D = 20u"inch", bar_size = 8, n_bars = 6, cover = 1.5u"inch")
        pts, _ = StructuralSynthesizer._serialize_section_rebar(sec, du)
        radii = [to_in(hypot(p[1], p[2])) for p in pts]
        @test length(pts) == 6
        @test all(r -> isapprox(r, radii[1]; atol = 1e-4), radii)
    end

    @testset "Composite studs serialize in the element frame" begin
        s_m = ustrip(u"m", 2.5u"ft")
        y_m = ustrip(u"m", 1.5u"inch")
        d_m = uconvert(u"m", 0.75u"inch")
        l_m = uconvert(u"m", 5.0u"inch")
        z_m = ustrip(u"m", 10.4u"inch")
        entry = (pts = [(s_m, y_m), (s_m, -y_m)], d_sa = d_m, l_sa = l_m, z_flange = z_m)
        pts, dia, len = StructuralSynthesizer._serialize_element_studs(entry, du)
        @test length(pts) == 2
        @test length(pts[1]) == 3
        @test to_in(pts[1][1]) ≈ 30.0 atol = 1e-4
        @test to_in(pts[1][2]) ≈ 1.5 atol = 1e-4
        @test to_in(pts[1][3]) ≈ 10.4 atol = 1e-4
        @test to_in(pts[2][2]) ≈ -1.5 atol = 1e-4
        @test to_in(dia) ≈ 0.75 atol = 1e-4
        @test to_in(len) ≈ 5.0 atol = 1e-4
        @test StructuralSynthesizer._serialize_element_studs(nothing, du) == (Vector{Float64}[], 0.0, 0.0)
    end

    @testset "Sections without rebar serialize empty" begin
        @test StructuralSynthesizer._serialize_section_rebar(nothing, du) == (Vector{Float64}[], 0.0)
        w = StructuralSizer.W("W14X90")
        @test StructuralSynthesizer._serialize_section_rebar(w, du) == (Vector{Float64}[], 0.0)
    end
end
