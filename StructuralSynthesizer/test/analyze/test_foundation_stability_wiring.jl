# Stage 4 wiring: horizontal base shears into FootingAction, and the API
# StabilityParams override threaded onto every footing-param block.
#
# ASCE 7-22 §2.4 global-stability demand basis (corpus: asce-7-22). The
# StructuralSizer stability mechanics are tested in StructuralSizer; here we
# only verify the Synthesizer-side plumbing: reactions populate Hx/Hy, and the
# API block reaches spread/strip/mat opts.

using Test
using Unitful
using Asap

using StructuralSynthesizer
using StructuralSizer

@testset "Foundation stability wiring (Hx/Hy + API StabilityParams)" begin

    @testset "node reaction populates horizontal base shears" begin
        # A 2×2 shell patch, base row fixed, processed so nodes carry 6-dof
        # globalIDs. The reaction vector is synthetic — this checks the dof
        # indexing (gid[1]=Hx, gid[2]=Hy, gid[3]=P, gid[4]=Mx, gid[5]=My),
        # not a solve.
        grid = [Asap.Node([Float64(i - 1) * u"m", 0.0u"m", Float64(k - 1) * u"m"],
                          k == 1 ? :fixed : :free) for i in 1:2, k in 1:2]
        a, b, c, d = grid[1, 1], grid[2, 1], grid[2, 2], grid[1, 2]
        shells = Asap.ShellTri3[
            Asap.ShellTri3((a, b, c), 0.3u"m", 30e9u"Pa", 0.2; id = :w, ρ = 2400.0),
            Asap.ShellTri3((a, c, d), 0.3u"m", 30e9u"Pa", 0.2; id = :w, ρ = 2400.0)]
        model = Asap.Model(vec(grid), Asap.Element{Asap.FixedFixed}[], shells,
                           Asap.AbstractLoad[])
        Asap.process!(model)

        node = grid[1, 2]                      # a free node → 6 live dofs
        gid = node.globalID
        @test length(gid) >= 6
        R = zeros(maximum(gid))
        R[gid[1]] = 12.3   # Hx
        R[gid[2]] = -4.5   # Hy
        R[gid[3]] = 100.0  # P (vertical)
        R[gid[4]] = 7.0    # Mx
        R[gid[5]] = 8.0    # My
        act = StructuralSynthesizer._node_reaction_action(node, R, :t)
        @test act.P == 100.0
        @test act.Mx == 7.0
        @test act.My == 8.0
        @test act.Hx == 12.3
        @test act.Hy == -4.5
    end

    @testset "API stability block threads onto every footing-param block" begin
        rc = StructuralSizer.RC_4000_60
        fdn_conc = rc.concrete
        reb = rc.rebar

        # No foundation_options → stability stays off on all blocks.
        api_off = StructuralSynthesizer.APIParams()
        opts_off = StructuralSynthesizer._resolve_foundation_options(api_off, fdn_conc, reb)
        @test opts_off.spread_params.stability === nothing
        @test opts_off.strip_params.stability === nothing
        @test opts_off.mat_params.stability === nothing

        # foundation_options present but no stability block → still off.
        api_no_stab = StructuralSynthesizer.APIParams()
        api_no_stab.foundation_options = StructuralSynthesizer.APIFoundationOptions()
        opts_no_stab = StructuralSynthesizer._resolve_foundation_options(api_no_stab, fdn_conc, reb)
        @test opts_no_stab.spread_params.stability === nothing
        @test opts_no_stab.strip_params.stability === nothing
        @test opts_no_stab.mat_params.stability === nothing

        # A stability block turns the checks ON for every footing type and
        # carries the (non-default) field values through.
        api_on = StructuralSynthesizer.APIParams()
        api_on.foundation_options = StructuralSynthesizer.APIFoundationOptions(
            stability = StructuralSynthesizer.APIStabilityParams(
                delta_ratio = 0.7,
                ca_ratio = 0.8,
                include_passive = false,
                concrete_unit_weight_pcf = 145.0,
                dead_counteracting_factor = 0.6))
        opts_on = StructuralSynthesizer._resolve_foundation_options(api_on, fdn_conc, reb)
        for p in (opts_on.spread_params, opts_on.strip_params, opts_on.mat_params)
            @test p.stability !== nothing
            @test p.stability.delta_ratio == 0.7
            @test p.stability.ca_ratio == 0.8
            @test p.stability.include_passive == false
            @test p.stability.dead_counteracting_factor == 0.6
            # 145 pcf → stored as a unitful quantity; converts to ≈ 22.8 kN/m³.
            @test ustrip(u"kN/m^3", p.stability.concrete_unit_weight) ≈
                  ustrip(u"kN/m^3", 145.0u"lbf/ft^3") rtol = 1e-9
        end
    end

    @testset "_with_stability preserves every other field" begin
        base = StructuralSizer.SpreadParams(material = StructuralSizer.RC_4000_60,
            cover = 4.0u"inch", bar_size = 9, min_depth = 18.0u"inch")
        stab = StructuralSizer.StabilityParams(delta_ratio = 0.9)
        p = StructuralSynthesizer._with_stability(base, stab)
        @test p.stability === stab
        @test p.cover == 4.0u"inch"
        @test p.bar_size == 9
        @test p.min_depth == 18.0u"inch"
        @test p.ϕ_flexure == base.ϕ_flexure
        # Round-tripping nothing is a no-op clone.
        p0 = StructuralSynthesizer._with_stability(base, nothing)
        @test p0.stability === nothing
        @test p0.cover == 4.0u"inch"
    end
end
