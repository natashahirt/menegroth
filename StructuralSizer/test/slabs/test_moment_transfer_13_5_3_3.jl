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
    mt = (fy = fy, span_axis = (1.0, 0.0))
    φ  = 0.75
    vc_psi = 4 * sqrt(4000.0)   # 4√f'c governs for a square column, λs = 1 at d < 10 in

    @testset "interior — (b) on both axes" begin
        col = (position = :interior, c1 = c, c2 = c, shape = :rectangular)
        b1 = c + d
        b0 = 4b1
        Jc = d * b1^3 / 6 + b1 * d^3 / 6 + d * b1 * b1^2 / 2
        φVc = φ * vc_psi * u"psi" * b0 * d
        Vu = 30.0kip
        @test Vu <= 0.4φVc
        Mx = 20.0kip * u"ft"
        My = 10.0kip * u"ft"
        γv = 1 - 1.25 * _γf0(b1, b1)
        vu_oracle = uconvert(u"psi", Vu / (b0 * d)) +
                    uconvert(u"psi", γv * (Mx + My) * (b1 / 2) / Jc)
        r = SS.check_punching_for_column(col, Vu, Mx, d, h, fc; Muy = My,
                                         moment_transfer = mt)
        @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", vu_oracle) rtol = 1e-9
        @test r.moment_transfer.provision_x === :aci_13_5_3_3b
        @test r.moment_transfer.γf_x ≈ 1.25 * _γf0(b1, b1)

        r0 = SS.check_punching_for_column(col, Vu, Mx, d, h, fc; Muy = My)
        @test r0.moment_transfer === nothing
        @test r.vu < r0.vu

        # Above 0.4φVc the Eq. (13-1) result stands.
        Vu_hi = 0.5φVc
        r_hi = SS.check_punching_for_column(col, Vu_hi, Mx, d, h, fc; Muy = My,
                                            moment_transfer = mt)
        r_hi0 = SS.check_punching_for_column(col, Vu_hi, Mx, d, h, fc; Muy = My)
        @test r_hi.moment_transfer === nothing
        @test r_hi.vu ≈ r_hi0.vu
    end

    @testset "corner — (a) on both axes" begin
        col = (position = :corner, c1 = c, c2 = c, shape = :rectangular)
        b1 = c + d / 2
        b0 = 2b1
        αs_term = (20 * d / b0 + 2) * sqrt(4000.0)
        φVc = φ * min(vc_psi, αs_term) * u"psi" * b0 * d
        Vu = 0.45φVc
        r = SS.check_punching_for_column(col, Vu, 30.0kip * u"ft", d, h, fc;
                                         Muy = 20.0kip * u"ft", moment_transfer = mt)
        @test r.moment_transfer.provision_x === :aci_13_5_3_3a
        @test r.moment_transfer.provision_y === :aci_13_5_3_3a
        @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", Vu / (b0 * d)) rtol = 1e-9

        r_hi = SS.check_punching_for_column(col, 0.55φVc, 30.0kip * u"ft", d, h, fc;
                                            Muy = 20.0kip * u"ft", moment_transfer = mt)
        @test r_hi.moment_transfer === nothing
    end

    @testset "edge — (a) drops the moment about the axis parallel to the edge" begin
        b1 = c + d / 2           # legs, perpendicular to the edge
        b2 = c + d               # face along the edge
        b0 = 2b1 + b2
        αs_term = (30 * d / b0 + 2) * sqrt(4000.0)
        φVc = φ * min(vc_psi, αs_term) * u"psi" * b0 * d
        Vu = 0.3φVc
        M = 30.0kip * u"ft"
        Jc_p = d * b2^3 / 12 + b2 * d^3 / 12 + 2 * b1 * d * (b2 / 2)^2
        v_direct = uconvert(u"psi", Vu / (b0 * d))

        # Edge along y, span along x: Mub is about an axis parallel to the edge.
        col_y = (position = :edge, c1 = c, c2 = c, shape = :rectangular,
                 boundary_edge_dirs = [(0.0, 1.0)])
        r = SS.check_punching_for_column(col_y, Vu, M, d, h, fc; moment_transfer = mt)
        @test r.moment_transfer.provision_x === :aci_13_5_3_3a
        @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", v_direct) rtol = 1e-9

        # The perpendicular moment stays, on the symmetric-axis section, with (b).
        My = 15.0kip * u"ft"
        r2 = SS.check_punching_for_column(col_y, Vu, M, d, h, fc; Muy = My,
                                          moment_transfer = mt)
        γv_perp = 1 - 1.25 * _γf0(b2, b1)
        @test r2.moment_transfer.provision_y === :aci_13_5_3_3b
        @test ustrip(u"psi", r2.vu) ≈
              ustrip(u"psi", v_direct + uconvert(u"psi", γv_perp * My * (b2 / 2) / Jc_p)) rtol = 1e-9

        # Edge along x, span along x: Mub is the perpendicular-axis moment and stays.
        col_x = (position = :edge, c1 = c, c2 = c, shape = :rectangular,
                 boundary_edge_dirs = [(1.0, 0.0)])
        r3 = SS.check_punching_for_column(col_x, Vu, M, d, h, fc; moment_transfer = mt)
        @test r3.moment_transfer.provision_y === :aci_13_5_3_3a
        @test ustrip(u"psi", r3.vu) ≈
              ustrip(u"psi", v_direct + uconvert(u"psi", γv_perp * M * (b2 / 2) / Jc_p)) rtol = 1e-9

        # No stored edge direction: the moment axes are unknown, Eq. (13-1) stands.
        col_none = (position = :edge, c1 = c, c2 = c, shape = :rectangular)
        r4 = SS.check_punching_for_column(col_none, Vu, M, d, h, fc; moment_transfer = mt)
        @test r4.moment_transfer === nothing
    end
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
    none_added = (n_bars_additional = 0,)
    Ab = 0.31u"inch^2"

    # 2 in² over 80 in ⇒ 1 in² in the band: εt ≫ 0.010.
    @test SS._placed_band_strain_ok(mt, gov, none_added, Ab, design(2.0u"inch^2"),
                                    nothing, 1, d, fc, fy)
    # 8 in² ⇒ 4 in² in the band: c = 4·60/(0.85·4·40)/0.85 = 2.08 in, εt = 0.0057.
    @test !SS._placed_band_strain_ok(mt, gov, none_added, Ab, design(8.0u"inch^2"),
                                     nothing, 1, d, fc, fy)
    # Added bars count against εt.
    @test !SS._placed_band_strain_ok(mt, gov, (n_bars_additional = 10,), Ab,
                                     design(2.0u"inch^2"), nothing, 1, d, fc, fy)
    # A y-axis (b) increase with no secondary design cannot be verified.
    mt_y = (γf_x = 0.6, γf_y = 0.75, provision_x = :eq_13_1, provision_y = :aci_13_5_3_3b)
    gov_y = (As_x = 0.0u"inch^2", As_y = 1.0u"inch^2", bb_x = bb, bb_y = bb)
    @test !SS._placed_band_strain_ok(mt_y, gov_y, none_added, Ab, design(2.0u"inch^2"),
                                     nothing, 1, d, fc, fy)
    @test SS._placed_band_strain_ok(mt_y, gov_y, none_added, Ab, design(2.0u"inch^2"),
                                    design(2.0u"inch^2"), 1, d, fc, fy)
end
