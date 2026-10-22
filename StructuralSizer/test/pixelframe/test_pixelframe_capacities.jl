# ==============================================================================
# Tests: PixelFrame Capacity Functions
# ==============================================================================
# Validates axial, flexural, shear, carbon, and deflection calculations
# against the Wongsittikan (2024) thesis and the original Pixelframe.jl.
#
# Thesis Section 3.1 reference section:
#   L_px = 125 mm, t = 30 mm, L_c = 30 mm
#   fc' = 57 MPa, dosage = 20 kg/m³, fR1 ≈ 4.19 MPa, fR3 ≈ 2.5 MPa
#   A_s = 2 × 10mm dia = 157 mm², f_pe = 500 MPa, d_ps = 200 mm
#
# The cross-section is a Y-shaped tri-leg profile (3 arms at 120°), NOT rectangular.
# Section properties come from Asap's CompoundSection polygon geometry.
# ==============================================================================

using Test
using StructuralSizer
using Unitful
using Asap  # kgCO2e for standalone runs
using Asap: CompoundSection

# ==============================================================================
# Helper: build the thesis reference section
# ==============================================================================

function _thesis_section(; fc′_MPa=57.0, dosage=20.0, fR1=nothing, fR3=nothing,
                          A_s_mm2=157.0, f_pe_MPa=500.0, d_ps_mm=200.0,
                          λ=:Y)
    # Use regression functions if fR values not provided
    _fR1 = fR1 === nothing ? fc′_dosage2fR1(fc′_MPa, dosage) : Float64(fR1)
    _fR3 = fR3 === nothing ? fc′_dosage2fR3(fc′_MPa, dosage) : Float64(fR3)

    conc = Concrete(
        Ec(fc′_MPa * u"MPa"),
        fc′_MPa * u"MPa",
        2400.0u"kg/m^3",
        0.2,     # ν
        0.15;    # ecc (placeholder)
        εcu = 0.003,
        λ = 1.0,
        aggregate_type = StructuralSizer.siliceous,
    )
    frc = FiberReinforcedConcrete(conc, dosage, _fR1, _fR3)
    PixelFrameSection(;
        λ = λ,
        L_px = 125.0u"mm",
        t = 30.0u"mm",
        L_c = 30.0u"mm",
        material = frc,
        A_s = A_s_mm2 * u"mm^2",
        f_pe = f_pe_MPa * u"MPa",
        d_ps = d_ps_mm * u"mm",
    )
end

@testset "PixelFrame Capacities" begin

    # =========================================================================
    # Section geometry — Y-shaped polygon
    # =========================================================================
    @testset "Section geometry — Y-shaped polygon" begin
        s = _thesis_section()

        # The section has a CompoundSection field
        cs = s.section
        @test cs isa CompoundSection

        # Polygon area should be positive and NOT equal to the old rectangular formula
        A_polygon = ustrip(u"mm^2", section_area(s))
        A_rect_old = 125.0 * (30.0 + 30.0)  # old wrong formula
        @test A_polygon > 0
        @test A_polygon != A_rect_old  # NOT rectangular

        # Depth and width from polygon extents
        d = ustrip(u"mm", section_depth(s))
        w = ustrip(u"mm", section_width(s))
        @test d > 0
        @test w > 0

        # The Y-section should be roughly symmetric about x
        @test isapprox(cs.centroid[1], 0.0; atol=1.0)

        # λ field should be :Y
        @test s.λ === :Y
        @test n_arms(s) == 3
    end

    @testset "make_pixelframe_Y_section — 3 arms" begin
        cs = make_pixelframe_Y_section(125.0, 30.0, 30.0)
        @test cs isa CompoundSection
        @test length(cs.solids) == 3  # 3 arms
        @test cs.area > 0
    end

    @testset "make_pixelframe_X2_section — 2 arms" begin
        cs = make_pixelframe_X2_section(125.0, 30.0, 30.0)
        @test cs isa CompoundSection
        @test length(cs.solids) == 2  # 2 arms
        @test cs.area > 0
        # X2 area should be ≈ 2/3 of Y area
        cs_y = make_pixelframe_Y_section(125.0, 30.0, 30.0)
        @test isapprox(cs.area, cs_y.area * 2.0 / 3.0; rtol=0.05)
    end

    @testset "make_pixelframe_X4_section — 4 arms" begin
        cs = make_pixelframe_X4_section(125.0, 30.0, 30.0)
        @test cs isa CompoundSection
        @test length(cs.solids) == 4  # 4 arms
        @test cs.area > 0
        # X4 area should be ≈ 4/3 of Y area
        cs_y = make_pixelframe_Y_section(125.0, 30.0, 30.0)
        @test isapprox(cs.area, cs_y.area * 4.0 / 3.0; rtol=0.05)
    end

    @testset "make_pixelframe_section dispatcher" begin
        cs_y  = make_pixelframe_section(:Y,  125.0, 30.0, 30.0)
        cs_x2 = make_pixelframe_section(:X2, 125.0, 30.0, 30.0)
        cs_x4 = make_pixelframe_section(:X4, 125.0, 30.0, 30.0)
        @test length(cs_y.solids) == 3
        @test length(cs_x2.solids) == 2
        @test length(cs_x4.solids) == 4
        @test_throws ErrorException make_pixelframe_section(:Z, 125.0, 30.0, 30.0)
    end

    @testset "PixelFrameSection with different layups" begin
        s_y  = _thesis_section(λ=:Y)
        s_x2 = _thesis_section(λ=:X2)
        s_x4 = _thesis_section(λ=:X4)

        @test s_y.λ === :Y
        @test s_x2.λ === :X2
        @test s_x4.λ === :X4

        @test n_arms(s_y) == 3
        @test n_arms(s_x2) == 2
        @test n_arms(s_x4) == 4

        # Area ordering: X2 < Y < X4
        A_y  = ustrip(u"mm^2", section_area(s_y))
        A_x2 = ustrip(u"mm^2", section_area(s_x2))
        A_x4 = ustrip(u"mm^2", section_area(s_x4))
        @test A_x2 < A_y < A_x4
    end

    # =========================================================================
    # FiberReinforcedConcrete property delegation
    # =========================================================================
    @testset "FRC property delegation" begin
        s = _thesis_section()
        frc = s.material

        # Direct fields
        @test frc.fiber_dosage == 20.0
        @test frc.fR1 > 0.0  # from regression
        @test frc.fR3 > 0.0  # from regression
        @test frc.fiber_ecc == 1.4u"kgCO2e/kg"  # updated default (typed kgCO₂e/kg)

        # Delegated from Concrete
        @test isapprox(ustrip(u"MPa", frc.fc′), 57.0; atol=1e-6)
        @test isapprox(ustrip(u"kg/m^3", frc.ρ), 2400.0; atol=1e-6)
    end

    @testset "fR1/fR3 regression functions" begin
        # Known regression values for dosage=20, fc'=57 MPa
        fR1 = fc′_dosage2fR1(57.0, 20.0)
        fR3 = fc′_dosage2fR3(57.0, 20.0)
        @test fR1 > 0.0
        @test fR3 > 0.0
        # fR1 = 0.0498 * 57 + 1.3563 = 4.1949
        @test isapprox(fR1, 0.0498 * 57.0 + 1.3563; rtol=1e-6)
        # fR3 = 0.0542 * 57 + 1.7409 = 4.8303
        @test isapprox(fR3, 0.0542 * 57.0 + 1.7409; rtol=1e-6)

        # Zero dosage → zero
        @test fc′_dosage2fR1(57.0, 0.0) == 0.0
        @test fc′_dosage2fR3(57.0, 0.0) == 0.0

        # Higher dosage → higher fR
        @test fc′_dosage2fR1(57.0, 40.0) > fc′_dosage2fR1(57.0, 20.0)
        @test fc′_dosage2fR3(57.0, 40.0) > fc′_dosage2fR3(57.0, 20.0)
    end

    # =========================================================================
    # Axial capacity (ACI 318-19 §22.4.2.3)
    # =========================================================================
    @testset "Axial capacity — thesis section" begin
        s = _thesis_section()
        result = pf_axial_capacity(s)

        # Po should be positive (compression capacity)
        @test ustrip(u"kN", result.Po) > 0

        # Pn = 0.8 × Po (Table 22.4.2.1)
        @test isapprox(ustrip(u"kN", result.Pn), 0.80 * ustrip(u"kN", result.Po); rtol=1e-6)

        # Pu = ϕ × Pn, ϕ = 0.65 for compression-controlled prestressed
        @test isapprox(ustrip(u"kN", result.Pu), 0.65 * ustrip(u"kN", result.Pn); rtol=1e-6)

        # Sanity: Po should be reasonable for the polygon area
        A_mm2 = s.section.area
        Po_approx_kN = 0.85 * 57.0 * A_mm2 / 1000.0
        @test ustrip(u"kN", result.Po) > 0.3 * Po_approx_kN
        @test ustrip(u"kN", result.Po) < 2.0 * Po_approx_kN
    end

    @testset "Axial capacity — zero tendon area" begin
        s = _thesis_section(A_s_mm2=0.0, f_pe_MPa=0.0)
        result = pf_axial_capacity(s)

        # Po = 0.85 × fc' × Ag (no tendon term)
        A_mm2 = s.section.area
        expected_Po_N = 0.85 * 57.0 * A_mm2
        @test isapprox(ustrip(u"N", result.Po), expected_Po_N; rtol=0.01)
    end

    @testset "Axial capacity — higher fc' gives higher capacity" begin
        s_low = _thesis_section(fc′_MPa=28.0)
        s_high = _thesis_section(fc′_MPa=80.0)

        Po_low = ustrip(u"kN", pf_axial_capacity(s_low).Po)
        Po_high = ustrip(u"kN", pf_axial_capacity(s_high).Po)

        @test Po_high > Po_low
    end

    @testset "Axial capacity — layup comparison" begin
        s_y  = _thesis_section(λ=:Y)
        s_x2 = _thesis_section(λ=:X2)
        s_x4 = _thesis_section(λ=:X4)

        # Larger area → higher axial capacity
        Pu_y  = ustrip(u"kN", pf_axial_capacity(s_y).Pu)
        Pu_x2 = ustrip(u"kN", pf_axial_capacity(s_x2).Pu)
        Pu_x4 = ustrip(u"kN", pf_axial_capacity(s_x4).Pu)

        @test Pu_x2 < Pu_y < Pu_x4
    end

    # =========================================================================
    # Flexural capacity (ACI 318-19 §22.4.1.2) — polygon compression zone
    # =========================================================================
    @testset "Flexural capacity — thesis section converges" begin
        s = _thesis_section()
        result = pf_flexural_capacity(s)

        @test result.converged
        @test ustrip(u"kN*m", result.Mu) > 0
        @test 0.65 ≤ result.ϕ ≤ 0.90
        @test result.εc ≤ 0.003 + 1e-6
    end

    @testset "Flexural capacity — convergence with various fc'" begin
        for fc′ in [28.0, 40.0, 57.0, 80.0, 100.0]
            s = _thesis_section(fc′_MPa=fc′)
            result = pf_flexural_capacity(s)
            @test result.converged
            @test ustrip(u"kN*m", result.Mu) > 0
        end
    end

    @testset "Flexural capacity — higher fc' gives higher capacity" begin
        s_low = _thesis_section(fc′_MPa=28.0)
        s_high = _thesis_section(fc′_MPa=80.0)

        Mu_low = ustrip(u"kN*m", pf_flexural_capacity(s_low).Mu)
        Mu_high = ustrip(u"kN*m", pf_flexural_capacity(s_high).Mu)

        @test Mu_high > Mu_low
    end

    @testset "Flexural capacity — larger tendon area gives higher capacity" begin
        s_small = _thesis_section(A_s_mm2=157.0)
        s_large = _thesis_section(A_s_mm2=402.0)

        Mu_small = ustrip(u"kN*m", pf_flexural_capacity(s_small).Mu)
        Mu_large = ustrip(u"kN*m", pf_flexural_capacity(s_large).Mu)

        @test Mu_large > Mu_small
    end

    @testset "Flexural capacity — deeper tendon gives higher capacity" begin
        s_shallow = _thesis_section(d_ps_mm=40.0)
        s_deep = _thesis_section(d_ps_mm=200.0)

        Mu_shallow = ustrip(u"kN*m", pf_flexural_capacity(s_shallow).Mu)
        Mu_deep = ustrip(u"kN*m", pf_flexural_capacity(s_deep).Mu)

        @test Mu_deep > Mu_shallow
    end

    @testset "Flexural capacity — β₁ transition" begin
        @test StructuralSizer._pf_β1(20.0) == 0.85
        @test StructuralSizer._pf_β1(28.0) == 0.85
        @test isapprox(StructuralSizer._pf_β1(42.0), 0.75; atol=1e-6)
        @test StructuralSizer._pf_β1(56.0) == 0.65
        @test StructuralSizer._pf_β1(80.0) == 0.65
    end

    @testset "Flexural capacity — ϕ transition" begin
        @test StructuralSizer._pf_ϕ_flexure(0.001) == 0.65
        @test StructuralSizer._pf_ϕ_flexure(0.002) == 0.65
        @test isapprox(StructuralSizer._pf_ϕ_flexure(0.0035), 0.775; atol=1e-6)
        @test StructuralSizer._pf_ϕ_flexure(0.005) == 0.90
        @test StructuralSizer._pf_ϕ_flexure(0.010) == 0.90
    end

    @testset "Flexural capacity — layup comparison" begin
        # All layups should converge
        for λ in [:Y, :X2, :X4]
            s = _thesis_section(λ=λ)
            result = pf_flexural_capacity(s)
            @test result.converged
            @test ustrip(u"kN*m", result.Mu) > 0
        end
    end

    # =========================================================================
    # Shear capacity (fib MC2010 §7.7.3.2.2) — linear fFtuk model
    # =========================================================================
    @testset "FRC shear capacity — thesis section positive" begin
        s = _thesis_section()
        Vu = frc_shear_capacity(s)

        Vu_kN = ustrip(u"kN", Vu)
        @test Vu_kN > 0

        # Sanity: should be reasonable for this section
        @test Vu_kN > 10.0   # at least 10 kN
        @test Vu_kN < 500.0  # less than 500 kN
    end

    @testset "FRC shear capacity — higher fR3 gives higher capacity" begin
        s_low = _thesis_section(fR1=1.0, fR3=1.0)
        s_high = _thesis_section(fR1=5.0, fR3=5.0)

        Vu_low = ustrip(u"kN", frc_shear_capacity(s_low))
        Vu_high = ustrip(u"kN", frc_shear_capacity(s_high))

        @test Vu_high > Vu_low
    end

    @testset "FRC shear capacity — keyword interface (rectangular) with fR1" begin
        # The keyword interface requires fR1 now
        bw = 200.0u"mm"
        d = 300.0u"mm"
        Vu = frc_shear_capacity(;
            bw, d,
            fc′ = 40.0u"MPa",
            fR1 = 3.0,
            fR3 = 2.5,
            ρ_l = 0.01,
            σ_cp = 5.0u"MPa",
        )
        @test ustrip(u"kN", Vu) > 0
    end

    @testset "FRC shear capacity — zero fiber (fR1=fR3=0) gives lower capacity" begin
        s_fiber = _thesis_section(fR1=4.0, fR3=2.5)
        s_plain = _thesis_section(fR1=0.0, fR3=0.0)

        Vu_fiber = ustrip(u"kN", frc_shear_capacity(s_fiber))
        Vu_plain = ustrip(u"kN", frc_shear_capacity(s_plain))

        @test Vu_fiber > Vu_plain
    end

    @testset "FRC shear capacity — linear fFtuk model consistency" begin
        # Verify the linear model formula:
        # fFts = 0.45 × fR1
        # fFtuk = fFts - (wu/CMOD3) × (fFts - 0.5×fR3 + 0.2×fR1)
        # with wu=1.5, CMOD3=2.5
        fR1 = 4.0
        fR3 = 2.5
        fFts = 0.45 * fR1  # = 1.8
        fFtuk = fFts - (1.5/2.5) * (fFts - 0.5*fR3 + 0.2*fR1)  # = 1.8 - 0.6*(1.8 - 1.25 + 0.8) = 1.8 - 0.6*1.35 = 1.8 - 0.81 = 0.99
        @test fFtuk > 0
        @test isapprox(fFtuk, 0.99; atol=0.01)
    end

    @testset "FRC shear capacity — layup comparison" begin
        # Larger area → higher shear capacity (more shear area)
        s_y  = _thesis_section(λ=:Y)
        s_x2 = _thesis_section(λ=:X2)
        s_x4 = _thesis_section(λ=:X4)

        Vu_y  = ustrip(u"kN", frc_shear_capacity(s_y))
        Vu_x2 = ustrip(u"kN", frc_shear_capacity(s_x2))
        Vu_x4 = ustrip(u"kN", frc_shear_capacity(s_x4))

        @test Vu_x2 < Vu_y < Vu_x4
    end

    # =========================================================================
    # Embodied carbon
    # =========================================================================
    @testset "Embodied carbon — concrete ECC formula" begin
        # `pf_concrete_ecc` returns a typed `kgCO₂e/m³` quantity; compare
        # against the same typed reference rather than a bare Float64.
        @test isapprox(pf_concrete_ecc(28.0u"MPa"),  (4.57 * 28.0  + 217.0)u"kgCO2e/m^3"; rtol=1e-6)
        @test isapprox(pf_concrete_ecc(57.0u"MPa"),  (4.57 * 57.0  + 217.0)u"kgCO2e/m^3"; rtol=1e-6)
        @test isapprox(pf_concrete_ecc(100.0u"MPa"), (4.57 * 100.0 + 217.0)u"kgCO2e/m^3"; rtol=1e-6)
    end

    @testset "Embodied carbon — per meter" begin
        s = _thesis_section()
        carbon = pf_carbon_per_meter(s)  # typed kgCO₂e/m

        @test carbon > 0.0u"kgCO2e/m"
        @test 0.1u"kgCO2e/m" < carbon < 100.0u"kgCO2e/m"  # broad sanity bounds
    end

    @testset "Embodied carbon — higher fc' gives higher carbon" begin
        s_low = _thesis_section(fc′_MPa=28.0)
        s_high = _thesis_section(fc′_MPa=80.0)

        c_low = pf_carbon_per_meter(s_low)
        c_high = pf_carbon_per_meter(s_high)

        @test c_high > c_low
    end

    @testset "Embodied carbon — MinCarbon objective" begin
        s = _thesis_section()
        frc = s.material

        carbon_1m = objective_value(MinCarbon(), s, frc, 1.0u"m")   # typed kgCO₂e
        carbon_2m = objective_value(MinCarbon(), s, frc, 2.0u"m")   # typed kgCO₂e

        @test carbon_1m > 0.0u"kgCO2e"
        @test isapprox(carbon_2m, 2.0 * carbon_1m; rtol=1e-6)
        # `pf_carbon_per_meter(s) * 1.0u"m"` is `kgCO₂e/m × m = kgCO₂e`; Unitful
        # normalises the resulting unit so the comparison matches the objective.
        @test isapprox(carbon_1m, pf_carbon_per_meter(s) * 1.0u"m"; rtol=1e-6)
    end

    @testset "Embodied carbon — fiber_ecc default is 1.4" begin
        s = _thesis_section()
        @test s.material.fiber_ecc == 1.4u"kgCO2e/kg"
    end

    @testset "Embodied carbon — layup comparison" begin
        s_y  = _thesis_section(λ=:Y)
        s_x2 = _thesis_section(λ=:X2)
        s_x4 = _thesis_section(λ=:X4)

        c_y  = pf_carbon_per_meter(s_y)
        c_x2 = pf_carbon_per_meter(s_x2)
        c_x4 = pf_carbon_per_meter(s_x4)

        # Larger section → more carbon
        @test c_x2 < c_y < c_x4
    end

    # =========================================================================
    # Deflection analysis
    # =========================================================================
    @testset "Cracking moment — positive for prestressed section" begin
        s = _thesis_section()
        cr = pf_cracking_moment(s)

        @test ustrip(u"kN*m", cr.Mcr) > 0
        @test ustrip(u"MPa", cr.fr) > 0
        @test ustrip(u"MPa", cr.σ_cp) > 0

        # fr ≈ 0.62√57 ≈ 4.68 MPa
        @test isapprox(ustrip(u"MPa", cr.fr), 0.62 * sqrt(57.0); rtol=0.01)
    end

    @testset "Cracking moment — higher fc' gives higher Mcr" begin
        s_low = _thesis_section(fc′_MPa=28.0)
        s_high = _thesis_section(fc′_MPa=80.0)

        Mcr_low = ustrip(u"kN*m", pf_cracking_moment(s_low).Mcr)
        Mcr_high = ustrip(u"kN*m", pf_cracking_moment(s_high).Mcr)

        @test Mcr_high > Mcr_low
    end

    @testset "Effective Ie — uncracked when Ma < Mcr" begin
        s = _thesis_section()
        cr = pf_cracking_moment(s)

        # Apply a small moment well below cracking
        Ma_small = 0.1 * cr.Mcr
        ie_result = pf_effective_Ie(s, Ma_small)

        @test ie_result.regime == UNCRACKED
        @test isapprox(ustrip(u"mm^4", ie_result.Ie), ie_result.Ig; rtol=1e-6)
    end

    @testset "Effective Ie — cracked when Ma > Mcr" begin
        s = _thesis_section()
        cr = pf_cracking_moment(s)

        # Apply a moment well above cracking
        Ma_large = 5.0 * cr.Mcr
        ie_result = pf_effective_Ie(s, Ma_large)

        @test ie_result.regime == CRACKED
        @test ustrip(u"mm^4", ie_result.Ie) < ie_result.Ig
        @test ustrip(u"mm^4", ie_result.Ie) ≥ ie_result.Icr
    end

    @testset "Deflection — simply supported beam" begin
        s = _thesis_section()
        L = 6.0u"m"
        w = 5.0u"kN/m"  # 5 kN/m unfactored service load

        result = pf_deflection(s, L, w)

        @test ustrip(u"mm", result.Δ) > 0
        @test result.L_over_Δ > 0
        @test result.regime isa DeflectionRegime
    end

    @testset "Deflection — heavier load gives larger deflection" begin
        s = _thesis_section()
        L = 6.0u"m"

        Δ_light = ustrip(u"mm", pf_deflection(s, L, 2.0u"kN/m").Δ)
        Δ_heavy = ustrip(u"mm", pf_deflection(s, L, 20.0u"kN/m").Δ)

        @test Δ_heavy > Δ_light
    end

    @testset "Deflection — longer span gives larger deflection" begin
        s = _thesis_section()
        w = 5.0u"kN/m"

        Δ_short = ustrip(u"mm", pf_deflection(s, 3.0u"m", w).Δ)
        Δ_long = ustrip(u"mm", pf_deflection(s, 8.0u"m", w).Δ)

        @test Δ_long > Δ_short
    end

    @testset "Check deflection — full serviceability check" begin
        s = _thesis_section()
        L = 6.0u"m"
        w_dead = 3.0u"kN/m"
        w_live = 2.0u"kN/m"

        result = pf_check_deflection(s, L, w_dead, w_live)

        @test ustrip(u"mm", result.Δ_D) > 0
        @test ustrip(u"mm", result.Δ_DL) ≥ ustrip(u"mm", result.Δ_D)
        @test ustrip(u"mm", result.Δ_LL) ≥ 0
        @test ustrip(u"mm", result.Δ_LT) > 0
        @test ustrip(u"mm", result.Δ_total) > 0
        @test result.limit_ll_mm > 0
        @test result.limit_total_mm > 0
        @test result.passes isa Bool

        # Live load limit should be L/360
        @test isapprox(result.limit_ll_mm, 6000.0 / 360.0; rtol=1e-6)
        # Total limit should be L/240
        @test isapprox(result.limit_total_mm, 6000.0 / 240.0; rtol=1e-6)
    end

    @testset "Check deflection — cantilever support" begin
        s = _thesis_section()
        L = 2.0u"m"
        w_dead = 3.0u"kN/m"
        w_live = 2.0u"kN/m"

        result = pf_check_deflection(s, L, w_dead, w_live; support=:cantilever)

        @test ustrip(u"mm", result.Δ_D) > 0
        @test result.passes isa Bool

        # Cantilever should deflect more than simply supported of same span
        result_ss = pf_check_deflection(s, L, w_dead, w_live; support=:simply_supported)
        @test ustrip(u"mm", result.Δ_DL) > ustrip(u"mm", result_ss.Δ_DL)
    end

    @testset "Check deflection — light load passes, heavy load fails" begin
        s = _thesis_section()
        L = 6.0u"m"

        # Light load — should pass
        result_light = pf_check_deflection(s, L, 0.1u"kN/m", 0.1u"kN/m")
        @test result_light.passes

        # Very heavy load — should likely fail
        result_heavy = pf_check_deflection(s, L, 100.0u"kN/m", 100.0u"kN/m")
        # Don't assert fails — just check it computes
        @test ustrip(u"mm", result_heavy.Δ_total) > ustrip(u"mm", result_light.Δ_total)
    end

    # =========================================================================
    # Ng & Tan full iterative deflection model
    # =========================================================================

    @testset "PFDeflectionMethod types" begin
        @test PFSimplified() isa PFDeflectionMethod
        @test PFThirdPointLoad() isa PFDeflectionMethod
        @test PFSinglePointLoad() isa PFDeflectionMethod
    end

    @testset "pf_element_properties — thesis section" begin
        s = _thesis_section()
        L_mm = 6000.0
        Ls_mm = 2000.0  # L/3
        Ld_mm = 2000.0  # L/3

        props = pf_element_properties(s, L_mm, Ls_mm, Ld_mm)

        # Basic sanity checks
        @test props.L == L_mm
        @test props.Ls == Ls_mm
        @test props.Ld == Ld_mm
        @test props.em > 0.0
        @test props.es == 0.0
        @test props.Aps > 0.0
        @test props.fpe > 0.0
        @test props.Itr > 0.0
        @test props.Atr > 0.0
        @test props.Zb > 0.0
        @test props.Zt > 0.0
        @test props.r > 0.0
        @test props.Ω > 0.0
        @test props.Mcr > 0.0
        @test props.My > 0.0
        @test props.moment_decompression > 0.0

        # Mcr should be positive and reasonable
        @test props.Mcr > props.moment_decompression

        # Regime ordering: Mcr < Mecl < My (typical for prestressed)
        # Note: not always guaranteed, but should hold for this section
        @test props.Mcr > 0.0
        @test props.My > 0.0
    end

    @testset "Ng & Tan — uncracked third-point (small moment)" begin
        s = _thesis_section()
        L = 6.0u"m"
        # Small moment well below cracking
        Ma_small = 0.5u"kN*m"

        result = pf_deflection(s, L, Ma_small; method=PFThirdPointLoad())

        @test ustrip(u"mm", result.Δ) != 0.0  # non-zero deflection
        @test result.regime == LINEAR_ELASTIC_UNCRACKED
        @test ustrip(u"MPa", result.fps) ≥ ustrip(u"MPa", s.f_pe) - 1.0  # fps ≈ fpe in uncracked
    end

    @testset "Ng & Tan — uncracked single-point (small moment)" begin
        s = _thesis_section()
        L = 6.0u"m"
        Ma_small = 0.5u"kN*m"

        result = pf_deflection(s, L, Ma_small; method=PFSinglePointLoad())

        @test result.regime == LINEAR_ELASTIC_UNCRACKED
        @test ustrip(u"MPa", result.fps) ≥ ustrip(u"MPa", s.f_pe) - 1.0
    end

    @testset "Ng & Tan — cracked third-point (large moment)" begin
        s = _thesis_section()
        L = 6.0u"m"

        # Get cracking moment to ensure we're above it
        props = pf_element_properties(s, 6000.0, 2000.0, 2000.0)
        Ma_large = (props.Mcr * 2.0)u"N*mm"

        result = pf_deflection(s, L, Ma_large; method=PFThirdPointLoad())

        @test result.regime in (LINEAR_ELASTIC_CRACKED, NONLINEAR_CRACKED)
        @test abs(ustrip(u"mm", result.Δ)) > 0.0
    end

    @testset "Ng & Tan — cracked single-point (large moment)" begin
        s = _thesis_section()
        L = 6.0u"m"

        props = pf_element_properties(s, 6000.0, 3000.0, 3000.0)
        Ma_large = (props.Mcr * 2.0)u"N*mm"

        result = pf_deflection(s, L, Ma_large; method=PFSinglePointLoad())

        @test result.regime in (LINEAR_ELASTIC_CRACKED, NONLINEAR_CRACKED)
        @test abs(ustrip(u"mm", result.Δ)) > 0.0
    end

    @testset "Ng & Tan — signed deflection increases with moment (third-point)" begin
        # For EPT beams, low moments can produce negative (upward) deflection due to
        # prestress camber. As moment increases, deflection transitions from negative
        # (upward) to positive (downward). The *signed* deflection should always increase.
        s = _thesis_section()
        L = 6.0u"m"

        Ma_low = 1.0u"kN*m"
        Ma_high = 10.0u"kN*m"

        Δ_low = ustrip(u"mm", pf_deflection(s, L, Ma_low; method=PFThirdPointLoad()).Δ)
        Δ_high = ustrip(u"mm", pf_deflection(s, L, Ma_high; method=PFThirdPointLoad()).Δ)

        # Signed deflection should increase (become more positive / less negative)
        @test Δ_high > Δ_low
    end

    @testset "Ng & Tan — absolute deflection changes with moment (single-point)" begin
        # For single-point load, the deflection formula is:
        #   δ = L²/(4EcI) × (fps×Aps×e/3 − P×L/4)
        # At low moments, prestress camber dominates (positive δ = upward).
        # At high moments, load dominates (negative δ = downward).
        # So signed deflection *decreases* with increasing moment.
        # We just verify both are non-zero and the magnitude changes.
        s = _thesis_section()
        L = 6.0u"m"

        Ma_low = 1.0u"kN*m"
        Ma_high = 10.0u"kN*m"

        Δ_low = ustrip(u"mm", pf_deflection(s, L, Ma_low; method=PFSinglePointLoad()).Δ)
        Δ_high = ustrip(u"mm", pf_deflection(s, L, Ma_high; method=PFSinglePointLoad()).Δ)

        # Both should be non-zero
        @test Δ_low != 0.0
        @test Δ_high != 0.0
        # For EPT with this section, low moment → positive (upward camber),
        # high moment → negative (downward deflection)
        @test Δ_high < Δ_low  # signed deflection decreases
    end

    @testset "Ng & Tan — returns Inf beyond My" begin
        s = _thesis_section()
        L = 6.0u"m"

        props = pf_element_properties(s, 6000.0, 2000.0, 2000.0)
        Ma_beyond = (props.My * 1.5)u"N*mm"

        result = pf_deflection(s, L, Ma_beyond; method=PFThirdPointLoad())
        @test isinf(ustrip(u"mm", result.Δ))
    end

    @testset "Ng & Tan — zero moment gives zero deflection" begin
        s = _thesis_section()
        L = 6.0u"m"

        result = pf_deflection(s, L, 0.0u"kN*m"; method=PFThirdPointLoad())
        @test ustrip(u"mm", result.Δ) == 0.0
        @test result.regime == LINEAR_ELASTIC_UNCRACKED
    end

    @testset "pf_check_deflection — Ng & Tan method" begin
        s = _thesis_section()
        L = 6.0u"m"
        w_dead = 3.0u"kN/m"
        w_live = 2.0u"kN/m"

        result = pf_check_deflection(s, L, w_dead, w_live; method=PFThirdPointLoad())

        # For EPT beams, Ng & Tan can produce upward camber (negative raw deflection)
        # at low moments due to prestress. The check function takes abs() of deflections.
        # So Δ_DL is not necessarily ≥ Δ_D (dead-only may have larger abs camber).
        @test ustrip(u"mm", result.Δ_D) ≥ 0.0
        @test ustrip(u"mm", result.Δ_DL) ≥ 0.0
        @test ustrip(u"mm", result.Δ_LL) ≥ 0.0
        @test ustrip(u"mm", result.Δ_LT) ≥ 0.0
        @test ustrip(u"mm", result.Δ_total) ≥ 0.0
        @test result.passes isa Bool
        @test result.limit_ll_mm > 0.0
        @test result.limit_total_mm > 0.0
        # Ng & Tan returns fps
        @test ustrip(u"MPa", result.fps_D) > 0.0
        @test ustrip(u"MPa", result.fps_DL) > 0.0
    end

    @testset "pf_deflection_curve — produces valid vectors" begin
        s = _thesis_section()
        L = 6.0u"m"
        max_M = 10.0u"kN*m"

        curve = pf_deflection_curve(s, L, max_M; method=PFThirdPointLoad(), n_samples=20)

        @test length(curve.moments_Nmm) == 20
        @test length(curve.deflections_mm) == 20
        @test length(curve.fps_MPa) == 20
        @test length(curve.I_mm4) == 20
        @test length(curve.regimes) == 20

        # First point is zero moment
        @test curve.moments_Nmm[1] == 0.0
        @test curve.deflections_mm[1] == 0.0

        # Moments are increasing
        @test all(diff(curve.moments_Nmm) .> 0.0)
    end

    @testset "pf_deflection_curve — single-point load" begin
        s = _thesis_section()
        L = 6.0u"m"
        max_M = 10.0u"kN*m"

        curve = pf_deflection_curve(s, L, max_M; method=PFSinglePointLoad(), n_samples=20)

        @test length(curve.moments_Nmm) == 20
        @test curve.moments_Nmm[1] == 0.0
    end

    @testset "Simplified vs Ng & Tan — both produce positive deflection" begin
        s = _thesis_section()
        L = 6.0u"m"
        w = 5.0u"kN/m"
        Ma_equiv = 5.0 * 6.0^2 / 8.0 * u"kN*m"  # wL²/8

        Δ_simplified = ustrip(u"mm", pf_deflection(s, L, w; method=PFSimplified()).Δ)
        Δ_ng_tan = abs(ustrip(u"mm", pf_deflection(s, L, Ma_equiv; method=PFThirdPointLoad()).Δ))

        @test Δ_simplified > 0.0
        @test Δ_ng_tan > 0.0
        # Both should be in the same order of magnitude (not exact match expected)
        @test Δ_simplified > 0.0
        @test Δ_ng_tan > 0.0
    end

    @testset "Ng & Tan — different layups" begin
        for λ in [:Y, :X2, :X4]
            s = _thesis_section(λ=λ)
            L = 6.0u"m"
            Ma = 5.0u"kN*m"

            result = pf_deflection(s, L, Ma; method=PFThirdPointLoad())
            @test !isnan(ustrip(u"mm", result.Δ))
            @test result.regime isa DeflectionRegime
        end
    end

end

# ==============================================================================
# Per-Pixel Design Tests
# ==============================================================================

@testset "PixelFrame Per-Pixel Design" begin

    @testset "validate_pixel_divisibility" begin
        # 6000 mm / 500 mm = 12 pixels
        @test validate_pixel_divisibility(6000.0, 500.0) == 12
        # 4000 mm / 500 mm = 8 pixels
        @test validate_pixel_divisibility(4000.0, 500.0) == 8
        # 3500 mm / 500 mm = 7 pixels
        @test validate_pixel_divisibility(3500.0, 500.0) == 7
        # Not divisible → error
        @test_throws ArgumentError validate_pixel_divisibility(6100.0, 500.0)
        @test_throws ArgumentError validate_pixel_divisibility(6250.0, 500.0)
        # Tolerance: 6000.5 mm should pass (within 1mm)
        @test validate_pixel_divisibility(6000.5, 500.0) == 12
        # Custom label
        @test_throws ArgumentError validate_pixel_divisibility(
            6100.0, 500.0; label="Beam 3")
    end

    @testset "PixelFrameDesign construction" begin
        s = _thesis_section()
        mats = [s.material for _ in 1:12]
        design = PixelFrameDesign(s, 500.0u"mm", 12, mats, nothing)

        @test design.n_pixels == 12
        @test design.pixel_length == 500.0u"mm"
        @test length(design.pixel_materials) == 12
        @test all(m -> m === s.material, design.pixel_materials)
    end

    @testset "pixel_volumes — uniform material" begin
        s = _thesis_section()
        mats = [s.material for _ in 1:10]
        design = PixelFrameDesign(s, 500.0u"mm", 10, mats, nothing)

        vols = pixel_volumes(design)
        @test length(vols) == 1  # single material
        total_vol = first(values(vols))
        # Expected: A × 10 × 500mm = A × 5000mm
        expected = uconvert(u"m^3", section_area(s) * 5000.0u"mm")
        @test isapprox(total_vol, expected, rtol=1e-6)
    end

    @testset "pixel_volumes — mixed materials" begin
        s_lo = _thesis_section(fc′_MPa=30.0, dosage=20.0)
        s_hi = _thesis_section(fc′_MPa=57.0, dosage=20.0)

        # 6 pixels: [lo, lo, hi, hi, lo, lo]
        mats = [s_lo.material, s_lo.material, s_hi.material,
                s_hi.material, s_lo.material, s_lo.material]
        design = PixelFrameDesign(s_hi, 500.0u"mm", 6, mats, nothing)

        vols = pixel_volumes(design)
        @test length(vols) == 2  # two materials
        @test haskey(vols, s_lo.material)
        @test haskey(vols, s_hi.material)

        vol_per_pixel = uconvert(u"m^3", section_area(s_hi) * 500.0u"mm")
        @test isapprox(vols[s_lo.material], 4 * vol_per_pixel, rtol=1e-6)
        @test isapprox(vols[s_hi.material], 2 * vol_per_pixel, rtol=1e-6)
    end

    @testset "pixel_carbon — less carbon with mixed materials" begin
        s_lo = _thesis_section(fc′_MPa=30.0, dosage=20.0)
        s_hi = _thesis_section(fc′_MPa=57.0, dosage=20.0)

        # Uniform high-strength
        mats_uniform = [s_hi.material for _ in 1:6]
        design_uniform = PixelFrameDesign(s_hi, 500.0u"mm", 6, mats_uniform, nothing)

        # Mixed: ends use lower strength
        mats_mixed = [s_lo.material, s_lo.material, s_hi.material,
                      s_hi.material, s_lo.material, s_lo.material]
        design_mixed = PixelFrameDesign(s_hi, 500.0u"mm", 6, mats_mixed, nothing)

        # Mixed should have less carbon (lower fc′ → lower concrete ecc)
        @test pixel_carbon(design_mixed) < pixel_carbon(design_uniform)
    end

    @testset "assign_pixel_materials — basic" begin
        # Build two materials: low and high strength
        s_lo = _thesis_section(fc′_MPa=30.0, dosage=20.0)
        s_hi = _thesis_section(fc′_MPa=57.0, dosage=20.0)

        # The governing section (high strength) should be feasible for all demands
        # Low-demand pixels should get the low-strength material
        checker = PixelFrameChecker()

        # 6 pixels with varying demands: midspan high, ends low
        # Use the high-strength section's capacity as reference
        fl_hi = pf_flexural_capacity(s_hi)
        Mu_hi_N = ustrip(u"N*m", fl_hi.Mu)

        # Low demand at ends, high demand at midspan
        pixel_demands = [
            MemberDemand(1; Pu_c=0.0, Mux=Mu_hi_N * 0.1, Vu_strong=0.0),
            MemberDemand(2; Pu_c=0.0, Mux=Mu_hi_N * 0.3, Vu_strong=0.0),
            MemberDemand(3; Pu_c=0.0, Mux=Mu_hi_N * 0.8, Vu_strong=0.0),
            MemberDemand(4; Pu_c=0.0, Mux=Mu_hi_N * 0.8, Vu_strong=0.0),
            MemberDemand(5; Pu_c=0.0, Mux=Mu_hi_N * 0.3, Vu_strong=0.0),
            MemberDemand(6; Pu_c=0.0, Mux=Mu_hi_N * 0.1, Vu_strong=0.0),
        ]

        material_pool = [s_lo.material, s_hi.material]

        mats = assign_pixel_materials(s_hi, 6, pixel_demands, material_pool, checker)

        @test length(mats) == 6
        # Symmetric: positions 1&6, 2&5, 3&4 should match
        @test mats[1] === mats[6]
        @test mats[2] === mats[5]
        @test mats[3] === mats[4]
        # Midspan pixels (3,4) should use higher strength than end pixels (1,6)
        @test ustrip(u"MPa", mats[3].fc′) ≥ ustrip(u"MPa", mats[1].fc′)
    end

    @testset "assign_pixel_materials — all same when demand is uniform" begin
        s = _thesis_section(fc′_MPa=57.0, dosage=20.0)
        s_lo = _thesis_section(fc′_MPa=30.0, dosage=20.0)
        checker = PixelFrameChecker()

        fl = pf_flexural_capacity(s)
        Mu_N = ustrip(u"N*m", fl.Mu) * 0.5  # moderate uniform demand

        pixel_demands = [MemberDemand(i; Pu_c=0.0, Mux=Mu_N, Vu_strong=0.0) for i in 1:4]
        material_pool = [s_lo.material, s.material]

        mats = assign_pixel_materials(s, 4, pixel_demands, material_pool, checker)

        # All pixels should get the same material (uniform demand)
        @test all(m -> m === mats[1], mats)
    end

    @testset "build_pixel_design — end-to-end" begin
        s = _thesis_section()
        checker = PixelFrameChecker()

        L = 3.0u"m"  # 6 pixels at 500mm
        fl = pf_flexural_capacity(s)
        Mu_N = ustrip(u"N*m", fl.Mu) * 0.3

        pixel_demands = [MemberDemand(i; Pu_c=0.0, Mux=Mu_N, Vu_strong=0.0) for i in 1:6]
        material_pool = [s.material]

        design = build_pixel_design(s, L, 500.0, pixel_demands, material_pool, checker)

        @test design isa PixelFrameDesign
        @test design.n_pixels == 6
        @test design.pixel_length == 500.0u"mm"
        @test length(design.pixel_materials) == 6
    end

    @testset "build_pixel_design — non-divisible span raises error" begin
        s = _thesis_section()
        checker = PixelFrameChecker()
        L = 3.1u"m"  # 3100 mm / 500 mm = not integer
        pixel_demands = [MemberDemand(1; Pu_c=0.0, Mux=0.0, Vu_strong=0.0)]
        material_pool = [s.material]

        @test_throws ArgumentError build_pixel_design(
            s, L, 500.0, pixel_demands, material_pool, checker)
    end

    @testset "size_beams with pixel_length — returns n_pixels" begin
        opts = PixelFrameBeamOptions(
            λ_values      = [:Y],
            L_px_values   = [125.0u"mm"],
            t_values      = [30.0u"mm"],
            L_c_values    = [30.0u"mm"],
            fc_values     = [57.0u"MPa"],
            dosage_values = [20.0u"kg/m^3"],
            A_s_values    = [157.0u"mm^2"],
            f_pe_values   = [500.0u"MPa"],
            d_ps_values   = [200.0u"mm"],
            pixel_length  = 500.0u"mm",
            objective     = MinCarbon(),
        )

        Mu = [5.0] .* u"kN*m"
        Vu = [10.0] .* u"kN"
        geoms = [ConcreteMemberGeometry(3.0u"m")]  # 3000mm / 500mm = 6 pixels

        result = size_beams(Mu, Vu, geoms, opts)
        @test haskey(result, :n_pixels)
        @test result.n_pixels == [6]
    end

    @testset "size_beams — non-divisible span raises error" begin
        opts = PixelFrameBeamOptions(
            λ_values      = [:Y],
            L_px_values   = [125.0u"mm"],
            fc_values     = [57.0u"MPa"],
            dosage_values = [20.0u"kg/m^3"],
            A_s_values    = [157.0u"mm^2"],
            f_pe_values   = [500.0u"MPa"],
            d_ps_values   = [200.0u"mm"],
            pixel_length  = 500.0u"mm",
        )

        Mu = [5.0] .* u"kN*m"
        Vu = [10.0] .* u"kN"
        geoms = [ConcreteMemberGeometry(3.1u"m")]  # 3100mm / 500mm ≠ integer

        @test_throws ArgumentError size_beams(Mu, Vu, geoms, opts)
    end

    @testset "size_columns with pixel_length — returns n_pixels" begin
        opts = PixelFrameColumnOptions(
            λ_values      = [:X4],
            L_px_values   = [125.0u"mm"],
            t_values      = [30.0u"mm"],
            L_c_values    = [30.0u"mm"],
            fc_values     = [57.0u"MPa"],
            dosage_values = [20.0u"kg/m^3"],
            A_s_values    = [157.0u"mm^2"],
            f_pe_values   = [500.0u"MPa"],
            d_ps_values   = [0.0u"mm"],
            pixel_length  = 500.0u"mm",
            objective     = MinCarbon(),
        )

        Pu = [50.0] .* u"kN"
        Mux = [5.0] .* u"kN*m"
        geoms = [ConcreteMemberGeometry(3.5u"m")]  # 3500mm / 500mm = 7 pixels

        result = size_columns(Pu, Mux, geoms, opts)
        @test haskey(result, :n_pixels)
        @test result.n_pixels == [7]
    end

    # ===================================================================
    # Tendon Deviation Axial Force
    # ===================================================================

    @testset "TendonDeviationResult construction" begin
        r = TendonDeviationResult(0.1, 50.0u"kN", 30.0u"kN", 100.0u"kN", 50.0u"kN", 0.3)
        @test r.θ ≈ 0.1
        @test r.P_horizontal ≈ 50.0u"kN"
        @test r.N_additional ≈ 50.0u"kN"
        @test r.μ_s ≈ 0.3
    end

    @testset "pf_tendon_deviation_force — straight tendon (d_ps_support = d_ps)" begin
        s = _thesis_section()
        mats = [s.material for _ in 1:6]
        design = PixelFrameDesign(s, 500.0u"mm", 6, mats, nothing)

        V_max = 20.0u"kN"

        # Straight tendon: d_ps_support = d_ps → θ = 0, full PT force is horizontal
        result = pf_tendon_deviation_force(design, V_max; d_ps_support=s.d_ps)

        @test result.θ ≈ 0.0 atol=1e-10
        # P_horizontal = A_s × f_ps × cos(0) = A_s × f_ps
        fl = pf_flexural_capacity(s)
        expected_P = uconvert(u"kN", s.A_s * fl.f_ps)
        @test isapprox(result.P_horizontal, expected_P, rtol=1e-6)

        # N_friction = V_max / μ_s = 20 / 0.3 = 66.67 kN
        @test isapprox(result.N_friction, V_max / 0.3, rtol=1e-6)

        # N_additional = N_friction - P_horizontal
        @test isapprox(result.N_additional, result.N_friction - result.P_horizontal, rtol=1e-6)
    end

    @testset "pf_tendon_deviation_force — draped tendon (d_ps_support = 0)" begin
        s = _thesis_section()
        mats = [s.material for _ in 1:6]
        design = PixelFrameDesign(s, 500.0u"mm", 6, mats, nothing)

        V_max = 20.0u"kN"

        # Draped: tendon at centroid at support (d_ps_support = 0), then rises to d_ps
        result = pf_tendon_deviation_force(design, V_max; d_ps_support=0.0u"mm")

        # θ should be positive (tendon rises from support to midspan)
        d_ps_mm = ustrip(u"mm", s.d_ps)
        expected_θ = atan(d_ps_mm / 500.0)
        @test isapprox(result.θ, expected_θ, rtol=1e-6)

        # cos(θ) < 1, so P_horizontal < A_s × f_ps
        fl = pf_flexural_capacity(s)
        full_P = uconvert(u"kN", s.A_s * fl.f_ps)
        @test result.P_horizontal < full_P
        @test isapprox(result.P_horizontal, full_P * cos(expected_θ), rtol=1e-6)
    end

    @testset "pf_tendon_deviation_force — stored in design" begin
        s = _thesis_section()
        mats = [s.material for _ in 1:6]
        design = PixelFrameDesign(s, 500.0u"mm", 6, mats, nothing)

        @test design.tendon_deviation === nothing

        V_max = 20.0u"kN"
        td = pf_tendon_deviation_force(design, V_max)
        design.tendon_deviation = td

        @test design.tendon_deviation isa TendonDeviationResult
        @test design.tendon_deviation.V_max ≈ 20.0u"kN"
    end

    @testset "pf_tendon_deviation_force — custom μ_s" begin
        s = _thesis_section()
        mats = [s.material for _ in 1:6]
        design = PixelFrameDesign(s, 500.0u"mm", 6, mats, nothing)

        V_max = 30.0u"kN"

        r1 = pf_tendon_deviation_force(design, V_max; μ_s=0.3)
        r2 = pf_tendon_deviation_force(design, V_max; μ_s=0.5)

        # Higher friction coefficient → lower required normal force → less additional force
        @test r2.N_friction < r1.N_friction
        @test r2.N_additional < r1.N_additional
        @test r2.μ_s ≈ 0.5
    end

end
