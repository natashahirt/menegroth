# ==============================================================================
# Tests — Deflection Checks (Steel NLP + RC T-Beam)
# ==============================================================================
# Covers:
#   1. required_Ix_for_deflection  (steel helper)
#   2. Steel W-beam NLP with Ix_min deflection constraint
#   3. cracked_moment_of_inertia_tbeam
#   4. design_tbeam_deflection  (full ACI §24.2 T-beam check)
# ==============================================================================

using Test
using Unitful
using Asap
using StructuralSizer
import JuMP

@testset "Deflection Checks" begin

    # ==================================================================
    # 1. required_Ix_for_deflection (steel beams)
    # ==================================================================
    @testset "required_Ix_for_deflection — basic" begin
        # 25 ft span, 0.8 kip/ft live load, E = 29000 ksi, L/360
        w_LL = 0.8kip/u"ft"
        L    = 25.0u"ft"
        E    = 29000.0ksi

        Ix_req = required_Ix_for_deflection(w_LL, L, E)
        @test Ix_req isa Unitful.Quantity
        @test unit(Ix_req) == u"inch^4"
        # Analytical: 5/384 × 0.8 × 25^4 / (29000 × (25/360))
        # all in kip, ft, then convert
        Ix_val = ustrip(u"inch^4", Ix_req)
        @test Ix_val > 0
        @test 200 < Ix_val < 1200  # sanity range
    end

    @testset "required_Ix_for_deflection — support conditions" begin
        w = 1.0kip/u"ft"; L = 20.0u"ft"; E = 29000.0ksi
        Ix_ss   = required_Ix_for_deflection(w, L, E; support=:simply_supported)
        Ix_cant = required_Ix_for_deflection(w, L, E; support=:cantilever)
        Ix_both = required_Ix_for_deflection(w, L, E; support=:both_ends_continuous)
        # Cantilever needs much more Ix than simply supported
        @test ustrip(u"inch^4", Ix_cant) > ustrip(u"inch^4", Ix_ss)
        # Both-ends continuous needs less than simply supported
        @test ustrip(u"inch^4", Ix_both) < ustrip(u"inch^4", Ix_ss)
    end

    @testset "required_Ix_for_deflection — limit_ratio" begin
        w = 0.5kip/u"ft"; L = 30.0u"ft"; E = 29000.0ksi
        Ix_360 = required_Ix_for_deflection(w, L, E; limit_ratio=1/360)
        Ix_240 = required_Ix_for_deflection(w, L, E; limit_ratio=1/240)
        # Tighter limit → larger required Ix
        @test ustrip(u"inch^4", Ix_360) > ustrip(u"inch^4", Ix_240)
    end

    # ==================================================================
    # 2. Steel W-beam NLP with Ix_min
    # ==================================================================
    @testset "Steel W-beam NLP with deflection constraint" begin
        Mu = 200.0kip*u"ft"
        Vu = 40.0kip
        geom = SteelMemberGeometry(25.0u"ft"; Lb=25.0u"ft", Cb=1.0)
        opts = NLPWOptions(
            min_depth = 12.0u"inch", max_depth = 36.0u"inch",
        )

        # Without deflection constraint
        r_no = size_steel_w_beam_nlp(Mu, Vu, geom, opts)
        @test r_no.status in (:converged, :optimal)

        # Require a large Ix — should push the solver to a deeper section
        Ix_big = 1200.0u"inch^4"
        r_defl = size_steel_w_beam_nlp(Mu, Vu, geom, opts; Ix_min=Ix_big)
        @test r_defl.status in (:converged, :optimal)

        # The deflection-constrained result should have >= required Ix
        @test r_defl.Ix >= ustrip(u"inch^4", Ix_big) * 0.95  # within 5% tolerance
    end

    # ==================================================================
    # 3. cracked_moment_of_inertia_tbeam
    # ==================================================================
    @testset "cracked_moment_of_inertia_tbeam — NA in flange" begin
        # Wide flange, small steel → NA stays in flange
        As = 2.0u"inch^2"
        bw = 12.0u"inch"; bf = 48.0u"inch"; hf = 6.0u"inch"
        d  = 18.0u"inch"
        fc′ = 4000.0u"psi"
        Ec_val = 57000 * sqrt(4000.0) * u"psi"
        Es_val = 29000.0ksi

        Icr = cracked_moment_of_inertia_tbeam(As, bw, bf, hf, d, Ec_val, Es_val)
        @test Icr isa Unitful.Quantity
        @test unit(Icr) == u"inch^4"
        Icr_val = ustrip(u"inch^4", Icr)

        # Compare to rectangular beam with width bf (should be same when NA in flange)
        Icr_rect = cracked_moment_of_inertia(As, bf, d, Ec_val, Es_val)
        @test isapprox(Icr_val, ustrip(u"inch^4", Icr_rect); rtol=0.001)
    end

    @testset "cracked_moment_of_inertia_tbeam — NA in web" begin
        # Narrow flange, more steel → NA drops into web
        As = 6.0u"inch^2"
        bw = 14.0u"inch"; bf = 30.0u"inch"; hf = 5.0u"inch"
        d  = 22.0u"inch"
        fc′ = 4000.0u"psi"
        Ec_val = 57000 * sqrt(4000.0) * u"psi"
        Es_val = 29000.0ksi

        Icr = cracked_moment_of_inertia_tbeam(As, bw, bf, hf, d, Ec_val, Es_val)
        Icr_val = ustrip(u"inch^4", Icr)

        # Icr_tbeam > rectangular Icr with web width only (flange adds stiffness)
        Icr_web_only = cracked_moment_of_inertia(As, bw, d, Ec_val, Es_val)
        @test Icr_val > ustrip(u"inch^4", Icr_web_only)

        # Sanity range
        @test 2000 < Icr_val < 20000
    end

    @testset "cracked_moment_of_inertia_tbeam — degenerate to rectangular" begin
        # When bf == bw, T-beam reduces to rectangular
        As = 4.0u"inch^2"
        b  = 14.0u"inch"; hf = 20.0u"inch"  # hf == h, so always NA in flange
        d  = 17.5u"inch"; h = 20.0u"inch"
        Ec_val = 57000 * sqrt(4000.0) * u"psi"
        Es_val = 29000.0ksi

        Icr_t = cracked_moment_of_inertia_tbeam(As, b, b, hf, d, Ec_val, Es_val)
        Icr_r = cracked_moment_of_inertia(As, b, d, Ec_val, Es_val)
        @test isapprox(ustrip(u"inch^4", Icr_t), ustrip(u"inch^4", Icr_r); rtol=0.001)
    end

    # ==================================================================
    # 4. design_tbeam_deflection
    # ==================================================================
    @testset "design_tbeam_deflection — simply supported" begin
        bw = 14.0u"inch"; bf = 48.0u"inch"; hf = 6.0u"inch"
        h  = 24.0u"inch"; d  = 21.5u"inch"
        As = 4.0u"inch^2"
        fc′ = 4.0ksi; fy = 60.0ksi; Es = 29000.0ksi
        L  = 25.0u"ft"
        w_dead = 1.2kip/u"ft"
        w_live = 0.8kip/u"ft"

        result = design_tbeam_deflection(
            bw, bf, hf, h, d, As,
            fc′, fy, Es, L, w_dead, w_live;
            support = :simply_supported,
        )

        # Structural fields exist
        @test hasproperty(result, :Ig)
        @test hasproperty(result, :Icr)
        @test hasproperty(result, :Mcr)
        @test hasproperty(result, :Ie_D)
        @test hasproperty(result, :Ie_DL)
        @test hasproperty(result, :Δ_LL)
        @test hasproperty(result, :Δ_total)
        @test hasproperty(result, :ok)
        @test hasproperty(result, :ȳ)
        @test hasproperty(result, :yb)

        # T-beam Ig should be larger than rectangular with bw
        Ig_rect_web = bw * h^3 / 12
        @test result.Ig > Ig_rect_web

        # Centroid should be above mid-depth for a T (flange shifts it up)
        @test result.ȳ < h / 2

        # Deflections should be positive
        @test ustrip(u"inch", result.Δ_LL) > 0
        @test ustrip(u"inch", result.Δ_total) > 0

        # Live load deflection less than total
        @test ustrip(u"inch", result.Δ_LL) < ustrip(u"inch", result.Δ_total)
    end

    @testset "design_tbeam_deflection — passes for typical beam" begin
        bw = 14.0u"inch"; bf = 48.0u"inch"; hf = 7.0u"inch"
        h  = 28.0u"inch"; d  = 25.5u"inch"
        As = 5.0u"inch^2"
        fc′ = 4.0ksi; fy = 60.0ksi; Es = 29000.0ksi
        L  = 24.0u"ft"
        w_dead = 1.0kip/u"ft"
        w_live = 0.6kip/u"ft"

        result = design_tbeam_deflection(
            bw, bf, hf, h, d, As,
            fc′, fy, Es, L, w_dead, w_live;
        )
        # A well-designed 28" deep T-beam on 24' should pass
        @test result.ok == true
    end

    @testset "design_tbeam_deflection — vs rectangular comparison" begin
        # Same overall dimensions; T-beam should deflect less (higher Ig/Icr)
        bw = 14.0u"inch"; bf = 48.0u"inch"; hf = 6.0u"inch"
        h  = 24.0u"inch"; d  = 21.5u"inch"
        As = 4.0u"inch^2"
        fc′ = 4.0ksi; fy = 60.0ksi; Es = 29000.0ksi
        L  = 25.0u"ft"
        w_dead = 1.2kip/u"ft"; w_live = 0.8kip/u"ft"

        t_result = design_tbeam_deflection(
            bw, bf, hf, h, d, As,
            fc′, fy, Es, L, w_dead, w_live,
        )
        r_result = design_beam_deflection(
            bw, h, d, As,
            fc′, fy, Es, L, w_dead, w_live,
        )

        # T-beam should have higher Ig (flange contribution)
        @test t_result.Ig > r_result.Ig
        # T-beam should have higher Icr
        @test t_result.Icr > r_result.Icr
        # T-beam should deflect less under live load
        @test ustrip(u"inch", t_result.Δ_LL) < ustrip(u"inch", r_result.Δ_LL)
    end

    @testset "design_tbeam_deflection — long-term factor" begin
        bw = 12.0u"inch"; bf = 36.0u"inch"; hf = 5.0u"inch"
        h  = 20.0u"inch"; d  = 17.5u"inch"
        As = 3.0u"inch^2"
        fc′ = 4.0ksi; fy = 60.0ksi; Es = 29000.0ksi
        L  = 20.0u"ft"
        w_dead = 0.8kip/u"ft"; w_live = 0.5kip/u"ft"

        # No compression steel → λΔ = 2.0 / (1+0) = 2.0
        r1 = design_tbeam_deflection(bw, bf, hf, h, d, As,
            fc′, fy, Es, L, w_dead, w_live; ξ=2.0)
        @test isapprox(r1.λΔ, 2.0; atol=1e-6)

        # With compression steel → smaller λΔ
        As_prime = 1.5u"inch^2"
        r2 = design_tbeam_deflection(bw, bf, hf, h, d, As,
            fc′, fy, Es, L, w_dead, w_live; ξ=2.0, As_prime=As_prime)
        @test r2.λΔ < r1.λΔ
        @test r2.Δ_total < r1.Δ_total
    end

    @testset "design_tbeam_deflection — degenerate bf==bw matches rectangular" begin
        b = 14.0u"inch"; hf = 24.0u"inch"  # hf == h → whole section is "flange"
        h = 24.0u"inch"; d = 21.5u"inch"
        As = 4.0u"inch^2"
        fc′ = 4.0ksi; fy = 60.0ksi; Es = 29000.0ksi
        L = 25.0u"ft"
        w_dead = 1.0kip/u"ft"; w_live = 0.6kip/u"ft"

        t_res = design_tbeam_deflection(b, b, hf, h, d, As,
            fc′, fy, Es, L, w_dead, w_live)
        r_res = design_beam_deflection(b, h, d, As,
            fc′, fy, Es, L, w_dead, w_live)

        @test isapprox(ustrip(u"inch^4", t_res.Ig), ustrip(u"inch^4", r_res.Ig); rtol=0.01)
        @test isapprox(ustrip(u"inch^4", t_res.Icr), ustrip(u"inch^4", r_res.Icr); rtol=0.01)
        @test isapprox(ustrip(u"inch", t_res.Δ_LL), ustrip(u"inch", r_res.Δ_LL); rtol=0.02)
    end

    # ==================================================================
    # 5. RC T-Beam NLP with auto-integrated deflection constraint
    # ==================================================================
    @testset "T-beam NLP with deflection constraint" begin
        Mu = 250.0kip*u"ft"
        Vu = 50.0kip
        bf = 48.0u"inch"
        hf = 6.0u"inch"
        L  = 25.0u"ft"
        w_dead = 1.2kip/u"ft"
        w_live = 0.8kip/u"ft"
        opts = NLPBeamOptions(min_depth=16.0u"inch", max_depth=30.0u"inch")

        # ── Without deflection constraint ──
        r_no = size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts)
        @test r_no.status in (:converged, :optimal)

        # ── With deflection constraint ──
        r_defl = size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts;
            w_dead=w_dead, w_live=w_live, L_span=L,
            defl_support=:simply_supported,
        )
        @test r_defl.status in (:converged, :optimal)

        # Deflection-constrained beam should be at least as heavy as unconstrained
        @test r_defl.area_web >= r_no.area_web * 0.95  # allow 5% numerical tolerance

        # Verify the resulting section actually passes deflection
        sec = r_defl.section
        fc′ = 4.0ksi; fy = 60.0ksi; Es = 29000.0ksi
        defl_check = design_tbeam_deflection(
            sec.bw, sec.bf, sec.hf, sec.h, sec.d, sec.As,
            fc′, fy, Es, L, w_dead, w_live;
            support = :simply_supported,
        )
        @test defl_check.ok == true
    end

    @testset "T-beam NLP deflection — severe demand forces deeper beam" begin
        # Heavy live load on long span → deflection governs, not strength
        Mu = 150.0kip*u"ft"  # moderate moment
        Vu = 30.0kip
        bf = 60.0u"inch"
        hf = 5.0u"inch"
        L  = 30.0u"ft"
        w_dead = 0.8kip/u"ft"
        w_live = 1.5kip/u"ft"   # heavy live load
        opts = NLPBeamOptions(min_depth=14.0u"inch", max_depth=36.0u"inch")

        r_str = size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts)
        r_def = size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts;
            w_dead=w_dead, w_live=w_live, L_span=L,
        )
        @test r_str.status in (:converged, :optimal)
        @test r_def.status in (:converged, :optimal)

        # When deflection is severe, the constrained beam should be noticeably deeper
        @test r_def.h_final >= r_str.h_final
    end

    # ==================================================================
    # 6. RC T-Beam MIP with auto-integrated deflection constraint
    # ==================================================================
    @testset "T-beam MIP with deflection constraint" begin
        n = 2
        Mu = [200.0, 300.0] .* kip*u"ft"
        Vu = [40.0, 60.0] .* kip
        L_span = 25.0u"ft"
        geoms = [ConcreteMemberGeometry(L_span) for _ in 1:n]
        opts  = ConcreteBeamOptions()
        bf = 48.0u"inch"; hf = 6.0u"inch"
        w_dead = 1.0kip/u"ft"
        w_live = 0.8kip/u"ft"

        # Without deflection
        r_no = size_tbeams(Mu, Vu, geoms, opts;
            flange_width=bf, flange_thickness=hf)

        # With deflection
        r_def = size_tbeams(Mu, Vu, geoms, opts;
            flange_width=bf, flange_thickness=hf,
            w_dead=w_dead, w_live=w_live,
            defl_support=:simply_supported,
        )

        @test r_no.status == JuMP.MOI.OPTIMAL
        @test r_def.status == JuMP.MOI.OPTIMAL

        # Deflection-constrained MIP should pick sections at least as heavy
        for i in 1:n
            sec_no  = r_no.sections[i]
            sec_def = r_def.sections[i]
            # Area comparison (bw × h for web)
            area_no  = ustrip(u"inch^2", sec_no.bw * sec_no.h)
            area_def = ustrip(u"inch^2", sec_def.bw * sec_def.h)
            @test area_def >= area_no * 0.90  # allow some tolerance for MIP discrete jumps
        end

        # Verify each assigned section passes deflection
        for i in 1:n
            sec = r_def.sections[i]
            fc′ = 4.0ksi; fy = 60.0ksi; Es = 29000.0ksi
            check = design_tbeam_deflection(
                sec.bw, sec.bf, sec.hf, sec.h, sec.d, sec.As,
                fc′, fy, Es, L_span, w_dead, w_live;
            )
            @test check.ok == true
        end
    end

end  # top-level testset

println("\n✅ All deflection tests passed!")
