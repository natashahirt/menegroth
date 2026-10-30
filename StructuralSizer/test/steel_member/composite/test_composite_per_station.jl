# ==============================================================================
# Per-Station Composite Check — AISC 360-16 §I3.1a / §I3.2a / §I3.2b
# ==============================================================================
#
# Exercises the per-station composite engine (StructuralSizer per_station.jl):
#   • b_eff(s) per §I3.1a with per-side caps (reduces byte-identically to the
#     scalar get_b_eff on a regular grid);
#   • sign-dispatched ϕMn(s) (§I3.2a sagging / §I3.2b hogging);
#   • grid-independent governing-station search on the exact fields.
#
# These are PURE Sizer tests: the demand field M(s) is supplied as a closed-form
# analytic callable (the FEM-recovered field is tested at the Synthesizer layer).
#
# Reference: AISC 360-16 §I3.1a (corpus aisc-360-16 p.150), §I3.2a / §I3.2b (p.151).
# ==============================================================================

using Test
using Unitful
using StructuralSizer
using Asap  # kip, ksi units

# --- Shared fixture: W21×55 + solid slab (AISC Example I-1 geometry) ----------
function _per_station_fixture(; bsl = 10.0u"ft", bsr = 10.0u"ft",
                                edl = nothing, edr = nothing)
    section  = W("W21X55")
    material = A992_Steel
    slab = SolidSlabOnBeam(7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
                           29000.0ksi, bsl, bsr; edge_dist_left = edl, edge_dist_right = edr)
    return (; section, material, slab)
end

# Parabolic (simply-supported, uniform-load) sagging moment of peak M0: max at s=½.
_parabolic_M(M0) = s -> M0 * (4 * s * (1 - s))

# Triangular-load (0 at s=0 → peak at s=1) simply-supported moment, peak M0:
#   M(x) = (w0/6L)(L²x − x³); max at x = L/√3 (s ≈ 0.5774). Normalize to peak M0.
function _triangular_M(M0)
    s_peak = 1 / sqrt(3)
    shape(s) = s - s^3            # ∝ (L²x − x³)/L³ with x = sL
    peak = shape(s_peak)
    return s -> M0 * (shape(s) / peak)
end

@testset "Per-Station Composite (AISC I3.1a/I3.2a/I3.2b)" begin

    # ======================================================================
    # A1. REDUCTION — per-station b_eff(s) == scalar get_b_eff (byte-identical).
    # ======================================================================
    @testset "A1. b_eff(s) reduces byte-identically to scalar get_b_eff" begin
        fix = _per_station_fixture()
        L = 45.0u"ft"

        # Constant per-side extent = spacing/2 (meters), identical FP inputs.
        d_m = ustrip(u"m", fix.slab.beam_spacing_left) / 2
        left  = SideExtentProfile(d_m)
        right = SideExtentProfile(d_m)

        b_scalar = get_b_eff(fix.slab, L)
        for s in (0.0, 0.25, 0.5, 0.731, 1.0)
            b_station = b_eff_at_station(fix.slab, L, s; left = left, right = right)
            @test b_station == b_scalar          # exact equality at every station
        end

        # A side left as `nothing` falls straight back to the scalar field.
        @test b_eff_at_station(fix.slab, L, 0.4) == b_scalar
    end

    # ======================================================================
    # A2. REDUCTION — constant b_eff + parabolic M ⇒ governing = midspan,
    #     ϕMn & DCR byte-identical to scalar get_ϕMn_composite at midspan.
    # ======================================================================
    @testset "A2. Constant b_eff + parabolic M ⇒ midspan governs (byte-identical)" begin
        fix = _per_station_fixture()
        L = 45.0u"ft"
        d_m = ustrip(u"m", fix.slab.beam_spacing_left) / 2
        left = SideExtentProfile(d_m); right = SideExtentProfile(d_m)

        ΣQn = 292.0kip
        M0  = 600.0kip * u"ft"
        demand = _parabolic_M(M0)

        g = governing_composite_station(fix.section, fix.material, fix.slab, L,
                                        demand, ΣQn; left = left, right = right)

        @test isapprox(g.s_star, 0.5; atol = 1e-4)      # peak of the parabola
        @test g.sense == :positive

        # Byte-identical capacity to the scalar composite path at midspan.
        b_mid = get_b_eff(fix.slab, L)
        scalar = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_mid, ΣQn)
        @test g.b_eff == b_mid
        @test g.ϕMn   == scalar.ϕMn
        dcr_ref = ustrip(u"N*m", uconvert(u"N*m", M0)) /
                  ustrip(u"N*m", uconvert(u"N*m", scalar.ϕMn))
        @test isapprox(g.dcr_max, dcr_ref; rtol = 1e-9)
    end

    # ======================================================================
    # B6. b_eff(s) for a linear-taper (skew) tributary = §I3.1a caps on the
    #     LOCAL extent; breakpoints land at the polygon-vertex projections.
    # ======================================================================
    @testset "B6. Linear-taper b_eff(s) tracks the local §I3.1a caps" begin
        fix = _per_station_fixture()
        L = 30.0u"m"                           # L/8 = 3.75 m

        # Left constant 1.0 m; right tapers 1.0 m → 3.0 m. Neither exceeds L/8
        # until near s=1 where right 3.0 m < 3.75 m — so no cap binds: linear.
        left  = SideExtentProfile(1.0)
        right = SideExtentProfile([0.0, 1.0], [1.0, 3.0])

        for s in (0.0, 0.25, 0.5, 0.75, 1.0)
            d_r = 1.0 + 2.0 * s                # local right extent
            expect = (1.0 + d_r) * u"m"        # both < L/8 ⇒ no cap
            @test isapprox(b_eff_at_station(fix.slab, L, s; left = left, right = right),
                           expect; rtol = 1e-9)
        end

        # Breakpoints are the union of the per-side profile vertices + span ends.
        @test beff_breakpoints(left, right) == [0.0, 1.0]
        stepped = SideExtentProfile([0.0, 0.4, 1.0], [1.0, 2.0, 2.0])
        @test beff_breakpoints(stepped, nothing) == [0.0, 0.4, 1.0]
    end

    # ======================================================================
    # C8. MIXED CAPS — L/8 governs part of the span, the local extent elsewhere.
    # ======================================================================
    @testset "C8. Mixed caps: L/8 binds where the taper is wide" begin
        fix = _per_station_fixture()
        L = 10.0u"m"                           # L/8 = 1.25 m
        LL8 = ustrip(u"m", L / 8)

        # Right tapers 0.5 m → 3.0 m: below 1.25 m near s=0, above it near s=1.
        left  = SideExtentProfile(0.5)         # constant 0.5 m < L/8 (never caps)
        right = SideExtentProfile([0.0, 1.0], [0.5, 3.0])

        for s in (0.1, 0.3, 0.5, 0.7, 0.9)
            d_r = 0.5 + 2.5 * s
            expect = (0.5 + min(LL8, d_r)) * u"m"
            @test isapprox(b_eff_at_station(fix.slab, L, s; left = left, right = right),
                           expect; rtol = 1e-9)
        end
        # Transition crossing: d_r = 1.25 at s = (1.25-0.5)/2.5 = 0.3.
        @test isapprox(ustrip(u"m", b_eff_at_station(fix.slab, L, 0.3; left = left, right = right)),
                       0.5 + LL8; rtol = 1e-6)
    end

    # ======================================================================
    # C9. MULTI-BAY (chained) — per-side profile stitches two bays; hand value.
    # ======================================================================
    @testset "C9. Stitched two-bay per-side profile matches a hand calc" begin
        fix = _per_station_fixture()
        L = 40.0u"m"                           # L/8 = 5 m, never binds here

        # Bay A half-width 1.5 m for s∈[0,0.5]; bay B half-width 2.5 m for s∈[0.5,1].
        bayed = SideExtentProfile([0.0, 0.5, 0.5, 1.0], [1.5, 1.5, 2.5, 2.5])
        other = SideExtentProfile(1.0)         # constant far side 1.0 m

        @test isapprox(b_eff_at_station(fix.slab, L, 0.25; left = bayed, right = other),
                       (1.5 + 1.0) * u"m"; rtol = 1e-9)
        @test isapprox(b_eff_at_station(fix.slab, L, 0.75; left = bayed, right = other),
                       (2.5 + 1.0) * u"m"; rtol = 1e-9)
        @test beff_breakpoints(bayed, other) == [0.0, 0.5, 1.0]
    end

    # ======================================================================
    # C7. GRID INDEPENDENCE — irregular b_eff + asymmetric (triangular) M ⇒
    #     governing station shifts off midspan and matches a dense brute scan;
    #     answer is stable under station/bracket refinement.
    # ======================================================================
    @testset "C7. Governing station: grid-independent, matches brute force" begin
        fix = _per_station_fixture()
        L = 36.0u"ft"
        # Skew tributary: left constant, right tapers ⇒ b_eff(s) varies.
        left  = SideExtentProfile(1.2)
        right = SideExtentProfile([0.0, 1.0], [0.8, 2.2])
        ΣQn = 292.0kip
        demand = _triangular_M(700.0kip * u"ft")   # peak at s ≈ 0.5774

        g = governing_composite_station(fix.section, fix.material, fix.slab, L,
                                        demand, ΣQn; left = left, right = right)

        # Brute-force dense scan of the SAME DCR field.
        dcr_of_s = s -> composite_dcr_at_station(fix.section, fix.material, fix.slab,
                                                 L, s, demand(s), ΣQn;
                                                 left = left, right = right).dcr
        N = 200_001
        s_grid = range(0.0, 1.0; length = N)
        dcr_grid = [dcr_of_s(s) for s in s_grid]
        i_max = argmax(dcr_grid)
        s_brute = s_grid[i_max]
        dcr_brute = dcr_grid[i_max]

        @test g.s_star > 0.5                       # asymmetric ⇒ NOT midspan
        @test isapprox(g.s_star, s_brute; atol = 2e-3)
        @test isapprox(g.dcr_max, dcr_brute; rtol = 1e-6)

        # Stability under refinement: more bracket samples ⇒ same optimum.
        bp = beff_breakpoints(left, right)
        s5, d5 = governing_station(dcr_of_s, bp; n_bracket = 5)
        s41, d41 = governing_station(dcr_of_s, bp; n_bracket = 41)
        @test isapprox(s5, s41; atol = 1e-4)
        @test isapprox(d5, d41; rtol = 1e-7)
        @test isapprox(d41, dcr_brute; rtol = 1e-6)
    end

    # ======================================================================
    # D10/D11. SIGN DISPATCH — hogging region uses §I3.2b (steel + slab rebar);
    #          governing lands at the interior support when neg capacity is low.
    # ======================================================================
    @testset "D. Sign dispatch (§I3.2a vs §I3.2b) + governing at support" begin
        fix = _per_station_fixture()
        L = 30.0u"ft"
        d_m = ustrip(u"m", fix.slab.beam_spacing_left) / 2
        left = SideExtentProfile(d_m); right = SideExtentProfile(d_m)
        ΣQn = 292.0kip

        # Propped-cantilever field (UDL, fixed at s=0, pinned at s=1):
        #   M(s) = wL²·(−1/8 + 5s/8 − s²/2); M(0) = −wL²/8 (hogging), sagging
        #   peak +9wL²/128 at s=5/8. Choose wL²/8 = 400 kip·ft ⇒ wL² = 3200.
        #   Hogging |M(0)| = 400 kip·ft vs sagging peak 225 kip·ft; bare-steel
        #   negative capacity (ϕMp ≈ 472 kip·ft) < positive composite (≈ 767),
        #   so the hogging SUPPORT governs the DCR.
        wL2 = 3200.0kip * u"ft"
        demand = s -> wL2 * (-0.125 + 0.625 * s - 0.5 * s^2)

        # Per-station sense dispatch.
        r0  = composite_dcr_at_station(fix.section, fix.material, fix.slab, L, 0.0,
                                       demand(0.0), ΣQn; left = left, right = right)
        r06 = composite_dcr_at_station(fix.section, fix.material, fix.slab, L, 0.625,
                                       demand(0.625), ΣQn; left = left, right = right)
        @test r0.sense  == :negative            # hogging ⇒ §I3.2b
        @test r06.sense == :positive            # sagging ⇒ §I3.2a

        # Hogging with no developed reinforcement is Chapter F at this span,
        # not φMp. L = 30 ft exceeds Lp for W21×55.
        ϕMn_F = get_ϕMn(fix.section, fix.material; Lb = L, Cb = 1.0, axis = :strong)
        Mp = fix.material.Fy * fix.section.Zx
        @test isapprox(r0.ϕMn, ϕMn_F; rtol = 1e-9)
        @test r0.ϕMn < 0.9 * Mp

        # Asr without negative-region anchors does not open §I3.2b.
        r0_rebar = composite_dcr_at_station(fix.section, fix.material, fix.slab, L, 0.0,
                                            demand(0.0), ΣQn; left = left, right = right,
                                            Asr = 2.0u"inch^2", Fysr = 60.0ksi,
                                            d_rebar = 3.0u"inch", neg_moment = false)
        @test isapprox(r0_rebar.ϕMn, r0.ϕMn; rtol = 1e-9)
        @test r0_rebar.sense == :negative

        # With weak negative capacity (no rebar) and comparable |M|, the governing
        # station is at the hogging support, not in the sagging span.
        g = governing_composite_station(fix.section, fix.material, fix.slab, L,
                                        demand, ΣQn; left = left, right = right)
        @test g.s_star < 0.05
        @test g.sense == :negative
    end

    # ======================================================================
    # D12. INFLECTION POINT (M = 0) — no spurious failure / divide-by-zero.
    # ======================================================================
    @testset "D12. Inflection (M=0) is finite and non-governing" begin
        fix = _per_station_fixture()
        L = 30.0u"ft"
        ΣQn = 292.0kip
        demand = s -> (-300.0kip * u"ft") * (1 - 3s)   # zero at s = 1/3
        r = composite_dcr_at_station(fix.section, fix.material, fix.slab, L, 1 / 3,
                                     demand(1 / 3), ΣQn)
        @test isfinite(r.dcr)
        @test isapprox(r.dcr, 0.0; atol = 1e-9)
    end

    # ======================================================================
    # F17. DEGENERATE / ROBUSTNESS — zero-extent segments; very short beam.
    # ======================================================================
    @testset "F17. Degenerate extents and very short beam (L/8 dominates)" begin
        fix = _per_station_fixture()

        # Zero-extent (pinched) tributary segment ⇒ b_eff from the other side only.
        pinched = SideExtentProfile([0.0, 0.5, 1.0], [1.0, 0.0, 1.0])
        L = 40.0u"m"
        @test isapprox(b_eff_at_station(fix.slab, L, 0.5; left = pinched, right = nothing),
                       ustrip(u"m", fix.slab.beam_spacing_right / 2) * u"m"; rtol = 1e-9)

        # Very short beam: L/8 caps BOTH sides everywhere ⇒ b_eff = 2·(L/8).
        Lshort = 2.0u"m"                       # L/8 = 0.25 m ≪ extents
        wide = SideExtentProfile(5.0)
        @test isapprox(b_eff_at_station(fix.slab, Lshort, 0.5; left = wide, right = wide),
                       2 * (Lshort / 8); rtol = 1e-9)
    end
end

# ==============================================================================
# Sizing payload — governing sagging station reduces to the scalar checker
# ==============================================================================

@testset "Per-station sizing payload reduces to scalar Chapter I" begin
    fix = _per_station_fixture()
    L = 30.0u"ft"
    # Per-side extent = half the fixture spacing, so §I3.1a matches get_b_eff.
    d_m = ustrip(u"m", fix.slab.beam_spacing_left / 2)
    left = SideExtentProfile(d_m)
    right = SideExtentProfile(d_m)
    M_peak = 200.0u"kip*ft"
    demand = _parabolic_M(M_peak)

    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 51.0u"ksi",
                              490.0u"lb/ft^3")
    ctx = CompositeContext(fix.slab, anchor, L; shored = false, Lb_const = 10.0u"ft")

    checker = AISCChecker(; deflection_limit = nothing, total_deflection_limit = nothing,
                          max_depth = Inf)
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, [fix.section], fix.material, MinWeight())
    ϕMnx_steel = StructuralSizer._get_ϕMnx_cached!(cache, 1, ustrip(u"m", L), 1.0,
                                                   fix.section, fix.material, checker.ϕ_b)

    g = governing_sagging_station(fix.section, fix.material, fix.slab, L, demand, ϕMnx_steel;
                                  left = left, right = right, ϕ = checker.ϕ_b)
    @test isapprox(g.s_star, 0.5; atol = 1e-3)
    @test isapprox(g.b_eff, get_b_eff(fix.slab, L); rtol = 1e-9)
    @test isapprox(g.M_pos, ustrip(u"N*m", uconvert(u"N*m", M_peak)); rtol = 1e-8)

    # Restuffed spacings reproduce the same total width through scalar get_b_eff.
    st = CompositeSaggingStation(g.b_eff, g.M_pos * u"N*m", g.spacing_left, g.spacing_right)
    ctx_st = context_at_sagging_station(ctx, st)
    @test isapprox(get_b_eff(ctx_st.slab, ctx_st.L_beam), g.b_eff; rtol = 1e-9)

    M_Nm = ustrip(u"N*m", uconvert(u"N*m", M_peak))
    geom = SteelMemberGeometry(L; Lb = L)
    demand_env = MemberDemand(1; Mux = M_Nm, Mux_pos = M_Nm, Mux_neg = 0.0,
                              Vu_strong = ustrip(u"N", uconvert(u"N", 20.0u"kip")))
    field = BeamSaggingField(left, right, demand, Float64[0.0, 1.0])
    psc = PerStationComposite(ctx, [field])

    ok_scalar = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                            demand_env, geom, ctx)
    ok_station = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                             demand_env, geom, psc)
    @test ok_scalar == ok_station

    # A huge final envelope is not the pre-cure demand. Sagging on the station
    # path uses the station moment, so the group stays feasible. The scalar
    # path still rejects that envelope as positive flexure.
    huge = ustrip(u"N*m", uconvert(u"N*m", 8000.0u"kip*ft"))
    demand_huge = MemberDemand(1; Mux = huge, Mux_pos = huge, Mux_neg = 0.0, Vu_strong = 0.0)
    @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                      demand_huge, geom, psc) == true
    @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                      demand_huge, geom, ctx) == false
end

# =============================================================================
# §I3.2b — the station check and the sizing checker use one hogging strength
# =============================================================================

@testset "Station hogging strength matches the sizing checker" begin
    fix = _per_station_fixture()
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 51.0u"ksi",
                              490.0u"lb/ft^3")
    Asr = 2.0u"inch^2"
    Fysr = 60.0ksi
    ΣQn = 292.0kip
    Lp = get_Lp_Lr(fix.section, fix.material).Lp
    M = -100.0kip * u"ft"

    function both(L, neg_moment)
        ctx = CompositeContext(fix.slab, anchor, L; shored = true,
                               Asr = Asr, Fysr = Fysr, neg_moment = neg_moment,
                               ΣQn_neg = ΣQn)
        station = composite_dcr_at_station(fix.section, fix.material, fix.slab, L, 0.0,
                                           M, ΣQn; Asr = Asr, Fysr = Fysr,
                                           neg_moment = neg_moment, ΣQn_neg = ΣQn)
        checker = AISCChecker(; deflection_limit = nothing,
                              total_deflection_limit = nothing, max_depth = Inf)
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [fix.section],
                                               fix.material, MinWeight())
        geom = SteelMemberGeometry(L; Lb = L)
        ϕ_check = StructuralSizer._composite_ϕMn_neg(checker, cache, 1, fix.section,
                                                     fix.material, geom, ctx)
        return station.ϕMn, ϕ_check * u"N*m"
    end

    # Span longer than Lp: anchors and rebar do not open the plastic alternative.
    ϕs, ϕc = both(4 * Lp, true)
    ϕF = get_ϕMn(fix.section, fix.material; Lb = 4 * Lp, Cb = 1.0, axis = :strong)
    @test isapprox(ϕs, ϕc; rtol = 1e-9)
    @test isapprox(ϕs, ϕF; rtol = 1e-9)

    # Rebar without negative-region anchors stays on Chapter F.
    ϕs2, ϕc2 = both(Lp / 2, false)
    ϕF2 = get_ϕMn(fix.section, fix.material; Lb = Lp / 2, Cb = 1.0, axis = :strong)
    @test isapprox(ϕs2, ϕc2; rtol = 1e-9)
    @test isapprox(ϕs2, ϕF2; rtol = 1e-9)

    # Compact, braced, anchored, and developed: both paths take the composite value.
    ϕs3, ϕc3 = both(Lp / 2, true)
    @test isapprox(ϕs3, ϕc3; rtol = 1e-9)
    @test ϕs3 > ϕF2
end

# =============================================================================
# §I3.1a — a group's summed length must not widen L/8
# =============================================================================

@testset "Own-span L/8 rejects a section the summed length would accept" begin
    fix = _per_station_fixture(; bsl = 20.0u"ft", bsr = 20.0u"ft")
    L_own = 16.0u"ft"
    L_sum = 80.0u"ft"
    # 10 ft of tributary on each side. Own-span L/8 is 2 ft; the sum's L/8 is 10 ft.
    side = SideExtentProfile(ustrip(u"m", 10.0u"ft"))
    b_own = b_eff_at_station(fix.slab, L_own, 0.5; left = side, right = side)
    b_sum = b_eff_at_station(fix.slab, L_sum, 0.5; left = side, right = side)
    @test isapprox(b_own, 4.0u"ft"; rtol = 1e-6)
    @test isapprox(b_sum, 20.0u"ft"; rtol = 1e-6)

    Σ_own = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_own)
    Σ_sum = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_sum)
    ϕ_own = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_own, Σ_own).ϕMn
    ϕ_sum = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_sum, Σ_sum).ϕMn
    @test ϕ_own < ϕ_sum
    Mu = (ϕ_own + ϕ_sum) / 2
    demand = _ -> Mu

    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 51.0u"ksi",
                              490.0u"lb/ft^3")
    # The context carries the summed length, as a framing-level group does.
    ctx = CompositeContext(fix.slab, anchor, L_sum; shored = true)
    checker = AISCChecker(; deflection_limit = nothing,
                          total_deflection_limit = nothing, max_depth = Inf)
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, [fix.section],
                                           fix.material, MinWeight())
    geom = SteelMemberGeometry(L_own; Lb = L_own)
    env = MemberDemand(1; Mux = 0.0, Mux_pos = 0.0, Mux_neg = 0.0,
                       Vu_strong = ustrip(u"N", 1.0u"N"))

    field_own = BeamSaggingField(side, side, demand, Float64[0.0, 1.0], L_own, nothing)
    field_sum = BeamSaggingField(side, side, demand, Float64[0.0, 1.0], L_sum, nothing)
    ok_own = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                         env, geom, PerStationComposite(ctx, [field_own]))
    ok_sum = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                         env, geom, PerStationComposite(ctx, [field_sum]))
    @test ok_own == false
    @test ok_sum == true

    # One 80 ft member over four interior supports: five 16 ft bays. Each
    # station's L/8 is the bay's, so the member fails like the single bay.
    bays = [0.2, 0.4, 0.6, 0.8]
    field_bays = BeamSaggingField(side, side, demand, Float64[0.0, 1.0], L_sum, nothing;
                                  supports = bays)
    ok_bays = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          env, geom, PerStationComposite(ctx, [field_bays]))
    @test ok_bays == false
end

# =============================================================================
# §I3.1a — span between supports (AISC 360-22 §I3.1a(a), PDF p. 168)
# =============================================================================

@testset "Span at a station is the support-to-support bay" begin
    L = 30.0u"ft"
    @test span_at_station(L, 0.3, Float64[]) == L
    # Bays 0–0.4, 0.4–1.0 → 12 ft and 18 ft.
    @test span_at_station(L, 0.1, [0.4]) ≈ 12.0u"ft"
    @test span_at_station(L, 0.7, [0.4]) ≈ 18.0u"ft"
    # On the support: the smaller adjacent bay.
    @test span_at_station(L, 0.4, [0.4]) ≈ 12.0u"ft"
    @test span_at_station(L, 0.0, [0.4]) ≈ 12.0u"ft"
    @test span_at_station(L, 1.0, [0.4]) ≈ 18.0u"ft"

    # Width follows the bay: per-side L/8 of 12 ft is 1.5 ft, of 18 ft 2.25 ft.
    fix = _per_station_fixture(; bsl = 20.0u"ft", bsr = 20.0u"ft")
    @test b_eff_at_station(fix.slab, L, 0.1; supports = [0.4]) ≈ 3.0u"ft"
    @test b_eff_at_station(fix.slab, L, 0.7; supports = [0.4]) ≈ 4.5u"ft"

    @test_throws ArgumentError BeamSaggingField(nothing, nothing, _ -> 0.0, [0.0, 1.0],
                                                L, nothing; supports = [1.0])
end

# =============================================================================
# §I8.2c / Eq. C-I3-1 — each sagging region has its own anchors
# =============================================================================

@testset "Each sagging region keeps its own studs" begin
    # Two positive lobes and a negative gap. The short lobe is [0, 0.08].
    shape(s) = 0.0 <= s <= 0.08 ? sin(π * s / 0.08) :
               0.20 <= s <= 1.0 ? sin(π * (s - 0.20) / 0.80) : -1.0
    # 1 N·m is the zero band, so the shape has to be a real moment.
    regions = positive_moment_regions(s -> 1.0e6 * shape(float(s)))
    @test length(regions) == 2
    @test regions[1].s_left ≈ 0.0 atol = 1e-2
    @test regions[1].s_right ≈ 0.08 atol = 1e-2
    @test regions[2].s_left ≈ 0.20 atol = 1e-2
    @test regions[2].s_right ≈ 1.0 atol = 1e-2
    # 60 ft member: the short lobe is under 5 ft, the long lobe is over 15 ft.
    @test maximum(region_shear_spans(regions[1], 60.0u"ft")) < 5.0u"ft"
    @test maximum(region_shear_spans(regions[2], 60.0u"ft")) > 15.0u"ft"

    fix = _per_station_fixture()
    L = 60.0u"ft"
    b_eff = get_b_eff(fix.slab, L)
    Cf = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
    Mu = 0.85 * get_ϕMn_composite(fix.section, fix.material, fix.slab, b_eff, Cf).ϕMn
    demand(s) = Mu * shape(float(s))
    long_only(s) = (ss = float(s); 0.20 <= ss <= 1.0 ? Mu * sin(π * (ss - 0.20) / 0.80) :
                                     -0.01 * Mu)

    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 51.0u"ksi",
                              490.0u"lb/ft^3")
    ctx = CompositeContext(fix.slab, anchor, L; shored = true)
    checker = AISCChecker(; deflection_limit = nothing,
                          total_deflection_limit = nothing, max_depth = Inf)
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, [fix.section],
                                           fix.material, MinWeight())
    geom = SteelMemberGeometry(L; Lb = L)
    env = MemberDemand(1; Mux = 0.0, Mux_pos = 0.0, Mux_neg = 0.0,
                       Vu_strong = ustrip(u"N", 1.0u"N"))
    both = BeamSaggingField(nothing, nothing, demand, Float64[0.0, 1.0], L, nothing)
    only_long = BeamSaggingField(nothing, nothing, long_only, Float64[0.0, 1.0], L, nothing)
    ok(field) = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                            env, geom, PerStationComposite(ctx, [field]))
    # The long bay can carry Mu. The short bay cannot fit the anchors Mu needs,
    # so the member fails even though the larger bay passes on its own.
    @test ok(only_long) == true
    @test ok(both) == false

    # The station inertia uses the anchors of the region it sits in.
    # Hogging uses the cracked section, not either bay's I_LB.
    moment(s) = 1.0e6 * shape(float(s))
    Σ(region) = region.s_peak < 0.5 ? 20.0u"kip" : Cf
    I_short = composite_inertia_at_station(fix.section, fix.material, fix.slab, L,
                                           0.04, moment, Σ)
    I_long = composite_inertia_at_station(fix.section, fix.material, fix.slab, L,
                                          0.60, moment, Σ)
    I_hog = composite_inertia_at_station(fix.section, fix.material, fix.slab, L,
                                         0.14, moment, Σ;
                                         Asr = 1.0u"inch^2", d_rebar = 3.0u"inch")
    @test I_short > fix.section.Ix
    @test I_long > I_short
    @test I_hog ≈ get_I_cracked_negative(fix.section, 1.0u"inch^2"; d_rebar = 3.0u"inch")
end
