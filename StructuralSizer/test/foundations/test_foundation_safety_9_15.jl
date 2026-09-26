# Items 9–15 / leftovers: edge punching orientation, eccentric soil,
# tensile interface steel, γf both axes, Ie source label, FEA :area coerce.
# Citations: ACI 318-11, ACI 336.2R, ACI 435R-95 (Ie weights not in corpus).

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "Foundation / slab safety items 9–15" begin

    @testset "10: edge punching orients c1 perp to free edge" begin
        # Rectangular edge column: named c1=12 in, c2=24 in; free edge // named c1.
        # ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211): ACI c1 is
        # the dimension perp to the free edge ⇒ named c2 = 24 in.
        c1 = 12.0u"inch"
        c2 = 24.0u"inch"
        d  = 6.0u"inch"
        fc = 4000.0u"psi"
        Vu = 50.0kip
        Mux = 80.0kip * u"ft"   # moment about axis // named c1 (// free edge)
        Muy = 10.0kip * u"ft"

        ori = SS._orient_edge_column(c1, c2, Mux, Muy; free_edge_parallel = :c1)
        @test ori.c1 == c2
        @test ori.c2 == c1
        @test ori.M_edge == Mux
        # Default :c2 must not swap — guards over-correction of the named axes.
        ori_default = SS._orient_edge_column(c1, c2, Mux, Muy)
        @test ori_default.c1 == c1
        @test ori_default.c2 == c2

        pch = punching_check(Vu, Mux, Muy, d, fc, c1, c2;
                             position = :edge, free_edge_parallel = :c1)
        geom_correct = SS.punching_geometry_edge(c2, c1, d)  # ACI c1 = 24 in
        @test pch.geom.b1 ≈ geom_correct.b1 rtol=1e-12
        @test pch.geom.b2 ≈ geom_correct.b2 rtol=1e-12
        @test pch.geom.b0 ≈ geom_correct.b0 rtol=1e-12

        geom_wrong = SS.punching_geometry_edge(c1, c2, d)    # unswapped
        @test pch.geom.b1 != geom_wrong.b1
        @test pch.geom.b0 != geom_wrong.b0
        # Old path: default :c2 (no swap) yields a different b0 and utilization.
        pch_old = punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :edge)
        @test pch.geom.b0 != pch_old.geom.b0
        @test pch.utilization != pch_old.utilization
    end

    @testset "P0: default :c2 keeps governing Mux=80 not leftover Muy=10" begin
        # Production oracle: punching_check(..., position=:edge) with no
        # free_edge_parallel must use transfer moment 80 kip·ft, not 10.
        # Default / inferred :c2 previously selected any nonzero Muy.
        c1 = 12.0u"inch"
        c2 = 24.0u"inch"
        d  = 6.0u"inch"
        h  = 8.0u"inch"
        fc = 4000.0u"psi"
        Vu = 50.0kip
        Mux = 80.0kip * u"ft"
        Muy = 10.0kip * u"ft"

        ori = SS._orient_edge_column(c1, c2, Mux, Muy)
        @test ori.c1 == c1
        @test ori.c2 == c2
        @test ori.M_edge == Mux

        pch = punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :edge)
        pch_gov = punching_check(Vu, Mux, zero(Muy), d, fc, c1, c2; position = :edge)
        pch_left = punching_check(Vu, zero(Mux), Muy, d, fc, c1, c2; position = :edge)
        @test pch.utilization ≈ pch_gov.utilization rtol=1e-12
        @test pch.utilization > pch_left.utilization
        @test pch.geom.b0 ≈ pch_gov.geom.b0 rtol=1e-12

        # Slab kernel infers :c2 (empty boundary_edge_dirs) — same oracle.
        col = (position = :edge, c1 = c1, c2 = c2, shape = :rectangular)
        r_slab = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = Muy)
        @test ustrip(u"psi", r_slab.vu) ≈ ustrip(u"psi", pch.vu) rtol=1e-9
    end

    @testset "P1: :c1 keeps geometry swap and governing |Muy|=130" begin
        # Production :c1 previously returned M_edge = Mux and dropped Muy.
        # After any c1↔c2 swap, M_edge is still max(|Mux|, |Muy|).
        c1 = 12.0u"inch"
        c2 = 24.0u"inch"
        d  = 6.0u"inch"
        fc = 4000.0u"psi"
        Vu = 50.0kip
        Mux = 10.0kip * u"ft"
        Muy = 130.0kip * u"ft"

        ori = SS._orient_edge_column(c1, c2, Mux, Muy; free_edge_parallel = :c1)
        @test ori.c1 == c2
        @test ori.c2 == c1
        @test ori.M_edge == Muy

        pch = punching_check(Vu, Mux, Muy, d, fc, c1, c2;
                             position = :edge, free_edge_parallel = :c1)
        geom_swapped = SS.punching_geometry_edge(c2, c1, d)  # ACI c1 = 24 in
        @test ustrip(u"inch", pch.geom.b0) ≈ 72.0 rtol=1e-12
        @test pch.geom.b0 ≈ geom_swapped.b0 rtol=1e-12
        geom_unswapped = SS.punching_geometry_edge(c1, c2, d)
        @test ustrip(u"inch", geom_unswapped.b0) ≈ 60.0 rtol=1e-12
        @test pch.geom.b0 != geom_unswapped.b0

        pch_gov = punching_check(Vu, Muy, zero(Mux), d, fc, c2, c1; position = :edge)
        pch_drop = punching_check(Vu, Mux, zero(Muy), d, fc, c2, c1; position = :edge)
        @test pch.utilization ≈ pch_gov.utilization rtol=1e-12
        @test pch.utilization > pch_drop.utilization
    end

    @testset "P1: mat bottom-edge passes :c1 (12×24 → b0=72)" begin
        # Bottom/top = free edge along local x → free_edge_parallel=:c1.
        # Named c1=12, c2=24, d=6 → ACI c1=24, b0=72 (not unswapped 60).
        c1 = 12.0u"inch"
        c2 = 24.0u"inch"
        d  = 6.0u"inch"
        fc = 4000.0u"psi"
        Mux = 80.0kip * u"ft"
        Muy = 10.0kip * u"ft"
        qu = 2.0u"kip/ft^2"
        Pu = 100.0kip
        λ = 1.0
        ϕv = 0.75

        demand = FoundationDemand(1; Pu=Pu, Ps=Pu, Mux=Mux, Muy=Muy, c1=c1, c2=c2)
        # ys_loc < half_crit+tol (1.25+0.5=1.75 ft) → bottom; mid-width → not left/right.
        plan = (B=10.0u"ft", Lm=8.0u"ft", xs_loc=[5.0u"ft"], ys_loc=[0.4u"ft"])
        # :c1 swaps named axes: Ac = (named_c2 + d/2)×(named_c1 + d)
        Ac = (c2 + d / 2) * (c1 + d)
        Vu_p = max(uconvert(u"lbf", Pu - qu * Ac), 0.0u"lbf")

        pch_c1 = punching_check(Vu_p, Mux, Muy, d, fc, c1, c2;
                                position = :edge, free_edge_parallel = :c1)
        pch_c2 = punching_check(Vu_p, Mux, Muy, d, fc, c1, c2; position = :edge)
        @test ustrip(u"inch", pch_c1.geom.b0) ≈ 72.0 rtol=1e-12
        @test ustrip(u"inch", pch_c2.geom.b0) ≈ 60.0 rtol=1e-12

        util = SS._mat_punching_util([demand], plan, qu, d, fc, λ, ϕv)
        @test util ≈ pch_c1.utilization rtol=1e-12
        @test util != pch_c2.utilization
    end

    @testset "P1: mat 24×12 bottom-edge swaps Ac (450 not 486)" begin
        # Named c1=24, c2=12, d=6, bottom edge (:c1). Unswapped named-axis
        # Ac = (24+3)×(12+6) = 486 in² understates Vu_p. Swapped ACI axes:
        # Ac = (named_c2 + d/2)×(named_c1 + d) = (12+3)×(24+6) = 450 in².
        # ACI 318-11 §11.11.1.2 / R11.11.7.2 (corpus: aci-318-11, pages 200, 209–211).
        c1 = 24.0u"inch"
        c2 = 12.0u"inch"
        d  = 6.0u"inch"
        fc = 4000.0u"psi"
        Mux = 80.0kip * u"ft"
        Muy = 10.0kip * u"ft"
        qu = 2.0u"kip/ft^2"
        Pu = 100.0kip
        λ = 1.0
        ϕv = 0.75

        demand = FoundationDemand(1; Pu=Pu, Ps=Pu, Mux=Mux, Muy=Muy, c1=c1, c2=c2)
        plan = (B=10.0u"ft", Lm=8.0u"ft", xs_loc=[5.0u"ft"], ys_loc=[0.4u"ft"])

        Ac_named = (c1 + d / 2) * (c2 + d)
        Ac_swap  = (c2 + d / 2) * (c1 + d)
        @test ustrip(u"inch^2", Ac_named) ≈ 486 rtol=1e-12
        @test ustrip(u"inch^2", Ac_swap)  ≈ 450 rtol=1e-12

        Vu_swap  = max(uconvert(u"lbf", Pu - qu * Ac_swap),  0.0u"lbf")
        Vu_named = max(uconvert(u"lbf", Pu - qu * Ac_named), 0.0u"lbf")
        @test Vu_swap > Vu_named

        pch_swap = punching_check(Vu_swap, Mux, Muy, d, fc, c1, c2;
                                  position = :edge, free_edge_parallel = :c1)
        pch_under = punching_check(Vu_named, Mux, Muy, d, fc, c1, c2;
                                   position = :edge, free_edge_parallel = :c1)
        util = SS._mat_punching_util([demand], plan, qu, d, fc, λ, ϕv)
        @test util ≈ pch_swap.utilization rtol=1e-12
        @test util > pch_under.utilization

        # Left/right :c2 keeps named-axis Ac; corner stays 2-sided.
        plan_left = (B=10.0u"ft", Lm=8.0u"ft", xs_loc=[0.4u"ft"], ys_loc=[4.0u"ft"])
        Ac_left = (c1 + d / 2) * (c2 + d)
        Vu_left = max(uconvert(u"lbf", Pu - qu * Ac_left), 0.0u"lbf")
        pch_left = punching_check(Vu_left, Mux, Muy, d, fc, c1, c2; position = :edge)
        @test SS._mat_punching_util([demand], plan_left, qu, d, fc, λ, ϕv) ≈
              pch_left.utilization rtol=1e-12

        plan_corner = (B=10.0u"ft", Lm=8.0u"ft", xs_loc=[0.3u"ft"], ys_loc=[0.3u"ft"])
        Ac_corner = (c1 + d / 2) * (c2 + d / 2)
        Vu_corner = max(uconvert(u"lbf", Pu - qu * Ac_corner), 0.0u"lbf")
        pch_corner = punching_check(Vu_corner, Mux, Muy, d, fc, c1, c2; position = :corner)
        @test SS._mat_punching_util([demand], plan_corner, qu, d, fc, λ, ϕv) ≈
              pch_corner.utilization rtol=1e-12
    end

    @testset "P1: Y-strip free end along named c1 → :c1" begin
        # Columns at (0,0) and (0, 20 ft): Δy>Δx → Y-layout. Named c1=12 (X),
        # c2=24 (Y). Free end along X = named c1 → :c1 so ACI c1 = named c2.
        # X-layout keeps :c2. Do not invent a swap.
        @test SS._strip_free_edge_parallel(:y) === :c1
        @test SS._strip_free_edge_parallel(:x) === :c2
        @test_throws ArgumentError SS._strip_free_edge_parallel(:z)

        c1 = 12.0u"inch"
        c2 = 24.0u"inch"
        d  = 6.0u"inch"
        Ac_y = SS._strip_edge_Ac(c1, c2, d, true, :c1)
        Ac_x = SS._strip_edge_Ac(c1, c2, d, true, :c2)
        @test Ac_y ≈ (c2 + d / 2) * (c1 + d) rtol=1e-12
        @test Ac_x ≈ (c1 + d / 2) * (c2 + d) rtol=1e-12
        @test SS._strip_edge_Ac(c1, c2, d, false, :c1) ≈ (c1 + d) * (c2 + d) rtol=1e-12

        @test SS._strip_c_across_along(c1, c2, :y) == (c1, c2)
        @test SS._strip_c_across_along(c1, c2, :x) == (c2, c1)
        @test_throws ArgumentError SS._strip_c_across_along(c1, c2, :z)
    end

    @testset "11: eccentric soil q_max = 2 qu at e = L/6" begin
        # ACI 336.2R §3.2.1 Eq. (3-1) (corpus: aci-336-combined-footings-mats, page 6)
        P  = 100.0kip
        B  = 10.0u"ft"
        L  = 10.0u"ft"
        ex = L / 6
        Mux = P * ex
        q = SS._eccentric_soil_pressure(P, Mux, 0.0kip * u"ft", B, L)
        @test q.q_max ≈ 2 * q.qu rtol=1e-10
        @test (q.q_max / q.qu) ≈ 2.0 rtol=1e-10
        @test q.q_min ≈ 0 * q.qu atol=1e-8 * q.qu
        @test q.ex ≈ ex rtol=1e-12
        # Old path: concentric P/A only would give q_max/qu = 1.
        q0 = SS._eccentric_soil_pressure(P, 0.0kip * u"ft", 0.0kip * u"ft", B, L)
        @test q0.q_max ≈ q0.qu rtol=1e-12
        @test q.q_max ≈ 2 * q0.qu rtol=1e-10
    end

    @testset "P0: Mux = −P L/6 still gives q_max/qu = 2" begin
        # ACI 336.2R §3.2.1 Eq. (3-1) (corpus: aci-336-combined-footings-mats,
        # page 6): q_max,min = (P/A)(1 ± 6e/Z).  Peak uses |e| so signed ASAP
        # Mux cannot report the unloaded edge as q_max.
        P  = 100.0kip
        B  = 10.0u"ft"
        L  = 10.0u"ft"
        Mux = -(P * (L / 6))
        q = SS._eccentric_soil_pressure(P, Mux, 0.0kip * u"ft", B, L)
        @test (q.q_max / q.qu) ≈ 2.0 rtol=1e-10
        @test q.q_min ≈ 0 * q.qu atol=1e-8 * q.qu
        @test q.ex ≈ Mux / P rtol=1e-12
        # +e oracle still holds (item 11); signs must not invert the peak.
        q_pos = SS._eccentric_soil_pressure(P, -Mux, 0.0kip * u"ft", B, L)
        @test (q_pos.q_max / q_pos.qu) ≈ 2.0 rtol=1e-10
        @test q.q_max ≈ q_pos.q_max rtol=1e-12
    end

    @testset "leftover: As_tensile stored on mixed-sign strip" begin
        # ACI 318-11 §15.8.1.2(b) (corpus: aci-318-11, page 275)
        d1 = FoundationDemand(1; Pu=400.0u"kN", Ps=400.0u"kN",
                              c1=18.0u"inch", c2=18.0u"inch")
        d2 = FoundationDemand(2; Pu=-200.0u"kN", Ps=-200.0u"kN",
                              c1=18.0u"inch", c2=18.0u"inch")
        soil = Soil(50.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StripParams(min_depth=12.0u"inch")
        result = design_footing(StripFooting(), [d1, d2], [0.0u"ft", 20.0u"ft"], soil; opts)
        @test hasproperty(result, :As_tensile)
        As_oracle = abs(d2.Pu) / (opts.ϕ_bearing * opts.material.rebar.Fy)
        @test result.As_tensile ≈ uconvert(u"m^2", As_oracle) rtol=1e-8
        @test ustrip(u"inch^2", result.As_tensile) > 0
    end

    @testset "leftover: γf transfer uses governing of Mux and Muy" begin
        # ACI 318-11 §13.5.3.1 / Eq. 13-1 (corpus: aci-318-11, page 250)
        Mux = 23.0kip * u"ft"
        Muy = 130.0kip * u"ft"
        c1 = 20.0u"inch"
        c2 = 30.0u"inch"
        h  = 8.0u"inch"
        d  = 6.5u"inch"
        fc = 4000.0u"psi"
        fy = 60.0ksi
        gov = SS.governing_transfer_reinforcement(Mux, Muy, c1, c2, h, d, fc, fy;
                                                  position = :edge)
        @test gov.Mu == Muy
        As_x_only = SS.governing_transfer_reinforcement(Mux, 0.0kip * u"ft",
            c1, c2, h, d, fc, fy; position = :edge)
        @test ustrip(u"inch^2", gov.As) > ustrip(u"inch^2", As_x_only.As)
    end

    @testset "P1: Y-strip one-way shear uses along-strip c2 face" begin
        # 24×12 Y-strip: along-strip face is c2/2 = 6 in, not c1/2 = 12 in.
        # ACI 318-11 §11.1.3.1 (corpus: aci-318-11, page 166): Vu at d from face.
        # Stations between d+6 in and d+12 in from center were skipped.
        c1 = 24.0u"inch"
        c2 = 12.0u"inch"
        d  = 16.0u"inch"
        L  = 22.0u"ft"
        B  = 6.0u"ft"
        qu = 2.0u"kip/ft^2"
        col_pos = [1.0u"ft", 21.0u"ft"]
        Pu = [200.0kip, 200.0kip]
        diag = SS._strip_VM_diagram(L, B, qu, col_pos, Pu)
        d_ft = ustrip(u"ft", d)
        xc0 = ustrip(u"ft", col_pos[1])
        face_y = ustrip(u"ft", c2 / 2)
        face_x = ustrip(u"ft", c1 / 2)
        vu_max(face) = begin
            vmax = 0.0
            for (i, x) in enumerate(diag.x_ft)
                min_dist = minimum(abs(x - ustrip(u"ft", col_pos[j])) - face
                                   for j in 1:2)
                if min_dist ≥ d_ft - 0.01
                    vmax = max(vmax, abs(diag.V_kip[i]))
                end
            end
            vmax
        end
        @test vu_max(face_y) > vu_max(face_x)
        x_gap = xc0 + d_ft + ustrip(u"ft", 9.0u"inch")
        @test (x_gap - xc0 - face_y) ≥ d_ft - 0.01
        @test (x_gap - xc0 - face_x) <  d_ft - 0.01
    end

    @testset "P1: transfer γf orients edge c1/c2 before b1/b2/bb" begin
        # South-edge, boundary_edge_dirs≈(1,0) → inferred :c1. Named c1=24 in,
        # c2=12 in, d=6.5 in, h=8 in, nonzero Mux. Unoriented γf≈0.55;
        # oriented (ACI c1=12) γf≈0.68 — ~19% low Mu_transfer without the swap.
        # ACI 318-11 §13.5.3.2 Eq. (13-1) / R11.11.7.2 (corpus: aci-318-11,
        # pages 250, 209–211).
        Mux = 80.0kip * u"ft"
        Muy = 0.0kip * u"ft"
        c1 = 24.0u"inch"
        c2 = 12.0u"inch"
        h  = 8.0u"inch"
        d  = 6.5u"inch"
        fc = 4000.0u"psi"
        fy = 60.0ksi
        col = (position = :edge, c1 = c1, c2 = c2,
               boundary_edge_dirs = [(1.0, 0.0)], θ = 0.0)
        @test SS._infer_free_edge_parallel(col) === :c1

        gov_old = SS.governing_transfer_reinforcement(
            Mux, Muy, c1, c2, h, d, fc, fy; position = :edge)
        @test gov_old.γf ≈ SS.gamma_f(c1 + d / 2, c2 + d) rtol=1e-12
        @test gov_old.γf ≈ 0.55 atol=0.02

        gov = SS.governing_transfer_reinforcement(
            Mux, Muy, c1, c2, h, d, fc, fy; position = :edge,
            free_edge_parallel = SS._infer_free_edge_parallel(col))
        @test gov.γf ≈ SS.gamma_f(c2 + d / 2, c1 + d) rtol=1e-12
        @test gov.γf ≈ 0.68 atol=0.02
        @test gov.γf > gov_old.γf
        @test ustrip(u"inch^2", gov.As) > ustrip(u"inch^2", gov_old.As)
        @test gov.bb ≈ c1 + 1.5h rtol=1e-12
        @test gov_old.bb ≈ c2 + 1.5h rtol=1e-12

        # Interior is not swapped even if :c1 is passed.
        gov_int = SS.governing_transfer_reinforcement(
            Mux, Muy, c1, c2, h, d, fc, fy; position = :interior,
            free_edge_parallel = :c1)
        gov_int_def = SS.governing_transfer_reinforcement(
            Mux, Muy, c1, c2, h, d, fc, fy; position = :interior)
        @test gov_int.γf ≈ gov_int_def.γf rtol=1e-12
        @test gov_int.As ≈ gov_int_def.As rtol=1e-12
    end

    @testset "relabel: weighted Ie is 435R-95, not §9.5.2.4 simple average" begin
        # ACI 318-11 §9.5.2.4 (corpus: aci-318-11, page 132) = simple average.
        # Implemented weights are ACI 435R-95 Eq. 4-1a (not in corpus).
        Ie_m = 100.0
        Ie_s = 400.0
        Ie_w = weighted_effective_Ie(Ie_m, Ie_s, Ie_s; position = :interior)
        @test Ie_w ≈ 0.70 * Ie_m + 0.15 * (Ie_s + Ie_s) rtol=1e-12
        simple_avg = (Ie_m + Ie_s) / 2
        @test Ie_w != simple_avg
    end

    @testset "13: FEA :area+:projection coerces to :wood_armer" begin
        fea = SS.FEA(design_approach = :area, moment_transform = :projection)
        @test fea.design_approach == :area
        @test fea.moment_transform == :wood_armer
    end

    @testset "P1: 12×36 Y-strip As_trans uses 24 in cantilever" begin
        # Y-strip, supports at 0 / 20 ft, named c1=12 in (∥ X = across),
        # c2=36 in (∥ Y = along), B=5 ft. Correct cant = (B−c1)/2 = 24 in;
        # old named-c2 cant = 12 in → Mu_trans ~4× low. Band width is
        # along-strip c2+d, not c1+d.
        # ACI 318-11 §15.4.1 / §15.4.2(a) (corpus: aci-318-11, pages 272–273).
        c1 = 12.0u"inch"
        c2 = 36.0u"inch"
        Pu = 80.0kip
        d1 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        d2 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        L_plan = 22.0u"ft"
        B_plan = 5.0u"ft"
        qa = (2 * Pu) / (B_plan * L_plan)
        soil = Soil(qa, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StripParams(min_depth=12.0u"inch")
        result = design_footing(StripFooting(), [d1, d2], [0.0u"ft", 20.0u"ft"], soil;
                               opts, strip_axis=:y)
        B = result.B
        d = result.d
        h = result.D
        L = result.L_ftg
        qu = (d1.Pu + d2.Pu) / (B * L)
        fc = opts.material.concrete.fc′
        fy = opts.material.rebar.Fy
        ϕf = opts.ϕ_flexure

        cant_y = (B - c1) / 2
        cant_old = (B - c2) / 2
        @test ustrip(u"inch", cant_y) ≈ 24.0 atol=3.0
        @test cant_y ≈ 2 * cant_old rtol=0.15

        band_w = c2 + d
        Mu_band = (qu * cant_y^2 / 2) * band_w
        As_oracle = max(SS._flexural_steel_footing(Mu_band, band_w, d, fc, fy, ϕf),
                        SS._min_steel_footing(band_w, h, fy))
        @test result.As_trans ≈ uconvert(u"m^2", As_oracle) rtol=1e-6

        band_w_old = c1 + d
        Mu_band_old = (qu * cant_old^2 / 2) * band_w_old
        As_old = max(SS._flexural_steel_footing(Mu_band_old, band_w_old, d, fc, fy, ϕf),
                     SS._min_steel_footing(band_w_old, h, fy))
        @test ustrip(u"inch^2", result.As_trans) > ustrip(u"inch^2", As_old)

        # X-layout (:x, default) keeps named-c2 across / named-c1 along.
        result_x = design_footing(StripFooting(), [d1, d2], [0.0u"ft", 20.0u"ft"], soil;
                                 opts, strip_axis=:x)
        Bx, dx, hx = result_x.B, result_x.d, result_x.D
        qu_x = (d1.Pu + d2.Pu) / (Bx * result_x.L_ftg)
        cant_x = (Bx - c2) / 2
        band_w_x = c1 + dx
        Mu_band_x = (qu_x * cant_x^2 / 2) * band_w_x
        As_x = max(SS._flexural_steel_footing(Mu_band_x, band_w_x, dx, fc, fy, ϕf),
                   SS._min_steel_footing(band_w_x, hx, fy))
        @test result_x.As_trans ≈ uconvert(u"m^2", As_x) rtol=1e-6

        # 24×12 Y-strip: across = named c1, along = named c2 (must not invert).
        d1_24 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=24.0u"inch", c2=12.0u"inch")
        d2_24 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=24.0u"inch", c2=12.0u"inch")
        result_24 = design_footing(StripFooting(), [d1_24, d2_24],
                                  [0.0u"ft", 20.0u"ft"], soil;
                                  opts, strip_axis=:y)
        B24, d24, h24 = result_24.B, result_24.d, result_24.D
        qu24 = (d1_24.Pu + d2_24.Pu) / (B24 * result_24.L_ftg)
        cant_24 = (B24 - 24.0u"inch") / 2
        band_w_24 = 12.0u"inch" + d24
        Mu_24 = (qu24 * cant_24^2 / 2) * band_w_24
        As_24 = max(SS._flexural_steel_footing(Mu_24, band_w_24, d24, fc, fy, ϕf),
                    SS._min_steel_footing(band_w_24, h24, fy))
        @test result_24.As_trans ≈ uconvert(u"m^2", As_24) rtol=1e-6
    end

    @testset "P1: high-qa 36×12 Y-strip floors B at c_across" begin
        # Y-strip, supports at 0 / 20 ft, named c1=36 in (∥ X = across),
        # c2=12 in (∥ Y = along), Pu=Ps=80 kip, qa=20 ksf. Soil B_min after
        # the 2 ft floor is 24 in < c_across; without the floor, cant_trans
        # is negative and Mu ∝ cant² still sizes a phantom cantilever.
        # Designed B must be ≥ 36 in; cant ≥ 0.
        c1 = 36.0u"inch"
        c2 = 12.0u"inch"
        Pu = 80.0kip
        d1 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        d2 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        soil = Soil(20.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StripParams(min_depth=12.0u"inch")
        result = design_footing(StripFooting(), [d1, d2], [0.0u"ft", 20.0u"ft"], soil;
                               opts, strip_axis=:y)
        @test result.B ≥ c1
        cant = (result.B - c1) / 2
        @test cant ≥ zero(cant)

        # ACI 318-11 §10.14.1 (corpus: aci-318-11, page 162): √(A2/A1) only
        # when the support is wider on all sides. Oracle uses B = c_across
        # (flush transverse edges). Designed B may exceed the floor for
        # shear (h/B); that is not the P1. Along-strip 4h alone must not
        # take the cap of 2.
        fc = opts.material.concrete.fc′
        fy = opts.material.rebar.Fy
        ϕb = opts.ϕ_bearing
        h_flush = 12.0u"inch"
        L_flush = 22.0u"ft"
        B_flush = c1
        c_across, c_along = SS._strip_c_across_along(c1, c2, :y)
        @test c_across == c1
        br_flush = SS._bearing_check_footing(
            Pu, c_along, c_across, B_flush, L_flush, h_flush,
            fc, fc, fy, ϕb, :rectangular)
        A1_flush = c_along * c_across
        Bn_sqA1 = ϕb * 0.85 * fc * A1_flush
        @test br_flush.sqA == 1.0
        @test br_flush.Bn_footing ≈ Bn_sqA1 rtol=1e-10
        A2_illegal = min(c_along + 4 * h_flush, L_flush) *
                     min(c_across + 4 * h_flush, B_flush)
        @test sqrt(A2_illegal / A1_flush) ≈ sqrt(5) atol=0.01
        @test min(sqrt(A2_illegal / A1_flush), 2.0) == 2.0
        @test br_flush.sqA != 2.0
        @test br_flush.Bn_footing ≉ 2 * Bn_sqA1

        # Happy path: 2 in projection on the across face and L longer than
        # the along face → wider on all sides → √ permitted, cap 2.
        B_wide = 40.0u"inch"
        @test B_wide > c_across && L_flush > c_along
        br_wide = SS._bearing_check_footing(
            Pu, c_along, c_across, B_wide, L_flush, h_flush,
            fc, fc, fy, ϕb, :rectangular)
        A2_wide = min(c_along + 4 * h_flush, L_flush) *
                  min(c_across + 4 * h_flush, B_wide)
        @test br_wide.sqA ≈ min(sqrt(A2_wide / A1_flush), 2.0) rtol=1e-10
        @test br_wide.sqA == 2.0
        @test br_wide.Bn_footing ≈ 2 * Bn_sqA1 rtol=1e-10

        # Helper A2 = min(c1+4h, Lf)*min(c2+4h, B) is named-axis (c1∥Lf, c2∥B).
        # Y-strip remaps: c_along=c2 pairs with L, c_across=c1 pairs with B.
        # Breaking: c1=36 in, c2=24 in, h=12 in, B=40 in → √(A2/A1)=1.83
        # (named-axis call gives 1.97, Bn ~8% high). Both faces project, so
        # §10.14.1 permits √.
        h_a2 = 12.0u"inch"
        B_a2 = 40.0u"inch"
        L_a2 = 22.0u"ft"
        c1_a2 = 36.0u"inch"
        c2_a2 = 24.0u"inch"
        A1 = c1_a2 * c2_a2
        A2_remap = min(c2_a2 + 4 * h_a2, L_a2) * min(c1_a2 + 4 * h_a2, B_a2)
        A2_named = min(c1_a2 + 4 * h_a2, L_a2) * min(c2_a2 + 4 * h_a2, B_a2)
        @test sqrt(A2_remap / A1) ≈ 1.83 atol=0.01
        @test sqrt(A2_named / A1) ≈ 1.97 atol=0.01
        br_remap = SS._bearing_check_footing(
            Pu, c2_a2, c1_a2, B_a2, L_a2, h_a2, fc, fc, fy, ϕb, :rectangular)
        br_named = SS._bearing_check_footing(
            Pu, c1_a2, c2_a2, B_a2, L_a2, h_a2, fc, fc, fy, ϕb, :rectangular)
        @test br_remap.sqA ≈ sqrt(A2_remap / A1) rtol=1e-10
        @test br_named.sqA ≈ sqrt(A2_named / A1) rtol=1e-10
        @test br_remap.Bn_footing / br_named.Bn_footing ≈
              sqrt(A2_remap / A1) / sqrt(A2_named / A1) rtol=1e-10

        # Circular diameter is named c1. Remapped c_along ≠ c1 must not
        # enter the cone (A1 would scale by (c_along/c1)²).
        D = 12.0u"inch"
        c2_uneq = 36.0u"inch"
        c_ac, c_al = SS._strip_c_across_along(D, c2_uneq, :y)
        @test c_al == c2_uneq
        br_circ = SS._bearing_check_footing(
            Pu, D, c2_uneq, D, L_flush, h_flush,
            fc, fc, fy, ϕb, :circular)
        A1_circ = π * (D / 2)^2
        @test br_circ.sqA == 1.0
        @test br_circ.Bn_footing ≈ ϕb * 0.85 * fc * A1_circ rtol=1e-10
        br_circ_remap = SS._bearing_check_footing(
            Pu, c_al, c_ac, D, L_flush, h_flush,
            fc, fc, fy, ϕb, :circular)
        @test br_circ.Bn_footing / br_circ_remap.Bn_footing ≈
              (D / c_al)^2 rtol=1e-10
        B_cwide = 40.0u"inch"
        @test min(B_cwide, L_flush) > D
        br_cwide = SS._bearing_check_footing(
            Pu, D, c2_uneq, B_cwide, L_flush, h_flush,
            fc, fc, fy, ϕb, :circular)
        A2_cwide = π * (min(D + 4 * h_flush, min(B_cwide, L_flush)) / 2)^2
        @test br_cwide.sqA ≈ min(sqrt(A2_cwide / A1_circ), 2.0) rtol=1e-10
        @test br_cwide.sqA == 2.0

        # End-flush station: B and L both exceed the loaded box, but the
        # along-face overhang is zero → not wider on all sides (sqA = 1).
        # Centered default would wrongly take the cap of 2.
        br_end = SS._bearing_check_footing(
            Pu, c_along, c_across, B_wide, L_flush, h_flush,
            fc, fc, fy, ϕb, :rectangular;
            col_along = c_along / 2)
        @test B_wide > c_across && L_flush > c_along
        @test br_end.sqA == 1.0
        @test br_end.Bn_footing ≈ Bn_sqA1 rtol=1e-10

        # Mixed units: SI B, L, h with inch column. sqrt must be a Float64
        # before min(..., 2) (centered happy path still caps at 2).
        br_si = SS._bearing_check_footing(
            Pu, c_along, c_across,
            uconvert(u"m", B_wide), uconvert(u"m", L_flush),
            uconvert(u"m", h_flush),
            fc, fc, fy, ϕb, :rectangular)
        @test br_si.sqA isa Float64
        @test br_si.sqA == 2.0
    end

    @testset "P1: end-flush 12×24 Y-strip production bearing uses sqA=1" begin
        # Breaking production path (not a helper stub with B = c_across):
        # Y-strip c1=12 in (across), c2=24 in (along), supports at 0 / 20 ft.
        # Plan parks each column 1 ft from the end → along overhang = 0.
        # Designed B and h grow past the column box; overall L ≫ c_along
        # must not take √(A2/A1). Circular twin (named c1 = D = 24 in) is
        # circumference-flush at the same station.
        c1 = 12.0u"inch"
        c2 = 24.0u"inch"
        Pu = 80.0kip
        soil = Soil(20.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StripParams(min_depth=12.0u"inch")
        fc = opts.material.concrete.fc′
        fy = opts.material.rebar.Fy
        ϕb = opts.ϕ_bearing
        positions = [0.0u"ft", 20.0u"ft"]

        d1 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        d2 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        result = design_footing(StripFooting(), [d1, d2], positions, soil;
                               opts, strip_axis=:y)
        c_across, c_along = SS._strip_c_across_along(c1, c2, :y)
        @test c_across == c1 && c_along == c2
        x_bar = (positions[1] + positions[2]) / 2
        col_along = positions[1] - (x_bar - result.L_ftg / 2)
        @test col_along ≈ c_along / 2 rtol=1e-10
        @test result.B > c_across
        @test result.L_ftg > c_along
        br_prod = SS._bearing_check_footing(
            Pu, c_along, c_across, result.B, result.L_ftg, result.D,
            fc, fc, fy, ϕb, :rectangular;
            col_along = col_along)
        A1 = c_along * c_across
        Bn_sqA1 = ϕb * 0.85 * fc * A1
        @test hasproperty(result, :sqA) && hasproperty(result, :Bn)
        @test result.sqA == 1.0
        @test br_prod.sqA == 1.0
        @test br_prod.Bn_footing ≈ Bn_sqA1 rtol=1e-10
        @test result.Bn ≈ uconvert(u"N", Bn_sqA1) rtol=1e-10
        @test br_prod.Bn_footing ≉ 2 * Bn_sqA1

        D = 24.0u"inch"
        dc1 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=D, c2=D, shape=:circular)
        dc2 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=D, c2=D, shape=:circular)
        result_c = design_footing(StripFooting(), [dc1, dc2], positions, soil;
                                 opts, strip_axis=:y)
        col_along_c = positions[1] - (x_bar - result_c.L_ftg / 2)
        @test col_along_c ≈ D / 2 rtol=1e-10
        @test result_c.B > D && result_c.L_ftg > D
        br_circ_prod = SS._bearing_check_footing(
            Pu, D, D, result_c.B, result_c.L_ftg, result_c.D,
            fc, fc, fy, ϕb, :circular;
            col_along = col_along_c)
        A1_circ = π * (D / 2)^2
        @test result_c.sqA == 1.0
        @test br_circ_prod.sqA == 1.0
        @test br_circ_prod.Bn_footing ≈ ϕb * 0.85 * fc * A1_circ rtol=1e-10
        @test result_c.Bn ≈ uconvert(u"N", ϕb * 0.85 * fc * A1_circ) rtol=1e-10
    end

    @testset "P0: mixed-unit flush station is sqA=1" begin
        # Production strip passes metre-promoted stations (col_pos_local
        # after SI round-trip), not only native 1.0u"ft". uconvert(inch, m)
        # is 0.3048/0.0254 = 12 + ~1.78e-15, not ×12, so left > 0 and Bn
        # doubles. ACI 318-11 §10.14.1 (corpus: aci-318-11, page 162): √
        # withheld unless wider on all sides. Overlap (0.999 ft) is also
        # not wider. 0.01 in leftover is still wider — not an ε-flush.
        Pu = 80.0kip
        opts = StripParams(min_depth=12.0u"inch")
        fc = opts.material.concrete.fc′
        fy = opts.material.rebar.Fy
        ϕb = opts.ϕ_bearing
        c1 = 24.0u"inch"   # helper along-face (named, or remapped Y-strip)
        c2 = 12.0u"inch"
        B = 40.0u"inch"
        L = 22.0u"ft"
        h = 12.0u"inch"
        A1 = c1 * c2
        Bn_sqA1 = ϕb * 0.85 * fc * A1

        br_flush = SS._bearing_check_footing(
            Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
            col_along = 1.0u"ft")
        @test br_flush.sqA == 1.0
        @test br_flush.sqA != 2.0
        @test br_flush.Bn_footing ≈ Bn_sqA1 rtol=1e-10
        @test br_flush.Bn_footing ≉ 2 * Bn_sqA1

        # (1) metre-promoted 1 ft station (production col_pos_local).
        br_m = SS._bearing_check_footing(
            Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
            col_along = uconvert(u"m", 1.0u"ft"))
        @test br_m.sqA == 1.0
        @test br_m.Bn_footing ≈ Bn_sqA1 rtol=1e-10
        @test br_m.Bn_footing ≉ 2 * Bn_sqA1

        # (2) mixed 1 ft + 0 inch (Unitful promotes through SI).
        br_mix = SS._bearing_check_footing(
            Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
            col_along = 1.0u"ft" + 0.0u"inch")
        @test br_mix.sqA == 1.0
        @test br_mix.Bn_footing ≈ Bn_sqA1 rtol=1e-10

        # (3) metre-promoted 24 in column with native 1 ft station.
        br_c1m = SS._bearing_check_footing(
            Pu, uconvert(u"m", 24.0u"inch"), c2, B, L, h, fc, fc, fy, ϕb,
            :rectangular; col_along = 1.0u"ft")
        @test br_c1m.sqA == 1.0
        @test br_c1m.Bn_footing ≈ Bn_sqA1 rtol=1e-10

        # (4) metre-promoted Lf = 2 ft, default col_along = Lf/2: along
        # faces fill Lf (24 in column in 24 in length) → not wider.
        br_Lf = SS._bearing_check_footing(
            Pu, c1, c2, B, uconvert(u"m", 2.0u"ft"), h, fc, fc, fy, ϕb,
            :rectangular)
        @test br_Lf.sqA == 1.0
        @test br_Lf.Bn_footing ≈ Bn_sqA1 rtol=1e-10

        br_overlap = SS._bearing_check_footing(
            Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
            col_along = 0.999u"ft")
        @test br_overlap.sqA == 1.0
        @test br_overlap.Bn_footing ≈ Bn_sqA1 rtol=1e-10

        # Leftover-inch after SI round-trip: do not bypass the snap on the
        # unit tag. ACI 318-11 §10.14.1 (corpus: aci-318-11, page 162).
        @testset "(1) leftover-inch col_along after SI round-trip is sqA=1" begin
            br = SS._bearing_check_footing(
                Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
                col_along = uconvert(u"inch", uconvert(u"m", 1.0u"ft")))
            @test br.sqA == 1.0
            @test br.sqA != 2.0
            @test br.Bn_footing ≈ Bn_sqA1 rtol=1e-10
            @test br.Bn_footing ≉ 2 * Bn_sqA1
        end

        @testset "(2) leftover-inch c1 after SI round-trip is sqA=1" begin
            br = SS._bearing_check_footing(
                Pu, uconvert(u"inch", uconvert(u"m", 24.0u"inch")), c2, B, L, h,
                fc, fc, fy, ϕb, :rectangular; col_along = 1.0u"ft")
            @test br.sqA == 1.0
            @test br.Bn_footing ≈ Bn_sqA1 rtol=1e-10
        end

        @testset "(3) leftover-inch Lf after SI round-trip, default col_along is sqA=1" begin
            br = SS._bearing_check_footing(
                Pu, c1, c2, B, uconvert(u"inch", uconvert(u"m", 2.0u"ft")), h,
                fc, fc, fy, ϕb, :rectangular)
            @test br.sqA == 1.0
            @test br.Bn_footing ≈ Bn_sqA1 rtol=1e-10
        end

        @testset "(4) circular leftover-inch station D=24 in is sqA=1" begin
            D = 24.0u"inch"
            A1_circ = π * (D / 2)^2
            br = SS._bearing_check_footing(
                Pu, D, D, B, L, h, fc, fc, fy, ϕb, :circular;
                col_along = uconvert(u"inch", uconvert(u"m", 1.0u"ft")))
            @test br.sqA == 1.0
            @test br.sqA != 1.0 + eps(1.0)
            @test br.Bn_footing ≈ ϕb * 0.85 * fc * A1_circ rtol=1e-10
        end

        # True 0.01 in leftover is still wider on all sides (clipped A2
        # then √ capped at 2 on B=40 in / L=22 ft). Not a construction-
        # tolerance flush. The cap of 2 does not lock that face's A2 clip
        # — see (8b).
        @testset "(8) true leftover 0.01 in still wider" begin
            br_leftover = SS._bearing_check_footing(
                Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
                col_along = 1.0u"ft" + 0.01u"inch")
            @test br_leftover.sqA != 1.0
            @test br_leftover.sqA == 2.0
        end

        # Tight leftover: 24.02 × 12.02 in footing, 24 × 12 in column,
        # default center. All four faces 0.01 in leftover — wider, but
        # A2 clips to the leftover (not 2h), so √(A2/A1) is the frustum
        # ratio, not the cap of 2. ACI 318-11 notation A2 (corpus:
        # aci-318-11, page 24); §10.14.1 (page 162).
        @testset "(8b) 24.02×12.02 leftover clips A2, not the √ cap of 2" begin
            Lf_tight = 24.02u"inch"
            B_tight  = 12.02u"inch"
            br = SS._bearing_check_footing(
                Pu, c1, c2, B_tight, Lf_tight, h, fc, fc, fy, ϕb,
                :rectangular)
            sqA_clip = sqrt(24.02 * 12.02 / 288.0)
            @test br.sqA ≈ sqA_clip rtol=1e-10
            @test br.sqA != 2.0
            @test br.sqA > 1.0
        end

        # P0: 6e-13 in is inside the residual < 1e-12 contract but
        # `round(x/1e-12)*1e-12` rounds UP to 12+1e-12 (`left` ≈
        # 1.00009e-12). Snap after face subtraction, not onto leftover.
        # ACI 318-11 §10.14.1 (corpus: aci-318-11, page 162).
        @testset "P0: col_along = 12+6e-13 in is sqA=1" begin
            br = SS._bearing_check_footing(
                Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
                col_along = (12.0 + 6e-13) * u"inch")
            @test br.sqA == 1.0
            @test br.sqA != 2.0
            @test br.Bn_footing ≈ Bn_sqA1 rtol=1e-10
            @test br.Bn_footing ≉ 2 * Bn_sqA1
        end

        # Inclusive floor: exclusive `< 1e-12` leaves (12+1e-12)inch
        # wider because Unitful inflates the leftover to ~1.00009e-12.
        # Still SI ulp, not leftover. ACI 318-11 §10.14.1 (corpus:
        # aci-318-11, page 162).
        @testset "P2: col_along = (12+1e-12)inch is sqA=1" begin
            br = SS._bearing_check_footing(
                Pu, c1, c2, B, L, h, fc, fc, fy, ϕb, :rectangular;
                col_along = (12.0 + 1e-12) * u"inch")
            @test br.sqA == 1.0
            @test br.sqA != 2.0
            @test br.Bn_footing ≈ Bn_sqA1 rtol=1e-10
            @test br.Bn_footing ≉ 2 * Bn_sqA1
        end

        # P1: Lf = 24+6e-13 in, default center. Lf/2 must be
        # re-canonicalized; a column that fills Lf is not wider.
        @testset "P1: Lf = 24+6e-13 in, default center, is sqA=1" begin
            br = SS._bearing_check_footing(
                Pu, c1, c2, B, (24.0 + 6e-13) * u"inch", h,
                fc, fc, fy, ϕb, :rectangular)
            @test br.sqA == 1.0
            @test br.Bn_footing ≈ Bn_sqA1 rtol=1e-10
            @test br.Bn_footing ≉ 2 * Bn_sqA1
        end
    end

    @testset "(5) design_footing leftover-inch c1/c2 + metre positions is sqA=1" begin
        # Production strip: leftover-inch column faces + metre stations.
        # Y-strip c1=12 in (across), c2=24 in (along), supports at 0 / 20 ft
        # park each column 1 ft from the end → along overhang = 0.
        c1 = uconvert(u"inch", uconvert(u"m", 12.0u"inch"))
        c2 = uconvert(u"inch", uconvert(u"m", 24.0u"inch"))
        Pu = 80.0kip
        soil = Soil(20.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StripParams(min_depth=12.0u"inch")
        positions = [uconvert(u"m", 0.0u"ft"), uconvert(u"m", 20.0u"ft")]
        d1 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        d2 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=c1, c2=c2)
        result = design_footing(StripFooting(), [d1, d2], positions, soil;
                               opts, strip_axis=:y)
        @test hasproperty(result, :sqA)
        @test result.sqA == 1.0
    end

    @testset "P1: clipped 1:2 A2 — 18×18 / D=20 at 1 ft, D=24 at 19.9 ft" begin
        # ACI 318-11 notation A2 (corpus: aci-318-11, page 24) + §10.14.1 /
        # R10.14.1 (pages 162–163): largest 1V:2H frustum wholly in the
        # support. Near-end spread is min(2h, overhang) per face — not the
        # centered box min(c+4h, L). √ only if every overhang > 0.
        Pu = 80.0kip
        soil = Soil(20.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        # qa = 2 ksf so designed B exceeds D=24 in and all four faces project
        # (otherwise a flush across-face masks the L-ceil along clip).
        soil_wide = Soil(2.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StripParams(min_depth=12.0u"inch")
        fc = opts.material.concrete.fc′
        fy = opts.material.rebar.Fy
        ϕb = opts.ϕ_bearing
        h_stub = 12.0u"inch"
        L_stub = 22.0u"ft"

        # Known-answer helper: 18×18, col_along=1 ft, h=12 in, B=24 in.
        # left = 12−9 = 3 in; right ≫ 2h; across = 3 in each.
        # A2 = (18+3+24)×(18+3+3) = 45×24 = 1080 in²; √(1080/324) ≈ 1.826.
        # Centered min(c+4h, L)×min(c+4h, B) = 66×24 → cap 2 (illegal).
        c18 = 18.0u"inch"
        B24 = 24.0u"inch"
        col_1ft = 1.0u"ft"
        A1_18 = c18 * c18
        A2_clip_18 = (c18 + 3.0u"inch" + 2 * h_stub) * B24
        A2_box_18 = min(c18 + 4 * h_stub, L_stub) * min(c18 + 4 * h_stub, B24)
        @test ustrip(u"inch^2", A2_clip_18) ≈ 1080 rtol=1e-12
        sqA_clip_18 = ustrip(Unitful.NoUnits, sqrt(A2_clip_18 / A1_18))
        sqA_box_18 = min(ustrip(Unitful.NoUnits, sqrt(A2_box_18 / A1_18)), 2.0)
        @test sqA_clip_18 ≈ sqrt(10 / 3) rtol=1e-12
        @test sqA_box_18 == 2.0
        br_18 = SS._bearing_check_footing(
            Pu, c18, c18, B24, L_stub, h_stub, fc, fc, fy, ϕb, :rectangular;
            col_along = col_1ft)
        @test br_18.sqA ≈ sqA_clip_18 rtol=1e-10
        @test br_18.sqA ≈ 1.83 atol=0.01
        @test br_18.sqA != 2.0
        @test br_18.Bn_footing ≈ ϕb * 0.85 * fc * A1_18 * br_18.sqA rtol=1e-10

        # Circular D=20, B=40 in, center 12 in from the end: cone of radius
        # 2h hangs off. Largest wholly-inside cone: r = min(10+24, 12)=12 in.
        # √(A2/A1) = 12/10 = 1.2. Centered min(D+4h, B)/2 = 20 in → cap 2.
        D20 = 20.0u"inch"
        B40 = 40.0u"inch"
        A1_20 = π * (D20 / 2)^2
        A2_cone_20 = π * (12.0u"inch")^2
        A2_box_20 = π * (min(D20 + 4 * h_stub, min(B40, L_stub)) / 2)^2
        br_d20 = SS._bearing_check_footing(
            Pu, D20, D20, B40, L_stub, h_stub, fc, fc, fy, ϕb, :circular;
            col_along = col_1ft)
        @test br_d20.sqA ≈ ustrip(Unitful.NoUnits, sqrt(A2_cone_20 / A1_20)) rtol=1e-10
        @test br_d20.sqA ≈ 1.2 rtol=1e-10
        @test min(ustrip(Unitful.NoUnits, sqrt(A2_box_20 / A1_20)), 2.0) == 2.0
        @test br_d20.sqA != 2.0

        # D=24, L-ceil of [0, 19.9] ft → col_along = 1.05 ft, overhang ≈ 0.6 in.
        # r = 12.6 in; √ = 12.6/12 = 1.05. Float floor is not a substitute.
        D24 = 24.0u"inch"
        col_199 = 1.05u"ft"
        A1_24 = π * (D24 / 2)^2
        r_199 = col_199
        br_d24 = SS._bearing_check_footing(
            Pu, D24, D24, B40, L_stub, h_stub, fc, fc, fy, ϕb, :circular;
            col_along = col_199)
        @test br_d24.sqA ≈ ustrip(u"inch", r_199) / 12.0 rtol=1e-10
        @test br_d24.sqA ≈ 1.05 atol=0.01
        @test br_d24.sqA != 2.0

        # Centered 18×18 with ≥2h on all four sides still caps at 2.
        B_cen = c18 + 4 * h_stub + 6.0u"inch"
        L_cen = c18 + 4 * h_stub + 6.0u"inch"
        br_cen = SS._bearing_check_footing(
            Pu, c18, c18, B_cen, L_cen, h_stub, fc, fc, fy, ϕb, :rectangular)
        @test br_cen.sqA == 2.0
        @test br_cen.Bn_footing ≈ 2 * ϕb * 0.85 * fc * A1_18 rtol=1e-10

        # Production 18×18 at [0, 20] ft (1 ft station). Light Pu keeps the
        # 2 ft B-floor and min_depth so the 3 in near-end clip is visible
        # on result.sqA (heavier Pu widens B until even the clipped frustum
        # hits the cap of 2). Assert result.Bn / result.sqA, not a stub.
        positions = [0.0u"ft", 20.0u"ft"]
        Pu18 = 20.0kip
        d18_1 = FoundationDemand(1; Pu=Pu18, Ps=Pu18, c1=c18, c2=c18)
        d18_2 = FoundationDemand(2; Pu=Pu18, Ps=Pu18, c1=c18, c2=c18)
        r18 = design_footing(StripFooting(), [d18_1, d18_2], positions, soil;
                             opts, strip_axis=:y)
        x_bar_18 = (positions[1] + positions[2]) / 2
        col_18 = positions[1] - (x_bar_18 - r18.L_ftg / 2)
        @test col_18 ≈ 1.0u"ft" rtol=1e-8
        left_18 = col_18 - c18 / 2
        right_18 = r18.L_ftg - col_18 - c18 / 2
        ac_18 = (r18.B - c18) / 2
        @test left_18 ≈ 3.0u"inch" rtol=1e-8
        @test ac_18 > zero(ac_18)
        @test left_18 < 2 * r18.D
        two_h_18 = 2 * r18.D
        A2_18p = (c18 + min(two_h_18, left_18) + min(two_h_18, right_18)) *
                 (c18 + min(two_h_18, ac_18) + min(two_h_18, ac_18))
        sqA_18p = min(ustrip(Unitful.NoUnits, sqrt(A2_18p / A1_18)), 2.0)
        @test r18.sqA ≈ sqA_18p rtol=1e-10
        @test r18.sqA ≈ 1.83 atol=0.01
        @test r18.sqA != 2.0
        @test r18.Bn ≈ uconvert(u"N", ϕb * 0.85 * fc * A1_18 * r18.sqA) rtol=1e-10

        # Production circular D=20 at [0, 20] ft (1 ft station).
        dc20_1 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=D20, c2=D20, shape=:circular)
        dc20_2 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=D20, c2=D20, shape=:circular)
        r20 = design_footing(StripFooting(), [dc20_1, dc20_2], positions, soil;
                             opts, strip_axis=:y)
        col_20 = positions[1] - (x_bar_18 - r20.L_ftg / 2)
        @test col_20 ≈ 1.0u"ft" rtol=1e-8
        r_edge_20 = min(col_20, r20.L_ftg - col_20, r20.B / 2)
        r_A2_20 = min(D20 / 2 + 2 * r20.D, r_edge_20)
        sqA_20p = min(ustrip(Unitful.NoUnits, r_A2_20 / (D20 / 2)), 2.0)
        @test r20.sqA ≈ sqA_20p rtol=1e-10
        @test r20.sqA < 2.0
        @test r20.Bn ≈ uconvert(u"N", ϕb * 0.85 * fc * A1_20 * r20.sqA) rtol=1e-10

        # Production D=24 at [0, 19.9] ft — L ceils; along overhang ≈ 0.6 in.
        pos_199 = [0.0u"ft", 19.9u"ft"]
        dc24_1 = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=D24, c2=D24, shape=:circular)
        dc24_2 = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=D24, c2=D24, shape=:circular)
        r24 = design_footing(StripFooting(), [dc24_1, dc24_2], pos_199, soil_wide;
                             opts, strip_axis=:y)
        x_bar_24 = (pos_199[1] + pos_199[2]) / 2
        col_24p = pos_199[1] - (x_bar_24 - r24.L_ftg / 2)
        @test col_24p ≈ 1.05u"ft" atol=0.02u"ft"
        @test r24.B > D24
        r_edge_24 = min(col_24p, r24.L_ftg - col_24p, r24.B / 2)
        r_A2_24 = min(D24 / 2 + 2 * r24.D, r_edge_24)
        sqA_24p = min(ustrip(Unitful.NoUnits, r_A2_24 / (D24 / 2)), 2.0)
        @test r24.sqA ≈ sqA_24p rtol=1e-10
        @test r24.sqA < 2.0
        @test r24.sqA != 2.0
        @test r24.Bn ≈ uconvert(u"N", ϕb * 0.85 * fc * A1_24 * r24.sqA) rtol=1e-10
    end

    @testset "P1: NLP rebar eval adds transfer As; Inf is infeasible" begin
        # Square-c NLP proxy made the punching swap a no-op; the miss was
        # transfer As absent from the objective. Inf → same as inadequate flexure.
        # ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250).
        mat = RC_4000_60
        fc  = mat.concrete.fc′
        fy  = mat.rebar.Fy
        Es  = mat.rebar.E
        γ_c = mat.concrete.ρ
        λ   = mat.concrete.λ
        wc_pcf = ustrip(pcf, γ_c)
        Ecs = Ec(fc, wc_pcf)
        p = FlatPlateNLPProblem(
            mat, fc, fy, Es, Ecs, γ_c, λ,
            18.0u"ft", 14.0u"ft", 20.0psf, 40.0psf,
            [:edge, :interior], [126.0, 126.0],
            2 * ustrip(u"m", 10.0u"ft"),
            0.26, 0.70, 0.52,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 12.0), (10.0, 24.0),
            [5],
            MinVolume(),
        )
        feasible, obj, result = evaluate(p, [8.0, 16.0])
        @test feasible
        @test obj < Inf
        mr = result.moment_results
        h, d, c, bar = result.h, result.d, result.c, result.bar_size
        ln2 = clear_span(mr.l2, c)
        M0_y = total_static_moment(mr.qu, mr.l1, ln2)
        unbal_y = [p.column_positions[i] != :interior ? 0.3 * M0_y : zero(M0_y)
                   for i in 1:length(p.column_positions)]
        T_M = eltype(mr.unbalanced_moments)
        unbal_y = T_M[uconvert(kip * u"ft", M) for M in unbal_y]
        rebar = SS._evaluate_rebar_for_size(p, mr, h, d, bar, c, unbal_y)
        As_xfer = sum(begin
            gov = SS.governing_transfer_reinforcement(
                mr.unbalanced_moments[i], unbal_y[i], c, c, h, d, fc, fy;
                position = p.column_positions[i], free_edge_parallel = :c2)
            gov.As
        end for i in 1:length(p.column_positions))
        mr0 = MomentAnalysisResult(
            mr.M0, mr.M_neg_ext, mr.M_neg_int, mr.M_pos,
            mr.qu, mr.qD, mr.qL, mr.l1, mr.l2, mr.ln, mr.c_avg,
            mr.column_moments, mr.column_shears,
            zero.(mr.unbalanced_moments), mr.Vu_max)
        unbal_y0 = zero.(unbal_y)
        rebar0 = SS._evaluate_rebar_for_size(p, mr0, h, d, bar, c, unbal_y0)
        @test rebar.total_As ≈ rebar0.total_As + As_xfer rtol=1e-8
        @test ustrip(u"inch^2", rebar.total_As) > ustrip(u"inch^2", rebar0.total_As)
        @test result.total_As ≈ rebar.total_As rtol=1e-8

        Mux_huge = 2000.0kip * u"ft"
        mr_inf = MomentAnalysisResult(
            mr.M0, mr.M_neg_ext, mr.M_neg_int, mr.M_pos,
            mr.qu, mr.qD, mr.qL, mr.l1, mr.l2, mr.ln, mr.c_avg,
            mr.column_moments, mr.column_shears,
            T_M[uconvert(kip * u"ft", Mux_huge), zero(Mux_huge)], mr.Vu_max)
        gov_inf = SS.governing_transfer_reinforcement(
            Mux_huge, zero(Mux_huge), c, c, h, d, fc, fy;
            position = :edge, free_edge_parallel = :c2)
        @test isinf(ustrip(u"inch^2", gov_inf.As))
        rebar_inf = SS._evaluate_rebar_for_size(p, mr_inf, h, d, bar, c, unbal_y0)
        @test isinf(ustrip(u"inch^2", rebar_inf.total_As))
    end

    @testset "14: bare Real Pu rejected at ACI spread entry" begin
        soil = Soil(5.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        # Keyword constructor cannot mix Real Pu with Quantity defaults.
        # Build a Real-valued demand to hit the ACI Quantity gate.
        demand = FoundationDemand{Float64, Float64, typeof(18.0u"inch")}(
            1, 912.0, 0.0, 0.0, 0.0, 0.0, 670.0,
            18.0u"inch", 18.0u"inch", :rectangular, false)
        @test !(demand.Pu isa Unitful.Quantity)
        @test_throws ArgumentError design_footing(SpreadFooting(), demand, soil)
        @test_throws MethodError SS._eccentric_soil_pressure(
            100.0, 0.0, 0.0, 10.0, 10.0)
    end
end
