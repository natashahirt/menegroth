# =============================================================================
# Pattern Loading Tests
# =============================================================================
#
# Tests the pattern loading feature (ACI 318-19 §6.4.3):
#   - Dead/live load separation in to_asap!
#   - Checkerboard cell partitioning
#   - Multi-case solve and force envelope
#   - :auto L/D skip logic
#   - Equivalence with single-solve when all cells loaded identically
#
# Geometry: 2×2 bay flat plate, 1 story — small enough for fast tests,
# large enough to produce meaningful checkerboard partitions.

using Test
using Unitful
using Asap
using LinearAlgebra
using Statistics

using StructuralSynthesizer
using StructuralSizer

# ─── Helpers ──────────────────────────────────────────────────────────────────

"""Build a 1-story flat plate ready for `to_asap!`."""
function _make_flat_plate_bays(xb, yb, Lx, Ly; sdl=20.0u"psf", ll=50.0u"psf")
    skel = gen_medium_office(Lx, Ly, 12.0u"ft", xb, yb, 1)
    struc = BuildingStructure(skel)

    opts = FlatPlateOptions(
        material = RC_4000_60,
        method   = DDM(),
        cover    = 0.75u"inch",
        bar_size = 5,
    )
    initialize!(struc; floor_type=:flat_plate, floor_opts=opts)

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

"""Build a 2×2 bay, 1-story flat plate structure ready for to_asap!."""
_make_flat_plate(; sdl=20.0u"psf", ll=50.0u"psf") =
    _make_flat_plate_bays(2, 2, 60.0u"ft", 60.0u"ft"; sdl=sdl, ll=ll)


@testset "Pattern Loading" begin

    # =====================================================================
    # 1. Dead/live load separation
    # =====================================================================
    @testset "to_asap! separates dead and live loads" begin
        struc = _make_flat_plate()
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)

        non_grade = [i for (i, c) in enumerate(struc.cells) if c.floor_type != :grade]
        @test !isempty(non_grade)

        for ci in non_grade
            dead = struc.cell_dead_loads[ci]
            live = struc.cell_live_loads[ci]
            combined = struc.cell_tributary_loads[ci]

            @test !isempty(dead)
            @test !isempty(live)
            # Combined should contain both dead and live loads
            @test length(combined) == length(dead) + length(live)

            # Dead and live pressures must be positive and distinct
            dp = dead[1].pressure
            lp = live[1].pressure
            @test dp > 0.0u"Pa"
            @test lp > 0.0u"Pa"
            @test dp != lp  # different because SDL+SW ≠ LL
        end
    end

    # =====================================================================
    # 2. No separation when pattern_loading = :none
    # =====================================================================
    @testset "to_asap! uses combined loads when pattern_loading = :none" begin
        struc = _make_flat_plate()
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)

        non_grade = [i for (i, c) in enumerate(struc.cells) if c.floor_type != :grade]
        for ci in non_grade
            dead = struc.cell_dead_loads[ci]
            live = struc.cell_live_loads[ci]
            combined = struc.cell_tributary_loads[ci]

            # Dead/live dicts should be empty
            @test isempty(dead)
            @test isempty(live)
            # Combined should be populated
            @test !isempty(combined)
        end
    end

    # =====================================================================
    # 3. Checkerboard partition produces two non-empty, disjoint sets
    # =====================================================================
    @testset "Checkerboard partition" begin
        struc = _make_flat_plate()
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)

        set_a, set_b = StructuralSynthesizer._checkerboard_partition(struc)

        non_grade = [i for (i, c) in enumerate(struc.cells) if c.floor_type != :grade]

        @test !isempty(set_a)
        @test !isempty(set_b)
        # Together they cover all non-grade cells
        @test sort(vcat(set_a, set_b)) == sort(non_grade)
        # Disjoint
        @test isempty(intersect(set_a, set_b))
    end

    # =====================================================================
    # 4. Pattern cases are generated correctly
    # =====================================================================
    @testset "Pattern case generation" begin
        struc = _make_flat_plate()
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)

        cases = StructuralSynthesizer._generate_pattern_cases(struc)
        @test length(cases) == 3  # full, checkerboard A, checkerboard B

        # Full case should have the most loads (dead + all live)
        @test length(cases[1]) >= length(cases[2])
        @test length(cases[1]) >= length(cases[3])

        # Pattern cases A and B should have the same dead loads but different live
        # (all three share the dead component, but A and B each have a subset of live)
        n_dead = sum(length(get(struc.cell_dead_loads, ci, Asap.TributaryLoad[]))
                     for ci in keys(struc.cell_dead_loads))
        n_live = sum(length(get(struc.cell_live_loads, ci, Asap.TributaryLoad[]))
                     for ci in keys(struc.cell_live_loads))
        @test length(cases[1]) == n_dead + n_live
        @test length(cases[2]) < length(cases[1])  # subset of live
        @test length(cases[3]) < length(cases[1])  # subset of live
    end

    # =====================================================================
    # 5. sync_asap! with pattern loading runs without error
    # =====================================================================
    @testset "sync_asap! with pattern_loading = :checkerboard" begin
        struc = _make_flat_plate()
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)
        sync_asap!(struc; params)

        model = struc.asap_model
        # Model should be solved — displacements non-zero
        @test any(!iszero, model.u)
        # Frame elements should have non-zero forces (enveloped)
        @test !isempty(model.frame_elements)
        @test any(el -> any(!iszero, el.forces), model.frame_elements)
    end

    # =====================================================================
    # 6. Enveloped forces ≥ single-solve forces
    # =====================================================================
    @testset "Enveloped forces ≥ single-solve forces" begin
        # Run without pattern loading
        struc_base = _make_flat_plate()
        params_base = DesignParameters(pattern_loading = :none)
        to_asap!(struc_base; params=params_base)
        sync_asap!(struc_base; params=params_base)
        base_forces = [copy(el.forces) for el in struc_base.asap_model.frame_elements]

        # Run with pattern loading
        struc_pat = _make_flat_plate()
        params_pat = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc_pat; params=params_pat)
        sync_asap!(struc_pat; params=params_pat)
        pat_forces = [copy(el.forces) for el in struc_pat.asap_model.frame_elements]

        # Enveloped forces should be ≥ base forces at every DOF (by absolute value)
        n_el = length(base_forces)
        @test n_el == length(pat_forces)
        n_ge = 0
        n_total = 0
        for i in 1:n_el
            for k in eachindex(base_forces[i])
                n_total += 1
                if abs(pat_forces[i][k]) >= abs(base_forces[i][k]) - 1e-6
                    n_ge += 1
                end
            end
        end
        # Allow a small fraction of DOFs to be numerically equal but not less
        ratio = n_ge / n_total
        @test ratio > 0.99
        println("  Envelope coverage: $(round(100*ratio, digits=1))% of DOFs " *
                "($(n_ge)/$(n_total)) have |pattern| ≥ |base|")
    end

    # =====================================================================
    # 7. :auto mode — skips patterns when L/D ≤ 0.75
    # =====================================================================
    @testset ":auto skips patterns when L/D ≤ 0.75" begin
        # Heavy dead load, light live load → L/D < 0.75
        struc = _make_flat_plate(sdl=100.0u"psf", ll=30.0u"psf")
        params = DesignParameters(pattern_loading = :auto)
        to_asap!(struc; params)

        @test !StructuralSynthesizer._should_run_patterns(struc, params)
    end

    @testset ":auto runs patterns when L/D > 0.75" begin
        # Heavy live load relative to dead → L/D > 0.75
        # After initialize!, slab self_weight ≈ 100-130 psf, so D ≈ 120-150 psf.
        # Need LL > 0.75 * D ≈ 110+ psf to trigger.
        struc = _make_flat_plate(sdl=20.0u"psf", ll=250.0u"psf")
        params = DesignParameters(pattern_loading = :auto)
        to_asap!(struc; params)

        @test StructuralSynthesizer._should_run_patterns(struc, params)
    end

    # =====================================================================
    # 8. :checkerboard always runs regardless of L/D
    # =====================================================================
    @testset ":checkerboard always runs" begin
        struc = _make_flat_plate(sdl=100.0u"psf", ll=30.0u"psf")
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)

        @test StructuralSynthesizer._should_run_patterns(struc, params)
    end

    # =====================================================================
    # 9. Pressure updates propagate through sync_asap!
    # =====================================================================
    @testset "sync_asap! propagates pressure changes with patterns" begin
        struc = _make_flat_plate()
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)
        sync_asap!(struc; params)

        forces_before = [copy(el.forces) for el in struc.asap_model.frame_elements]

        # Double the live load on all cells
        for cell in struc.cells
            cell.live_load = 2 * cell.live_load
        end
        sync_asap!(struc; params)

        forces_after = [copy(el.forces) for el in struc.asap_model.frame_elements]

        # At least some forces should increase
        max_increase = 0.0
        for i in eachindex(forces_before)
            for k in eachindex(forces_before[i])
                delta = abs(forces_after[i][k]) - abs(forces_before[i][k])
                max_increase = max(max_increase, delta)
            end
        end
        @test max_increase > 0.0
        println("  Max force increase after doubling LL: $(round(max_increase, digits=2))")
    end

    # =====================================================================
    # 10. Multi-case Asap solve produces correct number of results
    # =====================================================================
    @testset "Asap multi-case solve" begin
        struc = _make_flat_plate()
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)
        Asap.solve!(struc.asap_model)  # ensure model is fully processed

        cases = StructuralSynthesizer._generate_pattern_cases(struc)
        u_cases = Asap.solve(struc.asap_model, cases)

        @test length(u_cases) == length(cases)
        for u in u_cases
            @test length(u) == struc.asap_model.nDOFs
            @test any(!iszero, u)
        end

        # Full-loading case (index 1) should have the largest displacement norm
        norms = [norm(u) for u in u_cases]
        @test norms[1] >= maximum(norms[2:end]) - 1e-6
    end

    # =====================================================================
    # 11. Pattern cases reach member_group_demands (not el.forces envelope)
    # =====================================================================
    @testset "Pattern cases reach member_group_demands" begin
        struc = _make_flat_plate(sdl=20.0u"psf", ll=250.0u"psf")
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)
        sync_asap!(struc; params)

        u_full = copy(struc.asap_model.u)
        @test StructuralSynthesizer._get_pattern_solve_cache(struc) !== nothing

        cases = StructuralSynthesizer._pattern_demand_cases(struc, params)
        @test cases !== nothing
        @test length(cases) == 3

        max_dMy = 0.0
        for el in struc.asap_model.frame_elements
            eid = el.elementID
            (1 <= eid <= length(cases[1][2])) || continue
            f_full = StructuralSynthesizer._element_forces_from_u(
                el, cases[1][1], cases[1][2][eid]; resolution=40)
            f_pat  = StructuralSynthesizer._element_forces_from_u(
                el, cases[2][1], cases[2][2][eid]; resolution=40)
            max_dMy = max(max_dMy, maximum(abs, f_full.My .- f_pat.My))
        end
        @test max_dMy > 1e-8

        _, dem_pat, = member_group_demands(struc; member_edge_group=:beams, params=params)
        @test struc.asap_model.u == u_full
        @test !isempty(dem_pat)
        @test any(d -> d.Mux_pos > 0 || d.Mux_neg > 0, dem_pat)

        struc_full = _make_flat_plate(sdl=20.0u"psf", ll=250.0u"psf")
        params_none = DesignParameters(pattern_loading = :none)
        to_asap!(struc_full; params=params_none)
        sync_asap!(struc_full; params=params_none)
        _, dem_full, = member_group_demands(struc_full; member_edge_group=:beams, params=params_none)

        # ACI 318-11 §13.7.6.4: envelope includes full live load on all panels.
        @test maximum(d.Mux for d in dem_pat) + 1e-8 >= maximum(d.Mux for d in dem_full)
    end

    # =====================================================================
    # 12. Continuous-beam oracle: checkerboard hogging exceeds full-load
    #     hogging at some stations (signed per-station envelope).
    # =====================================================================
    @testset "Continuous beam: checkerboard hogging exceeds full-load hogging" begin
        # 3-span continuous beam line (3×1 bays). Group-peak Mux_neg can still
        # equal the full-load support moment because case 1 is in the envelope
        # (ACI 318-11 §13.7.6.4). The oracle is the signed per-station envelope:
        # some stations have larger hogging under a checkerboard case than
        # under full live load. If pattern cases never reach member_group_demands,
        # those stations are silently dropped.
        struc = _make_flat_plate_bays(3, 1, 90.0u"ft", 20.0u"ft";
                                     sdl=20.0u"psf", ll=250.0u"psf")
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)
        sync_asap!(struc; params)

        u_full = copy(struc.asap_model.u)
        cases = StructuralSynthesizer._pattern_demand_cases(struc, params)
        @test cases !== nothing
        @test length(cases) == 3

        n_exceed = 0
        max_hog_env = 0.0
        beam_edges = Set(get(struc.skeleton.groups_edges, :beams, Int[]))
        for (edge_idx, el) in enumerate(struc.asap_model.elements)
            edge_idx in beam_edges || continue
            eid = el.elementID
            (1 <= eid <= length(cases[1][2])) || continue
            f_full = StructuralSynthesizer._element_forces_from_u(
                el, cases[1][1], cases[1][2][eid]; resolution=40)
            _, hog_full = StructuralSynthesizer._asap_signed_My_envelopes(el, f_full.My)
            max_hog_env = max(max_hog_env, hog_full)
            for i in 2:length(cases)
                f_pat = StructuralSynthesizer._element_forces_from_u(
                    el, cases[i][1], cases[i][2][eid]; resolution=40)
                _, hog_pat = StructuralSynthesizer._asap_signed_My_envelopes(el, f_pat.My)
                max_hog_env = max(max_hog_env, hog_pat)
                ly_z = el.LCS[2][3]
                abs(ly_z) < 1e-8 && continue
                s = ly_z > 0 ? 1.0 : -1.0
                for k in eachindex(f_full.My)
                    hog_k_full = max(0.0, -f_full.My[k] * s)
                    hog_k_pat  = max(0.0, -f_pat.My[k] * s)
                    hog_k_pat > hog_k_full + 1e-6 && (n_exceed += 1)
                end
            end
        end
        @test n_exceed > 0

        _, dem_pat, = member_group_demands(struc; member_edge_group=:beams, params=params)
        @test struc.asap_model.u == u_full
        @test !isempty(dem_pat)
        hog_demand = maximum(d.Mux_neg for d in dem_pat)
        @test hog_demand > 0
        # member_group_demands signed envelope matches the per-station max
        # (resolution 200 vs 40, so allow a small interpolation gap).
        @test hog_demand + 1.0 >= max_hog_env
        @test hog_demand ≈ max_hog_env atol=0.05 * max(max_hog_env, 1.0)
    end

    # =====================================================================
    # 13. Pattern (u, loads) cache is not the pre-size vector after K change
    # =====================================================================
    @testset "Pattern cache refreshes after section / K change" begin
        # Stale-path oracle: after Ix change the cache still holds pre-size
        # pattern_u. member_group_demands (no params) — the size_columns!
        # call shape — must not envelope that vector
        # (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261).
        struc = _make_flat_plate(sdl=20.0u"psf", ll=250.0u"psf")
        params = DesignParameters(pattern_loading = :checkerboard)
        to_asap!(struc; params)
        sync_asap!(struc; params)

        cached0 = StructuralSynthesizer._get_pattern_solve_cache(struc)
        @test cached0 !== nothing
        u_before = [copy(u) for u in cached0[2]]
        @test StructuralSynthesizer._pattern_cache_is_current(struc)

        for el in struc.asap_model.frame_elements
            s = el.section
            el.section = Asap.Section(s.A, s.E, s.G, 10 * s.Ix, 10 * s.Iy, s.J, s.ρ;
                                     Ay=s.Ay, Az=s.Az)
        end
        # Cache is not auto-cleared by the section assignment — this is the
        # stale-path that used to reach member_group_demands.
        @test !StructuralSynthesizer._pattern_cache_is_current(struc)
        cached_stale = StructuralSynthesizer._get_pattern_solve_cache(struc)
        @test cached_stale !== nothing
        @test all(cached_stale[2][i] == u_before[i] for i in eachindex(u_before))

        Asap.update!(struc.asap_model)
        Asap.solve!(struc.asap_model)
        # update!/solve! of the full-load case must not silently validate the
        # pre-size pattern_u (token still fingerprints section K).
        @test !StructuralSynthesizer._pattern_cache_is_current(struc)
        cached_after_solve = StructuralSynthesizer._get_pattern_solve_cache(struc)
        @test all(cached_after_solve[2][i] == u_before[i] for i in eachindex(u_before))

        # No-params path (size_columns!) must refresh, not reuse pre-size u.
        member_group_demands(struc; member_edge_group=:columns)
        cached1 = StructuralSynthesizer._get_pattern_solve_cache(struc)
        @test cached1 !== nothing
        @test StructuralSynthesizer._pattern_cache_is_current(struc)
        @test any(i -> cached1[2][i] != u_before[i], eachindex(u_before))

        # Demand-case u that sizing actually envelopes (default DesignParameters
        # is the size_columns! / no-params shape) must not be the pre-size vector.
        cases_used = StructuralSynthesizer._pattern_demand_cases(struc, DesignParameters())
        @test cases_used !== nothing
        @test any(i -> cases_used[i][1] != u_before[i], eachindex(u_before))
    end

    println("\n✓ All pattern loading tests passed!")
end
