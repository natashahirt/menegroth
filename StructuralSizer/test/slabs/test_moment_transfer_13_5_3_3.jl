# =============================================================================
# ACI 318-11 §13.5.3.3 — increased flexural fraction γf (corpus: aci-318-11,
# page 250)
# =============================================================================
#
# (a) edge, moment about the axis parallel to the edge: γf = 1.0 when
#     Vu ≤ 0.75φVc; corner (both axes here): γf = 1.0 when Vu ≤ 0.5φVc.
# (b) interior, and edge moment about the axis perpendicular to the edge:
#     γf ≤ min(1.25 γf₀, 1.0) when Vu ≤ 0.4φVc and εt ≥ 0.010 in the
#     §13.5.3.2 effective width.
#
# Oracles below are written out from the clause and Eq. (13-1) / (11-37):
#   γf₀ = 1 / (1 + (2/3)√(b1/b2)),  γv = 1 − γf
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

_γf0(b1, b2) = 1.0 / (1.0 + (2.0 / 3.0) * sqrt(b1 / b2))

@testset "§13.5.3.3 — γf selection" begin
    fc = 4000.0u"psi"
    fy = 60_000.0u"psi"
    d  = 6.0u"inch"
    bb = 40.0u"inch"
    b  = 22.0u"inch"
    φVc = 100.0kip
    Mu = 40.0kip * u"ft"
    γ0 = _γf0(b, b)

    # (a) edge: 0.75φVc
    g = SS.moment_transfer_gamma_f(b, b, :edge_parallel, 70.0kip, φVc, Mu, bb, d, fc, fy)
    @test g.γf == 1.0 && g.provision === :aci_13_5_3_3a
    g = SS.moment_transfer_gamma_f(b, b, :edge_parallel, 80.0kip, φVc, Mu, bb, d, fc, fy)
    @test g.γf ≈ γ0 && g.provision === :eq_13_1

    # (a) corner: 0.5φVc
    g = SS.moment_transfer_gamma_f(b, b, :corner, 45.0kip, φVc, Mu, bb, d, fc, fy)
    @test g.γf == 1.0 && g.provision === :aci_13_5_3_3a
    g = SS.moment_transfer_gamma_f(b, b, :corner, 55.0kip, φVc, Mu, bb, d, fc, fy)
    @test g.provision === :eq_13_1

    # (b) interior: 0.4φVc, 1.25 γf₀
    g = SS.moment_transfer_gamma_f(b, b, :interior, 35.0kip, φVc, Mu, bb, d, fc, fy)
    @test g.γf ≈ 1.25 * γ0 && g.provision === :aci_13_5_3_3b
    g = SS.moment_transfer_gamma_f(b, b, :interior, 45.0kip, φVc, Mu, bb, d, fc, fy)
    @test g.γf ≈ γ0 && g.provision === :eq_13_1

    # (b) capped at 1.0: b1/b2 = 1/16 ⇒ γf₀ = 1/(1 + 1/6) = 0.857, 1.25γf₀ > 1.
    g = SS.moment_transfer_gamma_f(4.0u"inch", 64.0u"inch", :edge_perpendicular,
                                   35.0kip, φVc, 5.0kip * u"ft", bb, d, fc, fy)
    @test g.γf == 1.0 && g.provision === :aci_13_5_3_3b

    # (b) εt gate. Band 40 in × d 6 in, f'c 4 ksi, fy 60 ksi:
    # εt = 0.0075 at c/d = 0.003/0.0105, a = 0.85c = 1.457 in,
    # As = 0.85·4·40·1.457/60 = 3.30 in², φMn = 0.9·3.30·60·(6 − 0.729)/12
    # = 78.3 kip·ft. Mu = 104 kip·ft at 1.25·0.6 = 0.75 is ≈ 78 kip·ft:
    # tension-controlled but εt < 0.010, so (b) is refused.
    g = SS.moment_transfer_gamma_f(b, b, :interior, 35.0kip, φVc, 104.0kip * u"ft",
                                   bb, d, fc, fy)
    @test g.provision === :eq_13_1

    # (a) is refused when the band cannot develop the full moment.
    g = SS.moment_transfer_gamma_f(b, b, :edge_parallel, 10.0kip, φVc, 400.0kip * u"ft",
                                   bb, d, fc, fy)
    @test g.provision === :eq_13_1

    @test_throws ArgumentError SS.moment_transfer_gamma_f(b, b, :wall, 1.0kip, φVc, Mu,
                                                          bb, d, fc, fy)
end

@testset "§13.5.3.3 — Jc of the edge section about its symmetry axis" begin
    # b1 = 23 (legs), b2 = 26 (face along the edge), d = 6:
    # d b2³/12 = 8788, b2 d³/12 = 468, 2 b1 d (b2/2)² = 46644
    Jc = SS.polar_moment_Jc_edge_perpendicular(23.0u"inch", 26.0u"inch", 6.0u"inch")
    @test ustrip(u"inch^4", Jc) ≈ 8788 + 468 + 46644
end

@testset "§13.5.3.3 — band strain εt" begin
    # As 3.30 in², bb 40 in, d 6 in, f'c 4 ksi, fy 60 ksi:
    # a = 3.30·60/(0.85·4·40) = 1.456, c = a/0.85 = 1.713, εt = 0.003(6 − c)/c
    As = 3.30u"inch^2"
    c = (3.30 * 60 / (0.85 * 4 * 40)) / 0.85
    εt = SS.transfer_band_net_tensile_strain(As, 40.0u"inch", 6.0u"inch",
                                             4000.0u"psi", 60_000.0u"psi")
    @test εt ≈ 0.003 * (6 - c) / c
end

@testset "§13.5.3.3 — check_punching_for_column" begin
    c  = 16.0u"inch"
    d  = 5.75u"inch"
    h  = 7.0u"inch"
    fc = 4000.0u"psi"
    fy = 60_000.0u"psi"
    mt = (fy = fy,)
    φ  = 0.75
    vc_psi = 4 * sqrt(4000.0)   # 4√f'c governs for a square column, λs = 1 at d < 10 in

    @testset "interior — (b) on both axes" begin
        # Deeper slab, so the band holds 1.25γf₀·M at εt ≥ 0.010 while
        # Eq. (13-1) fails.
        local d = 8.5u"inch"
        local h = 10.0u"inch"
        col = (position = :interior, c1 = c, c2 = c, shape = :rectangular)
        b1 = c + d
        b0 = 4b1
        Jc = d * b1^3 / 6 + b1 * d^3 / 6 + d * b1 * b1^2 / 2
        φVc = φ * vc_psi * u"psi" * b0 * d
        Vu = 40.0kip
        @test Vu <= 0.4φVc
        Mx = 150.0kip * u"ft"
        My = 70.0kip * u"ft"
        r0 = SS.check_punching_for_column(col, Vu, Mx, d, h, fc; Muy = My)
        @test !r0.ok
        @test r0.moment_transfer === nothing

        γv = 1 - 1.25 * _γf0(b1, b1)
        vu_oracle = uconvert(u"psi", Vu / (b0 * d)) +
                    uconvert(u"psi", γv * (Mx + My) * (b1 / 2) / Jc)
        r = SS.check_punching_for_column(col, Vu, Mx, d, h, fc; Muy = My,
                                         moment_transfer = mt)
        @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", vu_oracle) rtol = 1e-9
        @test r.moment_transfer.provision_x === :aci_13_5_3_3b
        @test r.moment_transfer.γf_x ≈ 1.25 * _γf0(b1, b1)
        @test r.ok && r.vu < r0.vu

        # Above 0.4φVc the Eq. (13-1) result stands.
        Vu_hi = 0.5φVc
        r_hi = SS.check_punching_for_column(col, Vu_hi, Mx, d, h, fc; Muy = My,
                                            moment_transfer = mt)
        r_hi0 = SS.check_punching_for_column(col, Vu_hi, Mx, d, h, fc; Muy = My)
        @test r_hi.moment_transfer === nothing
        @test r_hi.vu ≈ r_hi0.vu
    end

    @testset "the increase is not taken where Eq. (13-1) passes" begin
        col = (position = :interior, c1 = c, c2 = c, shape = :rectangular)
        Mx = 20.0kip * u"ft"
        My = 10.0kip * u"ft"
        r0 = SS.check_punching_for_column(col, 30.0kip, Mx, d, h, fc; Muy = My)
        r = SS.check_punching_for_column(col, 30.0kip, Mx, d, h, fc; Muy = My,
                                         moment_transfer = mt)
        @test r0.ok
        @test r.moment_transfer === nothing
        @test r.vu ≈ r0.vu
    end

    @testset "corner — (a) on both axes" begin
        col = (position = :corner, c1 = c, c2 = c, shape = :rectangular)
        b1 = c + d / 2
        b0 = 2b1
        αs_term = (20 * d / b0 + 2) * sqrt(4000.0)
        φVc = φ * min(vc_psi, αs_term) * u"psi" * b0 * d
        Vu = 0.45φVc
        Mx = 45.0kip * u"ft"
        My = 35.0kip * u"ft"
        @test !SS.check_punching_for_column(col, Vu, Mx, d, h, fc; Muy = My).ok
        r = SS.check_punching_for_column(col, Vu, Mx, d, h, fc;
                                         Muy = My, moment_transfer = mt)
        @test r.moment_transfer.provision_x === :aci_13_5_3_3a
        @test r.moment_transfer.provision_y === :aci_13_5_3_3a
        @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", Vu / (b0 * d)) rtol = 1e-9

        r_hi = SS.check_punching_for_column(col, 0.55φVc, Mx, d, h, fc;
                                            Muy = My, moment_transfer = mt)
        @test r_hi.moment_transfer === nothing
    end

    @testset "edge — (a) drops the moment about the axis parallel to the edge" begin
        b1 = c + d / 2           # legs, perpendicular to the edge
        b2 = c + d               # face along the edge
        b0 = 2b1 + b2
        αs_term = (30 * d / b0 + 2) * sqrt(4000.0)
        φVc = φ * min(vc_psi, αs_term) * u"psi" * b0 * d
        Vu = 0.39φVc             # (b) also applies to the other moment
        M = 78.0kip * u"ft"      # Eq. (13-1) fails; the 37 in band develops M
        Jc_p = d * b2^3 / 12 + b2 * d^3 / 12 + 2 * b1 * d * (b2 / 2)^2
        v_direct = uconvert(u"psi", Vu / (b0 * d))

        # Edge along y, span along x: Mub is about an axis parallel to the edge.
        col_y = (position = :edge, c1 = c, c2 = c, shape = :rectangular,
                 boundary_edge_dirs = [(0.0, 1.0)])
        @test !SS.check_punching_for_column(col_y, Vu, M, d, h, fc).ok
        r = SS.check_punching_for_column(col_y, Vu, M, d, h, fc; moment_transfer = mt)
        @test r.moment_transfer.provision_x === :aci_13_5_3_3a
        @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", v_direct) rtol = 1e-9

        # The perpendicular moment stays, on the symmetric-axis section, with (b).
        My = 15.0kip * u"ft"
        γv_perp = 1 - 1.25 * _γf0(b2, b1)
        vu_perp = v_direct + uconvert(u"psi", γv_perp * My * (b2 / 2) / Jc_p)
        r2 = SS.check_punching_for_column(col_y, Vu, M, d, h, fc; Muy = My,
                                          moment_transfer = mt)
        @test r2.moment_transfer.provision_y === :aci_13_5_3_3b
        @test ustrip(u"psi", r2.vu) ≈ ustrip(u"psi", vu_perp) rtol = 1e-9

        # Edge along x, span along x: the span moment is about the axis
        # perpendicular to the edge, so (a) goes to the secondary moment.
        col_x = (position = :edge, c1 = c, c2 = c, shape = :rectangular,
                 boundary_edge_dirs = [(1.0, 0.0)])
        r3 = SS.check_punching_for_column(col_x, Vu, My, d, h, fc; Muy = M,
                                          moment_transfer = mt)
        @test r3.moment_transfer.provision_x === :aci_13_5_3_3b
        @test r3.moment_transfer.provision_y === :aci_13_5_3_3a
        @test ustrip(u"psi", r3.vu) ≈ ustrip(u"psi", vu_perp) rtol = 1e-9

        # No stored edge direction: the moment axes are unknown, Eq. (13-1) stands.
        col_none = (position = :edge, c1 = c, c2 = c, shape = :rectangular)
        r4 = SS.check_punching_for_column(col_none, Vu, M, d, h, fc; moment_transfer = mt)
        @test r4.moment_transfer === nothing
    end
end

@testset "Eq. (13-1) — moments meet the column axis they span" begin
    # A 24×12 interior column with the span along c2: the span moment has
    # b1 = c2 + d, the secondary moment b1 = c1 + d.
    c1 = 24.0u"inch"
    c2 = 12.0u"inch"
    d = 6.0u"inch"
    h = 7.5u"inch"
    fc = 4000.0u"psi"
    col = (position = :interior, c1 = c1, c2 = c2, shape = :rectangular, θ = 0.0)
    Vu = 40.0kip
    Mspan = 40.0kip * u"ft"
    b0 = 2 * (c1 + d) + 2 * (c2 + d)
    Jc(b1, b2) = d * b1^3 / 6 + b1 * d^3 / 6 + d * b2 * b1^2 / 2
    γv(b1, b2) = 1 - _γf0(ustrip(u"inch", b1), ustrip(u"inch", b2))
    oracle(b1, b2) = uconvert(u"psi", Vu / (b0 * d)) +
                     uconvert(u"psi", γv(b1, b2) * Mspan * (b1 / 2) / Jc(b1, b2))
    along_c2 = SS.check_punching_for_column(col, Vu, Mspan, d, h, fc; span_axis = (0.0, 1.0))
    along_c1 = SS.check_punching_for_column(col, Vu, Mspan, d, h, fc; span_axis = (1.0, 0.0))
    @test ustrip(u"psi", along_c2.vu) ≈ ustrip(u"psi", oracle(c2 + d, c1 + d)) rtol = 1e-9
    @test ustrip(u"psi", along_c1.vu) ≈ ustrip(u"psi", oracle(c1 + d, c2 + d)) rtol = 1e-9
    @test along_c2.vu != along_c1.vu
end

@testset "§13.5.3.3 — transfer steel uses the punching γf" begin
    M = 40.0kip * u"ft"
    c = 16.0u"inch"; h = 7.0u"inch"; d = 5.75u"inch"
    fc = 4000.0u"psi"; fy = 60_000.0u"psi"
    g0 = SS.governing_transfer_reinforcement(M, 0.0kip * u"ft", c, c, h, d, fc, fy;
                                             position = :interior)
    g1 = SS.governing_transfer_reinforcement(M, 0.0kip * u"ft", c, c, h, d, fc, fy;
                                             position = :interior, γf_x = 0.75)
    @test g1.γf == 0.75
    @test ustrip(u"inch^2", g1.As) ≈
          ustrip(u"inch^2", SS.transfer_reinforcement(M, 0.75, c + 3h, d, fc, fy))
    @test g1.As > g0.As
end

@testset "§13.5.3.3(b) — εt on the placed band steel" begin
    fc = 4000.0u"psi"; fy = 60_000.0u"psi"; d = 6.0u"inch"
    bb = 40.0u"inch"
    gov = (As_x = 1.0u"inch^2", As_y = 0.0u"inch^2", bb_x = bb, bb_y = bb)
    mt = (γf_x = 0.75, γf_y = 0.6, provision_x = :aci_13_5_3_3b, provision_y = :eq_13_1)
    design(As) = (column_strip_reinf = [(As_provided = As,)], column_strip_width = 80.0u"inch")
    bars(n) = (n_bars_additional = n, bar_area = 0.31u"inch^2")
    added(n_c1, n_c2) = (c1 = bars(n_c1), c2 = bars(n_c2))
    none_added = added(0, 0)

    # 2 in² over 80 in ⇒ 1 in² in the band: εt ≫ 0.010.
    @test SS._placed_band_strain_ok(mt, gov, none_added, design(2.0u"inch^2"),
                                    nothing, 1, d, fc, fy)
    # 8 in² ⇒ 4 in² in the band: c = 4·60/(0.85·4·40)/0.85 = 2.08 in, εt = 0.0057.
    @test !SS._placed_band_strain_ok(mt, gov, none_added, design(8.0u"inch^2"),
                                     nothing, 1, d, fc, fy)
    # Bars added in this band count against εt; bars in the other band do not.
    @test !SS._placed_band_strain_ok(mt, gov, added(10, 0),
                                     design(2.0u"inch^2"), nothing, 1, d, fc, fy)
    @test SS._placed_band_strain_ok(mt, gov, added(0, 10),
                                    design(2.0u"inch^2"), nothing, 1, d, fc, fy)
    # A y-axis (b) increase with no secondary design cannot be verified.
    mt_y = (γf_x = 0.6, γf_y = 0.75, provision_x = :eq_13_1, provision_y = :aci_13_5_3_3b)
    gov_y = (As_x = 0.0u"inch^2", As_y = 1.0u"inch^2", bb_x = bb, bb_y = bb)
    @test !SS._placed_band_strain_ok(mt_y, gov_y, none_added, design(2.0u"inch^2"),
                                     nothing, 1, d, fc, fy)
    @test SS._placed_band_strain_ok(mt_y, gov_y, none_added, design(2.0u"inch^2"),
                                    design(2.0u"inch^2"), 1, d, fc, fy)
end

@testset "§13.5.3.2 — each moment keeps its own band" begin
    c1 = 24.0u"inch"
    c2 = 12.0u"inch"
    h = 8.0u"inch"
    d = 6.5u"inch"
    edge = SS.transfer_bands(c1, c2, h, d; position = :edge, free_edge_parallel = :c1)
    # Edge along c1. Mux spans along the edge (one side); Muy spans into the slab.
    @test edge.b1_x == c1 + d && edge.bb_x == c2 + 1.5h
    @test edge.b1_y == c2 + d / 2 && edge.bb_y == c1 + 3h
    corner = SS.transfer_bands(c1, c2, h, d; position = :corner)
    @test corner.b1_x == c1 + d / 2 && corner.b2_x == c2 + d / 2
    @test corner.bb_x == c2 + 1.5h && corner.bb_y == c1 + 1.5h

    # A shallower inner layer needs more steel for the same moment.
    M = 40.0kip * u"ft"
    fc = 4000.0u"psi"
    fy = 60_000.0u"psi"
    full = SS.governing_transfer_reinforcement(0.0kip * u"ft", M, c1, c2, h, d, fc, fy)
    inner = SS.governing_transfer_reinforcement(0.0kip * u"ft", M, c1, c2, h, d, fc, fy;
                                                d_y = 0.8d)
    @test inner.As > full.As
end

@testset "§13.5.3.3 — a span along c2 keeps its fraction on that axis" begin
    # Edge along x, span along y: the span moment is about the axis parallel
    # to the edge, so (a) belongs to c2, not c1.
    c1 = 20.0u"inch"
    c2 = 12.0u"inch"
    d = 6.0u"inch"
    h = 8.0u"inch"
    fc = 4000.0u"psi"
    col = (position = :edge, c1 = c1, c2 = c2, shape = :rectangular,
           boundary_edge_dirs = [(1.0, 0.0)], θ = 0.0)
    mt = (fy = 60_000.0u"psi",)
    b0 = 2 * (c2 + d / 2) + (c1 + d)
    φVc = 0.75 * 4 * sqrt(4000.0) * u"psi" * b0 * d
    M = 65.0kip * u"ft"
    @test !SS.check_punching_for_column(col, 0.6φVc, M, d, h, fc; span_axis = (0.0, 1.0)).ok
    r = SS.check_punching_for_column(col, 0.6φVc, M, d, h, fc;
                                     span_axis = (0.0, 1.0), moment_transfer = mt)
    @test r.moment_transfer.provision_y === :aci_13_5_3_3a
    @test r.moment_transfer.γf_y == 1.0
    @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", 0.6φVc / (b0 * d)) rtol = 1e-9
end

@testset "§13.5.3 — extra bars come from the moment's own strip" begin
    # The secondary moment needs steel. The primary strip would cover it;
    # the secondary strip does not. The added bars have to be the secondary ones.
    c = 16.0u"inch"
    h = 7.0u"inch"
    d = 5.75u"inch"
    fc = 4000.0u"psi"
    fy = 60_000.0u"psi"
    width = 80.0u"inch"
    col = (position = :interior, c1 = c, c2 = c, θ = 0.0)
    station(As) = (As_provided = As,)
    design(As) = (column_strip_reinf = [station(As), station(As), station(As)],
                  column_strip_width = width)
    primary = design(4.0u"inch^2")
    secondary = design(0.30u"inch^2")
    pass_at(primary_design, Mub, Muy; kw...) = SS._transfer_reinforcement_pass(
        [col], (unbalanced_moments = [Mub], column_shears = [60.0kip]),
        (unbalanced_moments = [Muy],), primary_design, h, d, fc, fy;
        secondary_rebar_design = secondary,
        on_inadequate = (i, reason) -> false, kw...).results[1]
    r = pass_at(primary, 1.0kip * u"ft", 40.0kip * u"ft")
    gov = SS.governing_transfer_reinforcement(1.0kip * u"ft", 40.0kip * u"ft",
                                              c, c, h, d, fc, fy; position = :interior)
    Ab = SS._strip_bar_area(secondary, h, 3)
    expected = SS.additional_transfer_bars(gov.As_y, 0.30u"inch^2", gov.bb_y, width, Ab)
    covered = SS.additional_transfer_bars(gov.As_y, 4.0u"inch^2", gov.bb_y, width, Ab)
    @test r.c2.n_bars_additional == expected.n_bars_additional > 0
    @test r.c1.n_bars_additional == 0
    @test r.n_bars_additional == r.c2.n_bars_additional
    @test covered.n_bars_additional == 0

    # Both bands short: both sets of bars are reported.
    both = pass_at(design(0.30u"inch^2"), 40.0kip * u"ft", 40.0kip * u"ft")
    @test both.c1.n_bars_additional > 0 && both.c2.n_bars_additional > 0
    @test both.n_bars_additional == both.c1.n_bars_additional + both.c2.n_bars_additional

    # ACI 318-19 §8.6.1.2 top steel (across c2) governs the c1 band without
    # removing the c2 transfer bars. vuv = 60 kip / (87 · 5.75) = 120 psi.
    top = pass_at(design(0.30u"inch^2"), 1.0kip * u"ft", 40.0kip * u"ft";
              punching = [(b0 = 4 * (c + d),)])
    @test top.c1.governs === :min_top_steel_8_6_1_2
    @test top.c1.n_bars_additional > 0
    @test top.c2.governs === :moment_transfer
    @test top.c2.n_bars_additional == expected.n_bars_additional
    @test top.n_bars_additional == top.c1.n_bars_additional + top.c2.n_bars_additional
end

@testset "§13.5.3 — thickness pre-check uses the band of each moment" begin
    # Edge along c1, span along c2: the span moment runs into the slab and
    # has the full c1 + 3h band. Assigned to c1 it would see c2 + 1.5h.
    c1 = 30.0u"inch"
    c2 = 12.0u"inch"
    h = 7.0u"inch"
    d = 5.75u"inch"
    fc = 4000.0u"psi"
    fy = 60_000.0u"psi"
    col = (position = :edge, c1 = c1, c2 = c2, θ = 0.0, boundary_edge_dirs = [(1.0, 0.0)])
    # γf·M is 0.70 × 130 = 91 kip·ft on 51 in (holds about 114 tension-
    # controlled) but 0.49 × 130 = 64 kip·ft on 22.5 in (about 50).
    M = 130.0kip * u"ft"
    mr = (unbalanced_moments = [M],)
    @test SS._transfer_sections_adequate([col], mr, nothing, h, d, fc, fy;
                                         span_axis = (0.0, 1.0))
    @test !SS._transfer_sections_adequate([col], mr, nothing, h, d, fc, fy;
                                          span_axis = (1.0, 0.0))
end
