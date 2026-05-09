# =============================================================================
# Test: Per-slab EC extraction from the flat-plate method comparison sweep
# =============================================================================
#
# Smoke test for the slab_ec_kgco2e / slab_area_m2 / slab_ec_per_m2 fields
# added to _extract_results in flat_plate_method_comparison.jl.
#
# Verifies that:
#   1. The new fields exist on every result row (success and failure)
#   2. EC values are positive and finite for converged designs
#   3. EC density (kgCO₂e/m²) is in a physically plausible band for an
#      ~7–10 in NWC_4000 flat plate at LL = 50 psf
#   4. Foundation step is exercised (proxy: row.fdn_n_sized > 0)
#
# Single-method (FEA) run to keep runtime ~10–20 s.
#
# Run from project root:
#   julia --project=StructuralStudies StructuralStudies/test/test_ec_extraction.jl
# =============================================================================

using Test

# Load the comparison module — gives access to all internal helpers
# (_make_params, _build_skeleton, _run_method, _adaptive_*, etc.).
include(joinpath(@__DIR__, "..", "src", "flat_plate_methods",
                 "flat_plate_method_comparison.jl"))

@testset "Slab EC extraction (single-method smoke)" begin

    span_ft = 20.0
    ll_psf  = 50.0
    n_bays  = 3
    ht      = _adaptive_story_ht(span_ft)
    max_col = _adaptive_max_col(span_ft)

    base_params = _make_params(; floor_type = :flat_plate,
                                  sdl_psf = 20.0, max_col_in = max_col)
    skel  = _build_skeleton(span_ft, span_ft, ht, n_bays)
    struc = BuildingStructure(skel)
    prepare!(struc, base_params)

    # FEA is always applicable, so we get a converged row deterministically.
    mcfg = (key = :fea, name = "FEA",
            method = SR.FEA(; pattern_loading = false, design_approach = :frame))
    row = _run_method(struc, base_params, mcfg;
                      lx_ft = span_ft, ly_ft = span_ft, live_psf = ll_psf,
                      floor_type = :flat_plate)

    @testset "schema includes new EC fields" begin
        @test :slab_ec_kgco2e in propertynames(row)
        @test :slab_area_m2   in propertynames(row)
        @test :slab_ec_per_m2 in propertynames(row)
    end

    @testset "converged FEA row has positive, finite EC" begin
        @test row.converged
        @test isfinite(row.slab_ec_kgco2e) && row.slab_ec_kgco2e > 0
        @test isfinite(row.slab_area_m2)   && row.slab_area_m2   > 0
        @test isfinite(row.slab_ec_per_m2) && row.slab_ec_per_m2 > 0
    end

    @testset "EC density within sane bounds for NWC_4000 + Gr60" begin
        # A 20 ft square bay flat plate at 50 psf typically lands ~7–9 in.
        # Concrete EC ≈ 0.203 m × 2380 kg/m³ × 0.138 kg/kg ≈ 67 kg/m².
        # Add rebar (rebar volume ratio ~0.005–0.02, ECC ≈ 1.0–1.5 kg/kg
        # for Gr60 → ~10–40 kg/m² rebar contribution).
        # Total expected: ~50–200 kgCO₂e/m². Use a wider 40–400 to allow
        # for FEA optimizing depth differently than DDM.
        @test 40.0 ≤ row.slab_ec_per_m2 ≤ 400.0
    end

    @testset "slab area matches 3×3 × 20 ft plan (~ 334 m²)" begin
        # 3-bay × 3-bay × 20 ft / bay = 60 ft = 18.288 m per side
        # Floor area ≈ (18.288 m)² = 334.45 m².
        @test 300.0 ≤ row.slab_area_m2 ≤ 360.0
    end

    @testset "EC consistent with element_ec(slab.volumes) called directly" begin
        # Cross-check that what's recorded in row matches the live struc state.
        slab = struc.slabs[1]
        ec_direct = element_ec(slab.volumes)
        @test isapprox(row.slab_ec_kgco2e, ec_direct; rtol = 1e-6)
    end

    @testset "foundation pipeline ran (sanity check on multi-stage pipeline)" begin
        # Verifies the full pipeline reached stage 3 (size_foundations!),
        # which depends on the slab EC step running cleanly without
        # disrupting later stages.
        @test row.fdn_n_sized ≥ 1
    end
end

println("\n✓ Slab EC extraction smoke test passed.")
