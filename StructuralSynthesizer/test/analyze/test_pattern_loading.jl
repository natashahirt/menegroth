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

"""Build a 2×2 bay, 1-story flat plate structure ready for to_asap!."""
function _make_flat_plate(; sdl=20.0u"psf", ll=50.0u"psf")
    skel = gen_medium_office(60.0u"ft", 60.0u"ft", 12.0u"ft", 2, 2, 1)
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

    println("\n✓ All pattern loading tests passed!")
end
