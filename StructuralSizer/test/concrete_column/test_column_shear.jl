# ACI 318-19 column shear. The numbers below are computed from the clauses,
# not from design_column_shear, and then compared with it.
# corpus: aci-318-19. φ = 0.75 (§21.2.1). f'c = 4000 psi, fyt = 60 ksi.

using Test
using Unitful
using StructuralSizer

const _PHI = 0.75

function _shear_material()
    return ReinforcedConcreteMaterial(NWC_4000, Rebar_60)
end

@testset "Column shear" begin
    mat = _shear_material()
    fc = ustrip(u"psi", mat.concrete.fc′)
    fyt = ustrip(u"psi", mat.transverse.Fy)
    @test fc == 4000.0
    @test fyt == 60_000.0
    root = sqrt(fc)

    @testset "equation (a) caps" begin
        # Table 22.5.5.1(a), Nu = 0: Vc = 2λ√f'c bw d.
        plain = column_equation_a_pounds(12.0, 20.0, 12.0 * 24.0, fc, 0.0)
        @test plain.Vc_lb ≈ 2.0 * root * 12.0 * 20.0 rtol = 1e-12
        @test plain.Vn_limit_lb ≈ plain.Vc_lb + 8.0 * root * 12.0 * 20.0 rtol = 1e-12

        # Nu/(6Ag) = 100 psi. Under both 0.05f'c = 200 psi and 5λ√f'c.
        Nu_100 = 100.0 * 6.0 * (12.0 * 24.0)
        raised = column_equation_a_pounds(12.0, 20.0, 12.0 * 24.0, fc, Nu_100)
        @test raised.Vc_lb ≈ plain.Vc_lb + 100.0 * 12.0 * 20.0 rtol = 1e-9

        # 0.05f'c = 200 psi (§22.5.5.1.2). 2√f'c + 200 exceeds 5√f'c
        # (§22.5.5.1.1), so Vc stops at the ceiling and a larger Nu adds nothing.
        Ag = 12.0 * 24.0
        at_nu = column_equation_a_pounds(12.0, 20.0, Ag, fc, 0.05 * fc * 6.0 * Ag)
        over = column_equation_a_pounds(12.0, 20.0, Ag, fc, 0.10 * fc * 6.0 * Ag)
        @test at_nu.Vc_lb ≈ 5.0 * root * 12.0 * 20.0 rtol = 1e-9
        @test over.Vc_lb ≈ at_nu.Vc_lb rtol = 1e-12

        # §22.5.3.1: √f'c inside Vc stops at 100 psi. The 8√f'c term does not.
        hi = column_equation_a_pounds(12.0, 20.0, Ag, 15_000.0, 0.0)
        @test hi.Vc_lb ≈ 2.0 * 100.0 * 12.0 * 20.0 rtol = 1e-9
        @test hi.Vn_limit_lb ≈ hi.Vc_lb + 8.0 * sqrt(15_000.0) * 12.0 * 20.0 rtol = 1e-9

        # Tension that cancels 2λ√f'c leaves Vc at zero.
        Nu_zero = -(2.0 * root) * 6.0 * Ag
        @test column_equation_a_pounds(12.0, 20.0, Ag, fc, Nu_zero).Vc_lb ≈ 0.0 atol = 1e-6
    end

    @testset "tie legs match the crosstie rule" begin
        four = RCColumnSection(; b = 16.0u"inch", h = 16.0u"inch", bar_size = 8,
                               n_bars = 4, cover = 1.5u"inch", tie_bar_size = 3)
        @test column_tie_legs(four) == (x = 2, y = 2)
        # 12 #8 bars, four per face: one alternate bar between the corners,
        # so one crosstie each way. Av counts three legs, not two.
        twelve = RCColumnSection(; b = 24.0u"inch", h = 24.0u"inch", bar_size = 8,
                                 n_bars = 12, cover = 1.5u"inch", tie_bar_size = 3)
        legs = column_tie_legs(twelve)
        @test legs.x == 3
        @test legs.y == 3
    end

    @testset "a small shear stays at the support spacing on equation (c)" begin
        # 17 in. square, 4 #8, No. 3 ties. §10.9.1 keeps ρg above 0.01
        # (4×0.79/289 = 0.0109). §25.7.2.1 spacing is 16 in.
        # Av/s = 2·0.11/16 is below Av,min/s = 50·bw/fyt, so Table 22.5.5.1(c)
        # applies. Vu is under 0.5φVc, so §10.6.2 does not require Av,min and
        # Table 10.7.6.5.2 does not close the spacing.
        sec = RCColumnSection(; b = 17.0u"inch", h = 17.0u"inch", bar_size = 8,
                              n_bars = 4, cover = 1.5u"inch", tie_bar_size = 3)
        db_long = ustrip(u"inch", bar_diameter(8))
        db_tie = ustrip(u"inch", bar_diameter(3))
        s_support = min(16.0 * db_long, 48.0 * db_tie, 24.0)
        @test s_support == 16.0
        designed = design_column_shear(sec, 10.0u"kN", 0.0u"N", 0.0u"N", mat)
        @test designed.ok
        @test ustrip(u"inch", designed.spacing) ≈ s_support rtol = 1e-9
        @test occursin("(c)", designed.clause)
        @test occursin("No. 3 ties at", designed.clause)
        @test designed.tie_bar_size == 3
        @test sec.b == 17.0u"inch"
        @test sec.h == 17.0u"inch"

        d = ustrip(u"inch", effective_depth(sec; axis = :x))
        bw = 17.0
        Ab = ustrip(u"inch^2", bar_area(3))
        Av = 2.0 * Ab
        λs = min(sqrt(2.0 / (1.0 + d / 10.0)), 1.0)
        As = 2.0 * ustrip(u"inch^2", bar_area(8))
        ρw = As / (bw * d)
        Vc = (8.0 * λs * cbrt(ρw) * root) * bw * d
        Vs = Av * fyt * d / s_support
        ϕVn = _PHI * (Vc + Vs)
        @test ustrip(u"lbf", designed.ϕVn_x) ≈ ϕVn rtol = 1e-6
        @test designed.ratio_x ≈ ustrip(u"lbf", 10.0u"kN") / ϕVn rtol = 1e-6
        @test designed.ratio_x < 0.5
        @test designed.interaction_ratio == 0.0
    end

    @testset "shear above half of φVc,c meets Av,min and the spacing table" begin
        sec = RCColumnSection(; b = 17.0u"inch", h = 17.0u"inch", bar_size = 8,
                              n_bars = 4, cover = 1.5u"inch", tie_bar_size = 3)
        d = ustrip(u"inch", effective_depth(sec; axis = :x))
        bw = 17.0
        Ab = ustrip(u"inch^2", bar_area(3))
        Av = 2.0 * Ab
        λs = min(sqrt(2.0 / (1.0 + d / 10.0)), 1.0)
        ρw = 2.0 * ustrip(u"inch^2", bar_area(8)) / (bw * d)
        Vc_c = (8.0 * λs * cbrt(ρw) * root) * bw * d
        # Three quarters of φVc,c is above the §10.6.2.1 threshold and, for
        # this section, below φVc of equation (a). Av,min then switches the
        # section to equation (a). Vs there is still under 4√f'c bw d, so
        # Table 10.7.6.5.2 limits s to d/2.
        Vu = 0.75 * _PHI * Vc_c
        av_s = max(0.75 * root, 50.0) * bw / fyt
        s_av = Av / av_s
        s_table = min(d / 2.0, 24.0)
        @test s_table < s_av
        designed = design_column_shear(sec, Vu * u"lbf", 0.0u"N", 0.0u"N", mat)
        @test designed.ok
        @test ustrip(u"inch", designed.spacing) ≈ s_table rtol = 1e-6
        @test occursin("(a)", designed.clause)
        Vc_a = 2.0 * root * bw * d
        Vs = Av * fyt * d / s_table
        @test ustrip(u"lbf", designed.ϕVn_x) ≈ _PHI * (Vc_a + Vs) rtol = 1e-6
        @test designed.ratio_x < 1
    end

    @testset "both axes above one half are held to Eq. (22.5.1.11)" begin
        # 16 in. square already meets Av,min at the §25.7.2.1 spacing, so
        # equation (a) applies before any tightening. The demand below is
        # 0.8φVn at the Table 10.7.6.5.2 spacing. Each axis is under 1.0
        # there, and the sum is over 1.5, so the spacing has to close until
        # each ratio is 0.75.
        sec = RCColumnSection(; b = 16.0u"inch", h = 16.0u"inch", bar_size = 8,
                              n_bars = 4, cover = 1.5u"inch", tie_bar_size = 3)
        d = ustrip(u"inch", effective_depth(sec; axis = :x))
        bw = 16.0
        Av = 2.0 * ustrip(u"inch^2", bar_area(3))
        s_table = min(d / 2.0, 24.0)
        Vc = 2.0 * root * bw * d
        ϕVn_table = _PHI * (Vc + Av * fyt * d / s_table)
        Vu = 0.8 * ϕVn_table
        @test Vu < _PHI * (Vc + 8.0 * root * bw * d)
        Vs_req = Vu / 0.75 / _PHI - Vc
        s_eq = Av * fyt * d / Vs_req
        @test s_eq < s_table
        designed = design_column_shear(sec, Vu * u"lbf", Vu * u"lbf", 0.0u"N", mat)
        @test designed.ok
        @test designed.section_ok
        @test ustrip(u"inch", designed.spacing) ≈ s_eq rtol = 1e-4
        @test designed.ratio_x > 0.5
        @test designed.ratio_y > 0.5
        @test designed.interaction_ratio <= 1.0 + 1e-6
        @test designed.ratio ≈ designed.interaction_ratio
    end

    @testset "a demand past the section limit fails and the section stays" begin
        sec = RCColumnSection(; b = 12.0u"inch", h = 12.0u"inch", bar_size = 8,
                              n_bars = 4, cover = 1.5u"inch", tie_bar_size = 3)
        d = ustrip(u"inch", effective_depth(sec; axis = :x))
        limit = _PHI * (2.0 * root * 12.0 * d + 8.0 * root * 12.0 * d)
        Vu = 2.0 * limit
        designed = design_column_shear(sec, Vu * u"lbf", 0.0u"N", 0.0u"N", mat)
        @test !designed.ok
        @test !designed.section_ok
        @test designed.ratio > 1
        @test designed.ratio_x ≈ Vu / limit rtol = 1e-4
        @test occursin("22.5.1.2", designed.clause)
        @test sec.b == 12.0u"inch"
        @test sec.h == 12.0u"inch"
    end

    @testset "a circular tie uses bw = D and d = 0.8D" begin
        sec = RCCircularSection(; D = 20.0u"inch", bar_size = 8, n_bars = 8,
                                cover = 1.5u"inch", tie_type = :tied)
        designed = design_column_shear(sec, 5.0u"kN", 0.0u"N", 0.0u"N", mat)
        D = 20.0
        d = 0.8 * D
        s = min(16.0 * ustrip(u"inch", bar_diameter(8)),
                48.0 * ustrip(u"inch", bar_diameter(3)), D)
        Av = 2.0 * ustrip(u"inch^2", bar_area(3))
        @test designed.ok
        @test designed.tie_bar_size == 3
        @test ustrip(u"inch", designed.spacing) ≈ s rtol = 1e-6
        # Bars inside the outer thirds. Equation (c) at this spacing: Av/s is
        # under Av,min/s = 50·D/fyt, and 5 kN is under half of φVc.
        third = D / 3.0
        As_face = sum(ustrip(u"inch^2", bar.As) for bar in sec.bars
                      if ustrip(u"inch", bar.y) < third; init = 0.0)
        ρw = As_face / (D * d)
        λs = min(sqrt(2.0 / (1.0 + d / 10.0)), 1.0)
        Vc = (8.0 * λs * cbrt(ρw) * root) * D * d
        Vs = Av * fyt * d / s
        @test ustrip(u"lbf", designed.ϕVn_x) ≈ _PHI * (Vc + Vs) rtol = 1e-5
        @test occursin("(c)", designed.clause)
    end
end
