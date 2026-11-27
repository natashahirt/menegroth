# Stage 5 end-to-end: a laterally-loaded column drives real base shear through
# the production spread-footing sizing dispatch (_size_fnd_aci!) with the
# ASCE 7-22 global-stability checks turned on.
#
# This closes the loop built in Stages 1–4: foundation_actions_at -> ASD
# combination factoring that carries Hx/Hy (ASCE 7-22 §2.4.1 comb. 7a
# 0.6D + 0.6W) -> footing_loads(column_service) -> design_footing(SpreadFooting)
# -> footing_stability_utils. The wind/seismic *solve* that fills the reaction
# vectors is exercised by the lateral suite; here we inject a known lateral
# case so the sliding demand is deterministic and assert it reaches the result.
#
# Bowles 5e Eq. (4-3) sliding resistance (corpus:
# textbook-bowles-foundation-analysis-design-5e, PDF pages 252–253).

using Test
using Unitful
using Asap

using StructuralSynthesizer
using StructuralSizer

"""A small flat-plate office with gravity loads and sized columns."""
function _e2e_plate(; sdl = 100.0u"psf", ll = 20.0u"psf")
    skel = gen_medium_office(40.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(material = RC_4000_60, method = DDM(),
                            cover = 0.75u"inch", bar_size = 5)
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl       = uconvert(u"kN/m^2", sdl)
        cell.live_load = uconvert(u"kN/m^2", ll)
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    return struc
end

"""
Inject a lateral envelope with one wind case carrying a pure horizontal base
shear `Hx` at every support. The vertical dead at support `i` is its real
service reaction, so comb. 7a's counteracting `0.6D` is physical. No seismic.
"""
function _inject_wind_shear!(struc, demands, Hx)
    n = length(struc.supports)
    supports = Vector{StructuralSynthesizer.SupportFoundationCases}(undef, n)
    for i in 1:n
        Pd = ustrip(u"N", demands[i].Ps)          # service vertical as dead
        D = StructuralSizer.FootingAction(:D, Pd, 0.0, 0.0, 0.0, 0.0)
        L = StructuralSizer.FootingAction(:L)     # zero live
        companion = StructuralSizer.FootingAction(:roof)
        wind = StructuralSizer.FootingAction(:W, 0.0, 0.0, 0.0, ustrip(u"N", Hx), 0.0)
        supports[i] = StructuralSynthesizer.SupportFoundationCases(
            D, L, companion, [wind], StructuralSizer.FootingAction[])
    end
    struc.foundation_lateral = StructuralSynthesizer.FoundationLateralCases(
        :Lr, 1.0, 0.0, supports,
        (Float64[], Float64[], Float64[]), [Float64[]], Vector{Float64}[])
    return struc
end

"""First single-support spread foundation whose demand is compression."""
function _first_spread_compression(struc, demands)
    for (f_idx, fnd) in enumerate(struc.foundations)
        length(fnd.support_indices) == 1 || continue
        s = fnd.support_indices[1]
        demands[s].uplift && continue
        return f_idx, fnd, s
    end
    error("no single-support compression spread foundation")
end

@testset "Foundation global stability — end-to-end base shear → utilization" begin
    # Firm sand: friction-only resistance, ample bearing so a modest footing
    # forms and the lateral shear is reported rather than governing.
    soil = StructuralSizer.Soil(12.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    stab = StructuralSizer.StabilityParams()  # defaults: δ=0.5φ, passive on

    # One shared building/demands; size the same foundation three ways.
    struc = _e2e_plate()
    params = DesignParameters(pattern_loading = :none)
    to_asap!(struc; params)
    sync_asap!(struc; params)
    initialize_supports!(struc)
    initialize_foundations!(struc)
    demands = support_demands(struc)
    f_idx, fnd, _ = _first_spread_compression(struc, demands)
    n_supp = length(fnd.support_indices)

    # A base shear comfortably below the friction capacity (sliding < 1).
    Hx = 0.08 * demands[fnd.support_indices[1]].Ps

    @testset "stability OFF reproduces NaN checks (baseline)" begin
        _inject_wind_shear!(struc, demands, Hx)
        opts = StructuralSizer.FoundationOptions()  # stability === nothing
        StructuralSynthesizer._size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts)
        r = struc.foundations[f_idx].result
        @test r isa StructuralSizer.SpreadFootingResult
        @test isnan(r.checks.sliding)
        @test isnan(r.checks.overturning)
        @test isnan(r.checks.uplift)
    end

    local r_on
    @testset "stability ON surfaces a finite, positive sliding utilization" begin
        _inject_wind_shear!(struc, demands, Hx)
        opts = StructuralSizer.FoundationOptions(
            spread_params = StructuralSizer.SpreadParams(stability = stab))
        StructuralSynthesizer._size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts)
        r_on = struc.foundations[f_idx].result
        @test r_on isa StructuralSizer.SpreadFootingResult
        @test isfinite(r_on.checks.sliding)
        @test r_on.checks.sliding > 0
        @test r_on.checks.sliding < 1          # chosen below capacity
        @test isfinite(r_on.checks.overturning)
        @test isfinite(r_on.checks.uplift)
        # Stability is folded into the governing utilization.
        @test r_on.utilization ≥ r_on.checks.sliding - 1e-12
    end

    @testset "doubling base shear doubles the sliding demand" begin
        _inject_wind_shear!(struc, demands, 2 * Hx)
        opts = StructuralSizer.FoundationOptions(
            spread_params = StructuralSizer.SpreadParams(stability = stab))
        StructuralSynthesizer._size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts)
        r2 = struc.foundations[f_idx].result
        @test isfinite(r2.checks.sliding)
        @test r2.checks.sliding > r_on.checks.sliding
        # Same plan geometry (bearing governs) ⇒ resistance fixed ⇒ the sliding
        # utilization scales linearly with the horizontal demand (comb. 7a
        # factors 0.6W on both runs).
        if r2.B ≈ r_on.B && r2.L_ftg ≈ r_on.L_ftg && r2.D ≈ r_on.D
            @test r2.checks.sliding ≈ 2 * r_on.checks.sliding rtol = 1e-6
        end
    end
end
