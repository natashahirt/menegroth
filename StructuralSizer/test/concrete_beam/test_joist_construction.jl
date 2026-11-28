# ACI 318-11 §8.13 joist-construction limits and the §8.13.8 shear increase.
# Corpus: aci-318-11, PDF pages 120–121.

using Test
using Unitful
using StructuralSizer

@testset "ACI 318-11 §8.13 joist construction" begin
    # 5 in rib, 16 in stem below the slab (≤ 3.5×5 = 17.5), 20 in clear (≤ 30),
    # 2.5 in slab (≥ max(20/12, 2) = 2) on removable forms.
    qualifying = JoistConstruction(:one_way, 5u"inch", 16u"inch", 20u"inch", 2.5u"inch")
    q = check_joist_construction(qualifying)
    @test q.width_ok
    @test q.depth_ok
    @test q.spacing_ok
    @test q.slab_ok
    @test q.vc_increase_permitted
    @test q.ok

    two_way = JoistConstruction(:two_orthogonal, 6u"inch", 20u"inch", 30u"inch", 2.5u"inch")
    @test check_joist_construction(two_way).ok

    narrow = JoistConstruction(:one_way, 3.9u"inch", 12u"inch", 20u"inch", 2.5u"inch")
    n = check_joist_construction(narrow)
    @test !n.width_ok
    @test !n.vc_increase_permitted

    # Depth equal to 3.5 widths is permitted; anything above is not.
    at_limit = JoistConstruction(:one_way, 4u"inch", 14u"inch", 20u"inch", 2.5u"inch")
    @test check_joist_construction(at_limit).depth_ok
    deep = JoistConstruction(:one_way, 4u"inch", 14.1u"inch", 20u"inch", 2.5u"inch")
    @test !check_joist_construction(deep).depth_ok
    @test !check_joist_construction(deep).vc_increase_permitted

    wide_gap = JoistConstruction(:one_way, 6u"inch", 16u"inch", 30.1u"inch", 3u"inch")
    @test !check_joist_construction(wide_gap).spacing_ok

    # §8.13.6.1 on a 30 in module with the 4 in minimum rib: clear 26 in, 2.17 in.
    @test joist_topping_thickness(30.0u"inch") ≈ (26.0 / 12) * u"inch"
    @test joist_topping_thickness(20.0u"inch") ≈ 2.0u"inch"
    @test joist_topping_thickness(40.0u"inch") === nothing

    # Removable forms: slab at least 2 in, even when clear/12 is smaller.
    thin_removable = JoistConstruction(:one_way, 6u"inch", 16u"inch", 6u"inch", 1.9u"inch")
    tr = check_joist_construction(thin_removable)
    @test !tr.slab_ok
    @test tr.vc_increase_permitted

    # §8.13.5.2: permanent filler, slab at least 1-1/2 in and clear/12.
    filler_ok = JoistConstruction(:one_way, 6u"inch", 16u"inch", 12u"inch", 1.5u"inch";
                                  permanent_structural_filler = true)
    @test check_joist_construction(filler_ok).slab_ok
    filler_thin = JoistConstruction(:one_way, 6u"inch", 16u"inch", 12u"inch", 1.4u"inch";
                                    permanent_structural_filler = true)
    @test !check_joist_construction(filler_thin).slab_ok

    @test_throws ArgumentError JoistConstruction(:radial, 6u"inch", 16u"inch",
                                                 20u"inch", 2.5u"inch")

    # Stem only. A 6 in rib, 20 in stem, and 3 in slab is 23 in from soffit to
    # the top of the slab, which is past 3.5×6 = 21. The stem itself is not.
    stem_only = JoistConstruction(:two_orthogonal, 6u"inch", 20u"inch", 30u"inch", 3u"inch")
    @test check_joist_construction(stem_only).depth_ok
    @test check_joist_construction(stem_only).ok
    stem_over = JoistConstruction(:two_orthogonal, 6u"inch", 21.1u"inch", 30u"inch", 3u"inch")
    @test !check_joist_construction(stem_over).depth_ok

    # Prismatic T-beam: stem = h − hf, clear spacing = center-to-center − bw.
    # 6 in web, 17 in total, 3 in flange → 14 in stem. 36 in centers → 30 in clear.
    rib = RCTBeamSection(bw=6u"inch", h=17u"inch", bf=36u"inch", hf=3u"inch",
                         bar_size=5, n_bars=2)
    from_section = JoistConstruction(rib, 36u"inch", :two_orthogonal)
    @test ustrip(u"inch", from_section.rib_depth) ≈ 14.0
    @test ustrip(u"inch", from_section.clear_spacing) ≈ 30.0
    @test ustrip(u"inch", from_section.slab_thickness) ≈ 3.0
    @test check_joist_construction(from_section).ok
    @test_throws ArgumentError JoistConstruction(rib, 6u"inch", :one_way)

    bw = 5u"inch"
    d = 14u"inch"
    fc = 4000u"psi"
    plain = Vc_beam(bw, d, fc)
    increased = Vc_joist(qualifying, bw, d, fc)
    @test increased ≈ StructuralSizer.JOIST_ONE_WAY_VC_FACTOR * plain
    refused = Vc_joist(narrow, bw, d, fc)
    @test refused ≈ plain

    # One literal. Punching must not grow a second copy or call the helper.
    src = read(joinpath(pkgdir(StructuralSizer),
                        "src/members/codes/aci/beams/joist_construction.jl"), String)
    @test count(==("1.10"), split(src)) == 1
    for rel in ("src/codes/aci/punching/check.jl",
                "src/slabs/codes/concrete/flat_plate/design/checks/punching.jl",
                "src/slabs/codes/concrete/waffle/solid_head_punching.jl")
        punching = read(joinpath(pkgdir(StructuralSizer), rel), String)
        @test !occursin("_joist_vc_factor", punching)
        @test !occursin("Vc_joist", punching)
        @test !occursin("JOIST_ONE_WAY_VC_FACTOR", punching)
    end

    Vu = 20u"kip"
    fyt = 60000u"psi"
    bare = design_beam_shear(Vu, bw, d, fc, fyt)
    with_joist = design_beam_shear(Vu, bw, d, fc, fyt; joist = qualifying)
    @test with_joist.Vc ≈ 1.10 * bare.Vc
    without_increase = design_beam_shear(Vu, bw, d, fc, fyt; joist = narrow)
    @test without_increase.Vc ≈ bare.Vc
end
