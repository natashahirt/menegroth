using Test
using Unitful
using Unitful: ustrip, uconvert
using StructuralSizer
using StructuralSizer.Asap: kip  # Asap custom unit

@testset "AISC companion manual 1 tests (v16.0 companion PDF)" begin

    @testset "Example D.1 - W-shape tension member (W8x21)" begin
        # From PDF extract:
        # - Try W8x21 (A992): Ag = 6.16 in^2, Fy=50 ksi, Fu=65 ksi
        # - Available tensile yielding: 277 kips (LRFD), 180 kips (ASD)
        # - Rupture uses Ae = 4.32 in^2 -> Ae/Ag ≈ 0.701; gives 211 kips (LRFD), 141 kips (ASD)
        # - Slenderness check: L/r = 25 ft / 1.26 in = 238 <= 300

        s = W("W8X21")
        mat = A992_Steel

        # Yielding (ϕ=0.9)
        ϕPn_yield = 0.9 * mat.Fy * s.A
        @test isapprox(ϕPn_yield, 277kip; rtol=0.03)

        # Rupture (ϕ=0.75, Ae = 4.32 in^2)
        Ae_ratio = ustrip(uconvert(Unitful.NoUnits, (4.32u"inch^2") / s.A))
        ϕPn_rupt = StructuralSizer.get_ϕPn_tension(s, mat; Ae_ratio=Ae_ratio)
        @test isapprox(ϕPn_rupt, 211kip; rtol=0.05)

        # Slenderness recommendation (D1 commentary): L/r <= 300
        L = 25.0u"ft"
        ry = s.ry
        slender = ustrip(uconvert(Unitful.NoUnits, L / ry))
        @test slender < 300
        @test isapprox(slender, 238; atol=5)
    end

    @testset "Example G.1B - W-shape in major-axis shear (W24x62)" begin
        # From PDF extract:
        # - W24x62, Fy=50 ksi, Cv1=1.0
        # - Aw ≈ d*tw = 10.2 in^2
        # - Vn = 0.6*Fy*Aw*Cv1 = 306 kips
        # - ϕv = 1.0 for rolled shapes -> ϕVn = 306 kips

        s = W("W24X62")
        mat = A992_Steel

        ϕVn = get_ϕVn(s, mat; axis=:strong)  # uses the code's Aw definition
        @test isapprox(ϕVn, 306kip; rtol=0.10)
    end

    @testset "Example E.4A excerpt - W14x82 compression table point" begin
        # From PDF extract around p.49:
        # - Using Lc = 9 ft in AISC Manual Table 4-1a, available strength in axial compression:
        #   940 kips (LRFD), 626 kips (ASD) for W14x82
        #
        # We approximate this by checking ϕPn about the weak axis with KL=9 ft.
        # (This is a sanity check; table values include rounding and may reflect the governing axis.)

        s = W("W14X82")
        mat = A992_Steel
        KL = 9.0u"ft"

        ϕPn_y = get_ϕPn(s, mat, KL; axis=:weak, ϕ=0.9)
        @test isapprox(ϕPn_y, 940kip; rtol=0.15)
    end
end

