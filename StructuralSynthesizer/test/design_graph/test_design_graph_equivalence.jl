# =============================================================================
# DesignGraph equivalence test — graph path vs legacy stage loop
# =============================================================================
#
# In-suite twin of `scripts/runners/verify_design_graph.jl`. Asserts that the
# `DesignGraph` execution path (what `design_building` now drives via
# `build_design_graph` + `execute_graph!`) produces the SAME engineering
# invariants as an INDEPENDENT reference built from the legacy `build_pipeline`
# stage loop, on several small buildings.
#
# The reference path calls the stage loop DIRECTLY (never `build_design_graph` /
# `execute_graph!`), so a divergence in the graph executor (wrong node order,
# dropped node, missing/extra `sync_asap!`) would trip these assertions.
#
# Cases:
#   1. flat-plate DDM — stage 2 = `_reconcile_columns!` (needs_sync=false).
#   2. beam/column (vault floor) — stage 2 = `_size_beams_columns!`
#      (needs_sync=true), exercising the second sync branch.
#   3. flat-plate DDM with `uniform_column_sizing=:per_story`, so
#      `harmonize_uniform_column_sizes!` runs and mutates columns.
#
# Run standalone:
#   julia --project=StructuralSynthesizer \
#       StructuralSynthesizer/test/design_graph/test_design_graph_equivalence.jl
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using Asap  # registers u"kgCO2e" (embodied-carbon unit)

const _SR = StructuralSizer
const _SS = StructuralSynthesizer

# Invariant set — mirrored from scripts/runners/run_flat_plate_speedup_validation.jl.
const _INVARIANT_COLS = (
    :h_m, :M0_kNm,
    :punch_ratio, :defl_ratio,
    :As_cs_in2, :As_ms_in2, :As_total_in2,
    :col_min_in, :col_max_in,
    :ec_total_kgco2e, :ec_per_area_kgco2e_m2,
    :fdn_max_B_ft, :fdn_max_L_ft, :fdn_max_D_in, :fdn_max_util,
)

# One small flat-plate building (2×2 bays, 1 story → DDM-applicable, 9 columns).
function _build_verify_building()
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_design_graph",
        floor              = FlatPlateOptions(method = DDM()),
        materials          = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        max_iterations     = 5,
        skip_visualization = true,
        foundation_options = FoundationParameters(
            soil    = _SR.medium_sand,
            options = _SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Beam/column building: a vault floor makes `_infer_floor_type` return :vault
# (∉ :flat_plate/:flat_slab), so stage 2 routes to `_size_beams_columns!` with
# needs_sync=true — the second sync branch the flat-plate case never hits.
# Mirrors the proven test_vault_pipeline.jl configuration so it runs end-to-end.
function _build_beam_column_building()
    skel  = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_design_graph_beam_column",
        floor              = _SR.VaultOptions(lambda = 8.0, material = _SR.NWC_4000),
        max_iterations     = 5,
        skip_visualization = true,
    )
    return struc, params
end

# Flat-plate building with per-story column harmonization, so
# `harmonize_uniform_column_sizes!` runs and mutates columns (a 2×2×1 building's
# 9 columns carry different demands → at least one is enlarged to the governing
# size). Confirms graph==legacy including the post-pipeline harmonize step.
function _build_per_story_building()
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name                  = "verify_design_graph_per_story",
        floor                 = FlatPlateOptions(method = DDM()),
        materials             = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        uniform_column_sizing = :per_story,
        max_iterations        = 5,
        skip_visualization    = true,
        foundation_options    = FoundationParameters(
            soil    = _SR.medium_sand,
            options = _SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Reference: the pre-graph `design_building` body, reconstructed by hand so it is
# independent of the graph executor (calls `build_pipeline` + stage loop directly).
function _run_reference_path(struc::BuildingStructure, params::DesignParameters)
    prepare!(struc, params)
    for stage in build_pipeline(params)
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params=params)
    end
    if params.uniform_column_sizing !== :off
        n = _SS.harmonize_uniform_column_sizes!(struc, params)
        n > 0 && sync_asap!(struc; params=params)
    end
    design = capture_design(struc, params)
    restore!(struc; geometry_is_centerline=params.geometry_is_centerline)
    return design
end

# Extract the invariant NamedTuple from a captured BuildingDesign.  Must be
# called before any subsequent run mutates `struc` (sizer_result aliasing).
function _extract_invariants(design::BuildingDesign)
    slabs = collect(values(design.slabs))
    @assert !isempty(slabs) "design has no slabs"

    h_m    = maximum(ustrip(u"m", s.thickness) for s in slabs)
    M0_kNm = maximum(isnothing(s.M0) ? NaN : ustrip(u"kN*m", s.M0) for s in slabs)
    punch  = maximum(s.punching_max_ratio for s in slabs)
    defl   = maximum(s.deflection_ratio  for s in slabs)

    As_cs = 0.0u"inch^2"
    As_ms = 0.0u"inch^2"
    for s in slabs
        r = s.sizer_result
        isnothing(r) && continue
        hasproperty(r, :column_strip_reinf) &&
            (As_cs += sum(sr.As_provided for sr in r.column_strip_reinf; init = 0.0u"inch^2"))
        hasproperty(r, :middle_strip_reinf) &&
            (As_ms += sum(sr.As_provided for sr in r.middle_strip_reinf; init = 0.0u"inch^2"))
    end

    cols_in = [ustrip(u"inch", c.c1) for c in values(design.columns) if c.c1 > 0.0u"m"]
    col_min = isempty(cols_in) ? NaN : minimum(cols_in)
    col_max = isempty(cols_in) ? NaN : maximum(cols_in)

    ec_total = ustrip(u"kgCO2e", design.summary.embodied_carbon)
    struc    = design.structure
    area_m2  = 0.0
    for idx in keys(design.slabs)
        (idx < 1 || idx > length(struc.slabs)) && continue
        for ci in struc.slabs[idx].cell_indices
            (ci < 1 || ci > length(struc.cells)) && continue
            area_m2 += ustrip(u"m^2", struc.cells[ci].area)
        end
    end
    ec_per_area = area_m2 > 0.0 ? ec_total / area_m2 : NaN

    B_ft = L_ft = D_in = util = NaN
    for f in values(design.foundations)
        b = ustrip(u"ft",   f.width)
        l = ustrip(u"ft",   f.length)
        d = ustrip(u"inch", f.depth)
        u = max(f.bearing_ratio, f.punching_ratio, f.flexure_ratio)
        B_ft = isnan(B_ft) ? b : max(B_ft, b)
        L_ft = isnan(L_ft) ? l : max(L_ft, l)
        D_in = isnan(D_in) ? d : max(D_in, d)
        util = isnan(util) ? u : max(util, u)
    end

    return (
        h_m = h_m, M0_kNm = M0_kNm,
        punch_ratio = punch, defl_ratio = defl,
        As_cs_in2 = ustrip(u"inch^2", As_cs),
        As_ms_in2 = ustrip(u"inch^2", As_ms),
        As_total_in2 = ustrip(u"inch^2", As_cs + As_ms),
        col_min_in = col_min, col_max_in = col_max,
        ec_total_kgco2e = ec_total, ec_per_area_kgco2e_m2 = ec_per_area,
        fdn_max_B_ft = B_ft, fdn_max_L_ft = L_ft,
        fdn_max_D_in = D_in, fdn_max_util = util,
    )
end

# NaN-aware closeness (two NaNs equal); matches the runner's `_close`.
function _close(a, b; rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    if a isa AbstractFloat && b isa AbstractFloat
        (isnan(a) && isnan(b)) && return true
        return isapprox(a, b; rtol = rtol, atol = atol)
    end
    return isequal(a, b)
end

println("Testing DesignGraph vs legacy stage-loop equivalence...")

# (case_name, builder, has_foundations) — `has_foundations` gates the foundation
# sanity check (the vault case runs without foundations, so its foundation
# invariants are NaN==NaN on both sides).
_EQUIVALENCE_CASES = (
    ("flat-plate DDM (reconcile columns, foundations on)",
     _build_verify_building, true),
    ("beam/column (vault floor, _size_beams_columns! + needs_sync)",
     _build_beam_column_building, false),
    ("flat-plate DDM + uniform_column_sizing=:per_story (harmonize runs)",
     _build_per_story_building, true),
)

@testset "DesignGraph equivalence (graph vs legacy reference)" begin
    for (case_name, build_fn, has_foundations) in _EQUIVALENCE_CASES
        @testset "$case_name" begin
            struc, params = build_fn()

            # Graph path (current design_building). Extract before the reference
            # run mutates `struc`.
            graph_design = design_building(struc, params)
            graph_inv    = _extract_invariants(graph_design)

            # The building must actually design something for the diff to be
            # meaningful.
            @test !isempty(graph_design.slabs)
            @test !isempty(graph_design.columns)
            has_foundations && @test !isempty(graph_design.foundations)
            @test graph_inv.h_m > 0.0
            @test isfinite(graph_inv.ec_total_kgco2e) && graph_inv.ec_total_kgco2e > 0.0

            # Independent reference path (legacy build_pipeline stage loop, direct).
            ref_design = _run_reference_path(struc, params)
            ref_inv    = _extract_invariants(ref_design)

            # Strict per-invariant equality (rtol=1e-8): the graph executor must
            # reproduce the legacy stage loop bit-for-bit (within float roundoff).
            for col in _INVARIANT_COLS
                vg = getproperty(graph_inv, col)
                vr = getproperty(ref_inv, col)
                @test _close(vg, vr)  # graph vs reference for $col
            end
        end
    end
end

println("\n✓ DesignGraph equivalence test passed!")
