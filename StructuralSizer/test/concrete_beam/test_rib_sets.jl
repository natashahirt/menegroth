# Rib sets: one web and bottom bar size per line of rib pieces at a fixed
# story depth. Limits from ACI 318-11 §8.13.2 and §8.13.3 (corpus: aci-318-11,
# PDF page 120).

using Test
using Unitful
using StructuralSizer
using Asap: kip

const SSR = StructuralSizer

@testset "Rib sets at a story depth" begin
    s = 30u"inch"
    hf = 5u"inch"
    bf_of = (i, bw) -> bw + 2 * min(8 * hf, (s - bw) / 2)
    opts = ConcreteBeamOptions(include_flange = true)

    @testset "§8.13.2 and §8.13.3 filter the webs" begin
        # 6 in stem: every web from 4 to 8 in holds 3.5 bw ≥ stem.
        @test length(SSR.rib_set_webs(11u"inch", hf, s)) == 5
        # 24 in stem needs bw ≥ 24/3.5 ≈ 6.86 in.
        @test SSR.rib_set_webs(29u"inch", hf, s) == [7.0u"inch", 8.0u"inch"]
        # 30 in stem needs more than the widest joist web.
        @test isempty(SSR.rib_set_webs(35u"inch", hf, s))
        # 40 in centers leave more than 30 in clear.
        @test isempty(SSR.rib_set_webs(11u"inch", hf, 40u"inch"))
        @test_throws ArgumentError SSR.rib_set_webs(5u"inch", hf, s)
    end

    @testset "one web and bar size; counts per piece" begin
        Mu = [4.0, 18.0, 9.0] .* kip .* u"ft"
        Vu = [2.0, 5.0, 3.0] .* kip
        Mu_neg = [0.0, 0.0, 6.0] .* kip .* u"ft"
        geoms = [ConcreteMemberGeometry(0.762u"m") for _ in 1:3]
        res = SSR.size_rib_set(Mu, Vu, geoms, opts; h = 15u"inch", hf,
                               flange_width = bf_of, joist_spacing = s, Mu_neg)
        @test res.ok
        @test all(sec -> sec.h ≈ 15u"inch", res.sections)
        @test all(sec -> sec.bw == res.bw, res.sections)
        @test all(sec -> sec.bar_size == res.bar_size, res.sections)
        # The heaviest piece needs at least as many bars as the lightest.
        @test res.sections[2].n_bars >= res.sections[1].n_bars
        # Hogging puts top bars on that piece only.
        @test res.sections[3].n_bars_prime > 0
        @test res.sections[1].n_bars_prime == 0
        for (i, sec) in enumerate(res.sections)
            expl = SSR.check_tbeam_section(sec, Mu[i], Vu[i], geoms[i], opts;
                                           Mu_neg = Mu_neg[i], joist_spacing = s)
            @test expl.passed
        end
        total = sum(SSR.rib_section_carbon(sec, opts.material, opts.rebar_material, g.L)
                    for (sec, g) in zip(res.sections, geoms))
        @test res.carbon ≈ total
    end

    @testset "a shallow story fails where a deeper one passes" begin
        # Three #8 bars in an 8 in web at d ≈ 9.4 in carry about 93 kip·ft.
        Mu = [150.0] .* kip .* u"ft"
        Vu = [6.0] .* kip
        geoms = [ConcreteMemberGeometry(0.762u"m")]
        shallow = SSR.size_rib_set(Mu, Vu, geoms, opts; h = 11u"inch", hf,
                                   flange_width = bf_of, joist_spacing = s)
        @test !shallow.ok
        @test !isempty(shallow.reason)
        deep = SSR.size_rib_set(Mu, Vu, geoms, opts; h = 25u"inch", hf,
                                flange_width = bf_of, joist_spacing = s)
        @test deep.ok
    end

    @testset "a one-sided flange is the piece's own" begin
        one_side = (i, bw) -> i == 1 ? bw + min(6 * hf, (s - bw) / 2) : bf_of(i, bw)
        Mu = [8.0, 8.0] .* kip .* u"ft"
        Vu = [3.0, 3.0] .* kip
        geoms = [ConcreteMemberGeometry(0.762u"m") for _ in 1:2]
        res = SSR.size_rib_set(Mu, Vu, geoms, opts; h = 13u"inch", hf,
                               flange_width = one_side, joist_spacing = s)
        @test res.ok
        @test res.sections[1].bf < res.sections[2].bf
    end
end
