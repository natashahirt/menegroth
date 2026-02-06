using StructuralSizer
# Units are re-exported from StructuralSizer (via Asap)
using Unitful
using Test

@testset "HSS / PIPE catalogue + AISC capacities" begin

    @testset "Catalogue loaders" begin
        # Just verify we can load a known rectangular HSS and a known pipe.
        hss = HSS("HSS20X20X3/4")
        pipe = PIPE("Pipe8STD")  # Alias for HSSRound(...)

        @test hss isa HSSRectSection
        @test pipe isa HSSRoundSection

        # Basic sanity on dimensions / derived geometry
        @test hss.H > 0u"m"
        @test hss.B > 0u"m"
        @test hss.t > 0u"m"
        @test hss.h ≈ (hss.H - 3hss.t)
        @test hss.b ≈ (hss.B - 3hss.t)
        @test hss.λ_f ≈ ustrip(hss.b / hss.t)
        @test hss.λ_w ≈ ustrip(hss.h / hss.t)

        @test pipe.OD > 0u"m"
        @test pipe.t > 0u"m"
        # Catalogue ID may not exactly equal OD - 2*tdes due to catalog rounding / basis differences.
        @test isapprox(pipe.ID, pipe.OD - 2pipe.t; atol=5e-3u"m")
        @test pipe.D_t ≈ ustrip(pipe.OD / pipe.t)
    end

    @testset "AISC capacities compile (conservative hollow impl)" begin
        hss = HSS("HSS20X12X1/2")
        pipe = PIPE("Pipe8STD")

        mat = A992_Steel
        L = 3.0u"m"

        # Flexure
        @test get_ϕMn(hss, mat; axis=:strong) > 0u"N*m"
        @test get_ϕMn(hss, mat; axis=:weak) > 0u"N*m"
        @test get_ϕMn(pipe, mat; axis=:strong) > 0u"N*m"

        # Slenderness classification dispatch exists
        sl_hss = get_slenderness(hss, mat)
        @test sl_hss.class_f in (:compact, :noncompact, :slender)
        @test sl_hss.class_w in (:compact, :noncompact, :slender)
        sl_pipe = get_slenderness(pipe, mat)
        @test sl_pipe.class in (:compact, :noncompact, :slender)

        # Shear
        @test get_ϕVn(hss, mat; axis=:strong) > 0u"N"
        @test get_ϕVn(pipe, mat; axis=:strong) > 0u"N"

        # Compression
        @test get_ϕPn(hss, mat, L; axis=:strong) > 0u"N"
        @test get_ϕPn(hss, mat, L; axis=:weak) > 0u"N"
        @test get_ϕPn(pipe, mat, L; axis=:strong) > 0u"N"

        # Tension (shared for any AbstractSection)
        @test StructuralSizer.get_ϕPn_tension(hss, mat) > 0u"N"
        @test StructuralSizer.get_ϕPn_tension(pipe, mat) > 0u"N"
    end

    @testset "AISCChecker works on HSS/PIPE catalogues (no ISymm hardcode)" begin
        chk = AISCChecker()
        mat = A992_Steel

        hss = HSS("HSS20X20X3/4")
        pipe = PIPE("Pipe8STD")
        catalogue = [hss, pipe]

        dem = MemberDemand(1; Pu_c=100e3u"N", Pu_t=0.0u"N", Mux=10e3u"N*m", Muy=0.0u"N*m",
                           Vu_strong=0.0u"N", Vu_weak=0.0u"N", δ_max=0.0u"m", I_ref=1.0u"m^4")
        geo = SteelMemberGeometry(3.0; Lb=3.0, Kx=1.0, Ky=1.0, Cb=1.0)

        cache = create_cache(chk, length(catalogue))
        precompute_capacities!(chk, cache, catalogue, mat, MinWeight())

        @test is_feasible(chk, cache, 1, hss, mat, dem, geo) isa Bool
        @test is_feasible(chk, cache, 2, pipe, mat, dem, geo) isa Bool
    end

    @testset "HSS chapter logic branches (equation-based sanity)" begin
        mat = A992_Steel

        # -------------------------
        # Rectangular HSS flexure (F7)
        # -------------------------
        @testset "Rect HSS flexure branches" begin
            # Compact example from catalogue
            sC = HSS("HSS20X20X3/4")
            slC = get_slenderness(sC, mat)
            @test slC.class_f == :compact
            @test slC.class_w == :compact

            MnC = get_Mn(sC, mat; axis=:strong)
            @test MnC == mat.Fy * sC.Zx

            # Noncompact example (synthetic geometry chosen so b/t is between λp and λr)
            # λ = (B - 3t)/t = B/t - 3
            # For A992: λp_f ≈ 1.12√(E/Fy) ≈ 27, λr_f ≈ 1.40√(E/Fy) ≈ 34
            # Choose B/t ≈ 33 ⇒ λ ≈ 30 (noncompact).
            sNC = HSSRectSection(0.30u"m", 0.30u"m", 0.00909u"m")
            slNC = get_slenderness(sNC, mat)
            @test slNC.class_f == :noncompact

            Mp = mat.Fy * sNC.Zx
            My = mat.Fy * sNC.Sx
            Mn_expected = Mp + (My - Mp) * ((slNC.λ_f - slNC.λp_f) / (slNC.λr_f - slNC.λp_f))
            Mn = get_Mn(sNC, mat; axis=:strong)
            @test isapprox(Mn, Mn_expected; rtol=1e-10)
            @test My <= Mn <= Mp
        end

        # -------------------------
        # Rectangular HSS shear (G4)
        # -------------------------
        @testset "Rect HSS shear (G4) matches Cv2 branches" begin
            s = HSSRectSection(0.30u"m", 0.30u"m", 0.002u"m") # very thin → shear buckling likely
            E, Fy = mat.E, mat.Fy
            h = s.h
            t = s.t
            w = ustrip(h / t)
            kv = 5.0

            lim1 = 1.10 * sqrt(kv * E / Fy)
            lim2 = 1.37 * sqrt(kv * E / Fy)
            Cv2 = if w <= lim1
                1.0
            elseif w <= lim2
                1.10 * sqrt(kv * E / Fy) / w
            else
                1.51 * kv * E / (Fy * w^2)
            end

            Aw = 2 * h * t
            Vn_expected = 0.6 * Fy * Aw * Cv2

            Vn = get_Vn(s, mat; axis=:strong, kv=kv)
            @test isapprox(Vn, Vn_expected; rtol=1e-10)
        end

        # -------------------------
        # Rectangular HSS compression (E3 + E7 effective width)
        # -------------------------
        @testset "Rect HSS compression reduces area when slender" begin
            s = HSSRectSection(0.30u"m", 0.30u"m", 0.002u"m")  # Very slender (b/t ≈ 147)
            L = 3.0u"m"

            lim = StructuralSizer.get_compression_limits(s, mat)
            @test max(lim.λ_f, lim.λ_w) > lim.λr  # Confirm slender
            
            # E7 effective area reduces capacity compared to gross area
            # For slender sections, Pn with effective area < Pn with gross area
            r = s.ry
            Fe = π^2 * mat.E / (L / r)^2
            ratio = mat.Fy / Fe
            Fcr = ratio <= 2.25 ? (0.658^ratio) * mat.Fy : 0.877 * Fe
            Pn_gross = Fcr * s.A  # Would get if no local buckling
            
            Pn = get_Pn(s, mat, L; axis=:weak)
            @test Pn < Pn_gross  # Effective area reduces capacity
            @test Pn > 0u"N"     # But capacity is still positive
            
            # Verify E7 effective width formula is applied
            # For this very slender section, reduction should be significant (< 80% of gross)
            @test Pn / Pn_gross < 0.8
        end

        # -------------------------
        # Round HSS / Pipe (F8, G5, E7.2 area)
        # -------------------------
        @testset "Round HSS branches" begin
            # Pipe shear (G5) – ordinary length assumption (Fcr=0.6Fy) is what we implement
            pipe = PIPE("Pipe8STD")
            ϕVn = get_ϕVn(pipe, mat)
            ϕVn_expected = 0.9 * (0.6 * mat.Fy) * pipe.A / 2
            @test isapprox(ϕVn, ϕVn_expected; rtol=1e-12)

            # Slender round flexure (F8-3) + compression Ae reduction (E7-7 style)
            s = HSSRoundSection(0.50u"m", 0.002u"m")  # D/t = 250 → slender for A992
            sl = get_slenderness(s, mat)
            @test sl.class == :slender

            Fcr_flex = min(0.33 * mat.E / sl.λ, mat.Fy)
            Mn_expected = Fcr_flex * s.S
            Mn = get_Mn(s, mat)
            @test isapprox(Mn, Mn_expected; rtol=1e-12)

            # Compression: Ae reduced when D/t exceeds 0.11(E/Fy)
            Dt_limit = 0.11 * (mat.E / mat.Fy)
            @test s.D_t > Dt_limit
            Ae_expected = s.A * (2/3 + (0.038 * (mat.E / mat.Fy)) / s.D_t)
            Ae_expected = clamp(Ae_expected, zero(Ae_expected), s.A)
            L = 3.0u"m"
            Fe = π^2 * mat.E / (L / s.r)^2
            ratio = mat.Fy / Fe
            Fcr = ratio <= 2.25 ? (0.658^ratio) * mat.Fy : 0.877 * Fe
            Pn_expected = Fcr * Ae_expected

            Pn = get_Pn(s, mat, L)
            @test isapprox(Pn, Pn_expected; rtol=1e-10)
        end
    end
end

