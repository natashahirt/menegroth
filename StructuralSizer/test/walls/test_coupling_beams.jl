# Coupling beams: §18.6 (corpus: aci-318-19, PDF pages 302–306) and
# §18.10.7.4 with φ = 0.85 from §21.2.4.4 (PDF pages 333–334 and 398).

using Test
using Unitful
using StructuralSizer

const _FC = 4000.0u"psi"
const _FY = 60.0u"ksi"
const _FYT = 60.0u"ksi"
const _ES = 29000.0u"ksi"

@testset "Width and span limits" begin
    wide = coupling_beam_dimensions(80.0u"inch", 20.0u"inch", 8.0u"inch", 17.0u"inch")
    @test wide.span_ok
    @test wide.width_ok
    @test wide.width_limit ≈ 6.0u"inch"
    narrow = coupling_beam_dimensions(160.0u"inch", 40.0u"inch", 8.0u"inch", 36.0u"inch")
    @test !narrow.width_ok
    @test narrow.width_limit ≈ 10.0u"inch"
    short = coupling_beam_dimensions(60.0u"inch", 20.0u"inch", 12.0u"inch", 17.0u"inch")
    @test !short.span_ok
end

@testset "Hoop spacing is the least of d/4, 6 in, and 6db" begin
    spacing = coupling_beam_hoop_spacing(20.0u"inch", 1.0u"inch", 60)
    @test spacing.spacing ≈ 5.0u"inch"
    @test spacing.first_hoop ≈ 2.0u"inch"
    deep = coupling_beam_hoop_spacing(40.0u"inch", 0.5u"inch", 60)
    @test deep.spacing ≈ 3.0u"inch"
    grade80 = coupling_beam_hoop_spacing(40.0u"inch", 1.0u"inch", 80)
    @test grade80.spacing ≈ 5.0u"inch"
end

@testset "Vc is omitted only when both §18.6.5.2 conditions hold" begin
    Ag = 12.0u"inch" * 24.0u"inch"
    Ve = 100.0u"kip"
    Veq = 80.0u"kip"
    light = 1.0u"kip"
    @test coupling_beam_concrete_omitted(Veq, Ve, light, Ag, _FC)
    @test !coupling_beam_concrete_omitted(40.0u"kip", Ve, light, Ag, _FC)
    heavy = Ag * _FC / 20
    @test !coupling_beam_concrete_omitted(Veq, Ve, heavy, Ag, _FC)
end

@testset "Ve is the two probable moments over the span, plus gravity shear" begin
    shear = coupling_beam_design_shear(200.0u"kip*ft", 200.0u"kip*ft", 10.0u"ft", 15.0u"kip")
    @test shear.V_eq ≈ 40.0u"kip"
    @test shear.Ve ≈ 55.0u"kip"
end

@testset "Mpr at 1.25 fy is above the nominal moment" begin
    bw, h = 12.0u"inch", 24.0u"inch"
    d, dp = 21.5u"inch", 2.5u"inch"
    As = 1.0u"inch^2"
    Nu = 0.0u"kip"
    mpr = coupling_beam_section_moment(bw, h, d, dp, As, _FC, _FY, _ES, Nu; stress_factor=1.25)
    mn = coupling_beam_section_moment(bw, h, d, dp, As, _FC, _FY, _ES, Nu)
    @test mpr.converged && mn.converged
    @test mpr.Mn > mn.Mn
    couple = 1.25 * _FY * As * (d - dp)
    @test mpr.Mn > 0.5 * couple
    @test mpr.Mn < 2.0 * couple
end

@testset "A special coupling beam places bars on both faces and hoops for Ve" begin
    designed = design_special_coupling_beam(
        10.0u"ft", 24.0u"inch", 12.0u"inch",
        150.0u"kip*ft", 0.0u"kip", 0.0u"kip", 10.0u"kip", 0.0u"kip",
        _FC, _FY, _FYT, _ES; dimensions=true)
    @test designed.ok
    @test designed.bars.n_bars >= 2
    @test designed.ρ <= designed.ρ_limit
    @test designed.dimensions.span_ok && designed.dimensions.width_ok
    @test designed.vc_omitted
    @test designed.stirrup_bar in 3:5
    @test ustrip(u"N*m", designed.φMn) >= ustrip(u"N*m", 150.0u"kip*ft")
    @test ustrip(u"N", designed.φVn) >= ustrip(u"N", designed.Ve)
end

@testset "Diagonal bars are at least four, in two layers, at φ = 0.85" begin
    bw, h, ℓn = 12.0u"inch", 36.0u"inch", 48.0u"inch"
    Acw = bw * h
    cap = coupling_beam_diagonal_strength(1.0u"inch^2", _FY, 0.4u"rad", _FC, Acw).cap
    Vu = 0.5 * COUPLING_BEAM_DIAGONAL_PHI * cap
    designed = design_diagonal_coupling_beam(ℓn, h, bw, Vu, _FC, _FY, _FYT)
    @test designed.ok
    @test designed.bars >= 4
    @test designed.layers >= 2
    @test iseven(designed.bars)
    @test ustrip(u"N", designed.φVn) >= ustrip(u"N", Vu)
    @test COUPLING_BEAM_DIAGONAL_PHI == 0.85
    over = design_diagonal_coupling_beam(ℓn, h, bw, 2 * cap, _FC, _FY, _FYT)
    @test !over.ok
end
