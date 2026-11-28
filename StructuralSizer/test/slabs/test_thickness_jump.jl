# One analysis is scaled onto the half-inch grid. The sizing loop confirms it.

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

function _jump_analysis(; h, sdl, qL, γ, l1, l2, ln,
                        moment = 1.0kip * u"ft", shear = 1.0kip,
                        fea = nothing, pattern = false)
    sw = SS.slab_self_weight(h, γ)
    qD = uconvert(psf, sdl + sw)
    qu = SS.governing_uniform_pressure(qD, qL)
    M = uconvert(kip * u"ft", moment)
    return MomentAnalysisResult(
        M, M, M, M,
        qu, qD, uconvert(psf, qL),
        uconvert(u"ft", l1), uconvert(u"ft", l2), uconvert(u"ft", ln),
        uconvert(u"ft", 16.0u"inch"),
        [M], [uconvert(kip, shear)], [0.0kip * u"ft"],
        uconvert(kip, qu * l2 * ln / 2);
        fea_Δ_panel = fea,
        pattern_loading = pattern,
    )
end

function _depth_passes(result, secondary, h, γ, fc, fy, Es, Ecs, columns, spans)
    d = effective_depth(h; cover = 0.75u"inch", bar_diameter = 0.5u"inch")
    return SS.phase_a_depth_passes(
        result, secondary, h, d, fc, fy, Es, Ecs, spans, γ, columns; λ = 1.0)
end

@testset "Slab thickness jump" begin
    γ = 150.0pcf
    fc = 4000u"psi"
    fy = 60u"ksi"
    Es = 29000u"ksi"
    Ecs = Ec(fc, 150.0)
    columns = [(c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)]
    inc = 0.5u"inch"

    @testset "self-weight split and gross-plate scale" begin
        # 6 in of 150 pcf is 75 psf. Doubling the thickness adds another 75 psf.
        # qD(6) = 125 + 75 = 200 psf, qL = 100 psf.
        # qu(6) = max(1.2·200 + 1.6·100, 1.4·200) = max(400, 280) = 400 psf.
        # qu(12) = max(1.2·275 + 160, 1.4·275) = max(490, 385) = 490 psf.
        h0 = 6.0u"inch"
        h = 12.0u"inch"
        sdl = 125.0psf
        qL = 100.0psf
        sw0 = SS.slab_self_weight(h0, γ)
        @test ustrip(psf, sw0) ≈ 75 rtol = 1e-6
        qD0 = sdl + sw0
        loads = SS.loads_at_thickness(qD0, qL, h0, h, γ)
        @test ustrip(psf, loads.qD) ≈ 275 rtol = 1e-6
        @test ustrip(psf, loads.qu) ≈ 490 rtol = 1e-6
        qu0 = SS.governing_uniform_pressure(qD0, qL)
        @test ustrip(psf, qu0) ≈ 400 rtol = 1e-6
        r = ustrip(loads.qu / qu0)
        @test r ≈ 1.225 rtol = 1e-9
        analyzed = _jump_analysis(; h = h0, sdl = sdl, qL = qL, γ = γ,
                                  l1 = 20.0u"ft", l2 = 20.0u"ft", ln = 18.0u"ft",
                                  moment = 40.0kip * u"ft", fea = 0.80u"inch")
        dscale = r * (6 / 12)^3
        scaled = SS.scale_moment_result(analyzed, r, dscale, loads.qD, loads.qu)
        @test ustrip(kip * u"ft", scaled.M_pos) ≈ 40 * 1.225 rtol = 1e-9
        @test ustrip(u"inch", scaled.fea_Δ_panel) ≈ 0.80 * 1.225 * (0.5)^3 rtol = 1e-9
        @test scaled.pattern_loading == false
    end

    @testset "one step when the scale does not apply" begin
        h0 = 6.0u"inch"
        analyzed = _jump_analysis(; h = h0, sdl = 20.0psf, qL = 50.0psf, γ = γ,
                                  l1 = 20.0u"ft", l2 = 20.0u"ft", ln = 18.0u"ft",
                                  pattern = true)
        refused = (hh, scaled_p, scaled_s) -> error("pattern loading must not be scaled")
        stepped = SS.propose_slab_thickness(
            h0, inc, 30.0u"inch", analyzed, nothing, γ; passes = refused)
        @test ustrip(u"inch", stepped) ≈ 6.5
        dropped = SS.propose_slab_thickness(
            h0, inc, 30.0u"inch", analyzed, nothing, γ;
            drop_panel = :present, passes = refused)
        @test ustrip(u"inch", dropped) ≈ 6.5
        stiff = SS.propose_slab_thickness(
            h0, inc, 30.0u"inch", analyzed, nothing, γ;
            stiffness_depends_on_h = true, passes = refused)
        @test ustrip(u"inch", stiff) ≈ 6.5
    end

    @testset "shear failure jumps past the next half-inch" begin
        # High uniform load on a 20 ft span. Moments stay at 1 kip·ft so
        # flexure, transfer, and deflection are not the constraint.
        h0 = 6.0u"inch"
        l1 = 20.0u"ft"
        l2 = 10.0u"ft"
        ln = 20.0u"ft"
        sdl = 800.0psf
        qL = 100.0psf
        spans = (primary = l1, secondary = l2)
        analyzed = _jump_analysis(; h = h0, sdl = sdl, qL = qL, γ = γ,
                                  l1 = l1, l2 = l2, ln = ln)
        d0 = effective_depth(h0; cover = 0.75u"inch", bar_diameter = 0.5u"inch")
        @test !SS.check_one_way_shear(analyzed, d0, fc; h = h0, fy = 60.0u"ksi").ok
        h_max = 40.0u"inch"
        proposed = SS.propose_slab_thickness(
            h0, inc, h_max, analyzed, nothing, γ;
            passes = (hh, scaled_p, scaled_s) ->
                _depth_passes(scaled_p, scaled_s, hh, γ, fc, fy, Es, Ecs, columns, spans))
        @test ustrip(u"inch", proposed) > 6.5
        @test ustrip(u"inch", proposed) % 0.5 ≈ 0 atol = 1e-9

        # Independent scan of the same checks. The jump is that scan's first pass.
        qu0 = SS.governing_uniform_pressure(analyzed.qD, analyzed.qL)
        expected = nothing
        candidate = 6.5u"inch"
        while candidate <= h_max
            loads = SS.loads_at_thickness(analyzed.qD, analyzed.qL, h0, candidate, γ)
            r = ustrip(loads.qu / qu0)
            scaled = SS.scale_moment_result(analyzed, r, r * ustrip((h0 / candidate)^3),
                                            loads.qD, loads.qu)
            if _depth_passes(scaled, nothing, candidate, γ, fc, fy, Es, Ecs, columns, spans)
                expected = candidate
                break
            end
            candidate += inc
        end
        @test expected !== nothing
        @test proposed ≈ expected

        thinner = proposed - inc
        loads_thin = SS.loads_at_thickness(analyzed.qD, analyzed.qL, h0, thinner, γ)
        r_thin = ustrip(loads_thin.qu / qu0)
        scaled_thin = SS.scale_moment_result(
            analyzed, r_thin, r_thin * ustrip((h0 / thinner)^3),
            loads_thin.qD, loads_thin.qu)
        @test !_depth_passes(scaled_thin, nothing, thinner, γ, fc, fy, Es, Ecs, columns, spans)

        # Hand shear at the jumped depth: Vu = qu·ℓ2·(ℓn/2 − d), Vc from ACI 318-19
        # Table 22.5.5.1(c). The 1 kip·ft moments leave ρw at the 0.0018 h floor.
        d = effective_depth(proposed; cover = 0.75u"inch", bar_diameter = 0.5u"inch")
        loads_h = SS.loads_at_thickness(analyzed.qD, analyzed.qL, h0, proposed, γ)
        Vu = one_way_shear_demand(loads_h.qu, l2, ln, d)
        Vc = one_way_shear_capacity_without_Av(fc, l2, d, 0.0018 * l2 * proposed)
        @test ustrip(kip, Vu) <= 0.75 * ustrip(kip, Vc)
        d_thin = effective_depth(thinner; cover = 0.75u"inch", bar_diameter = 0.5u"inch")
        Vu_thin = one_way_shear_demand(loads_thin.qu, l2, ln, d_thin)
        Vc_thin = one_way_shear_capacity_without_Av(fc, l2, d_thin, 0.0018 * l2 * thinner)
        @test ustrip(kip, Vu_thin) > 0.75 * ustrip(kip, Vc_thin)
    end

    @testset "a passing next half-inch is not skipped" begin
        h0 = 8.0u"inch"
        analyzed = _jump_analysis(; h = h0, sdl = 20.0psf, qL = 40.0psf, γ = γ,
                                  l1 = 18.0u"ft", l2 = 18.0u"ft", ln = 16.0u"ft")
        spans = (primary = 18.0u"ft", secondary = 18.0u"ft")
        proposed = SS.propose_slab_thickness(
            h0, inc, 30.0u"inch", analyzed, nothing, γ;
            passes = (hh, scaled_p, scaled_s) ->
                _depth_passes(scaled_p, scaled_s, hh, γ, fc, fy, Es, Ecs, columns, spans))
        @test ustrip(u"inch", proposed) ≈ 8.5
    end
end
