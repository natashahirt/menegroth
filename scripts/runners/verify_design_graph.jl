# =============================================================================
# Differential Verify Harness — DesignGraph vs Legacy Stage Loop
# =============================================================================
#
# PERMANENT exact-first gate for the Incremental Design DAG effort. It proves
# that the new `DesignGraph` execution path (the one `design_building` now
# drives via `build_design_graph` + `execute_graph!`) produces outputs that are
# bit-identical (within float tolerance) to an INDEPENDENT reference produced by
# the legacy `build_pipeline` stage loop.
#
# Two paths are run on EACH of several small buildings:
#
#   GRAPH PATH  — `design_building(struc, params)`, which internally builds a
#                 `DesignGraph` from `build_pipeline` stages and runs it with
#                 `execute_graph!` (topological order + `sync_asap!` placement).
#
#   REFERENCE   — the pre-graph `design_building` body, reconstructed here by
#     PATH        hand: `prepare!`, then iterate `build_pipeline(params)` stages
#                 (`stage.fn(struc)` + `stage.needs_sync && sync_asap!`), then
#                 `harmonize_uniform_column_sizes!` (if enabled), then
#                 `capture_design`, then `restore!`. This calls the stage loop
#                 DIRECTLY — never `build_design_graph` / `execute_graph!` — so a
#                 divergence in the graph executor (wrong order, dropped node,
#                 missing/extra sync) would show up as an invariant mismatch.
#
# Cases (each diffs graph-vs-legacy on the full invariant set at rtol=1e-8):
#
#   1. flat-plate DDM — stage 2 is `_reconcile_columns!` (needs_sync=false);
#      foundations on.
#   2. beam/column (vault floor) — `_infer_floor_type` returns :vault, so
#      stage 2 routes to `_size_beams_columns!` with needs_sync=true, exercising
#      the SECOND sync branch the flat-plate case never hits.
#   3. flat-plate DDM with `uniform_column_sizing=:per_story`, so
#      `harmonize_uniform_column_sizes!` actually runs and mutates columns.
#
# The two designs are diffed on an invariant set mirrored from
# `scripts/runners/run_flat_plate_speedup_validation.jl` (slab h, M0, punching
# ratio, deflection ratio, As totals, column min/max dims, embodied carbon total
# + per area, foundation dims/util) at rtol=1e-8, atol=1e-10, with NaN==NaN.
#
# Usage:
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/verify_design_graph.jl
#
# Exit code: 0 when identical, 1 on any mismatch.
# =============================================================================

# Headless ENV guards first (match run_flat_plate_speedup_validation.jl:49-51),
# then activate `StructuralSynthesizer` (Asap is a direct path dep here).
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
    get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
Pkg.instantiate()

# `Asap` is `using`-ed directly so `@u_str` can resolve `u"kgCO2e"` (the carbon
# unit is registered by `Asap`) at macro-expansion time in this module — same
# reasoning as run_flat_plate_speedup_validation.jl:57-62.
using Asap
using StructuralSizer
using StructuralSynthesizer
using Unitful
using Printf

const SR = StructuralSizer
const SS = StructuralSynthesizer

# -----------------------------------------------------------------------------
# Shared verify helpers — single canonical copy. Provides INVARIANT_COLS (used
# below) plus design_signature / same_signature (unused in this runner). Included
# AFTER the `using` preamble so BuildingDesign + the u"kgCO2e" unit (registered by
# Asap) resolve at include time. See the file header for the `_close` contract.
#
# INVARIANT_COLS is mirrored from run_flat_plate_speedup_validation.jl:118-127 and
# MUST match between the graph path and the legacy reference path: stored in
# coherent units (SI where natural, imperial where the speedup harness used it) so
# the tolerance test is unit-consistent on both sides.
# -----------------------------------------------------------------------------
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer",
                 "test", "design_graph", "_verify_shared.jl"))

# -----------------------------------------------------------------------------
# Building + parameters — one small flat-plate building.
# -----------------------------------------------------------------------------
# 2×2 bays, single story: 54'×42' footprint → 27'×21' bays (aspect 1.29 < 2, so
# DDM applicable), 9 columns.  Kept small to stay fast after load.  Foundations
# enabled so the foundation invariants are exercised.
function build_verify_building()
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_design_graph",
        floor              = FlatPlateOptions(method = DDM()),
        materials          = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        max_iterations     = 5,
        skip_visualization = true,   # headless: no shell mesh / analysis model build
        foundation_options = FoundationParameters(
            soil    = SR.medium_sand,
            options = SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Case 2 — a beam/column building. A vault floor makes `_infer_floor_type`
# return :vault (∉ :flat_plate/:flat_slab), so `build_pipeline` routes stage 2
# to `_size_beams_columns!` with needs_sync=true — the SECOND sync branch the
# flat-plate case never exercises. Mirrors the proven test_vault_pipeline.jl
# configuration (30'×24'×12', 2×2 bays, 1 story), so it runs end-to-end.
function build_beam_column_building()
    skel  = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_design_graph_beam_column",
        floor              = SR.VaultOptions(lambda = 8.0, material = SR.NWC_4000),
        max_iterations     = 5,
        skip_visualization = true,
    )
    return struc, params
end

# Case 3 — a flat-plate building with `uniform_column_sizing=:per_story`, so
# `harmonize_uniform_column_sizes!` runs and mutates columns (the 9 columns of a
# 2×2×1 building carry different demands, so at least one is enlarged to the
# governing size). Verifies graph==legacy including the post-pipeline harmonize.
function build_per_story_building()
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
            soil    = SR.medium_sand,
            options = SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# -----------------------------------------------------------------------------
# Reference path — the pre-graph `design_building` body, by hand.
# -----------------------------------------------------------------------------
# Deliberately calls `build_pipeline` + the stage loop DIRECTLY (no
# `build_design_graph` / `execute_graph!`), so it is an independent oracle for
# the graph executor.  Mirrors `design_building` (design_workflow.jl:470-548) as
# it was BEFORE the graph refactor, minus visualization (skipped) and the
# read-only pre-sizing validation (no effect on the invariants for a valid DDM
# building).
function run_reference_path(struc::BuildingStructure, params::DesignParameters)
    t_start = time()

    prepare!(struc, params)

    for stage in build_pipeline(params)
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params=params)
    end

    if params.uniform_column_sizing !== :off
        n_harmonized = SS.harmonize_uniform_column_sizes!(struc, params)
        n_harmonized > 0 && sync_asap!(struc; params=params)
    end

    design = capture_design(struc, params; t_start=t_start)

    restore!(struc; geometry_is_centerline=params.geometry_is_centerline)
    return design
end

# -----------------------------------------------------------------------------
# Invariant extraction from a captured BuildingDesign.
# -----------------------------------------------------------------------------
# Reads only the post-`restore!`-durable captured results (SlabDesignResult,
# ColumnDesignResult, FoundationDesignResult, DesignSummary) plus the source
# structure's geometry (cell areas, which `restore!` does not touch).  Must be
# called BEFORE any subsequent run mutates `struc`, since `sizer_result` is a
# reference into the sized slab result.
function extract_invariants(design::BuildingDesign)
    slabs = collect(values(design.slabs))
    isempty(slabs) && error("extract_invariants: design has no slabs")

    # Slab scalars — a single flat-plate panel here; `maximum` is a
    # deterministic, order-independent reduction if there are several.
    h_m        = maximum(ustrip(u"m", s.thickness) for s in slabs)
    M0_kNm     = maximum(isnothing(s.M0) ? NaN : ustrip(u"kN*m", s.M0) for s in slabs)
    punch      = maximum(s.punching_max_ratio for s in slabs)
    defl       = maximum(s.deflection_ratio  for s in slabs)

    # Reinforcement totals — summed over the sizer result exactly as the speedup
    # harness does from `slab.result` (run_flat_plate_speedup_validation.jl:391-392).
    As_cs = 0.0u"inch^2"
    As_ms = 0.0u"inch^2"
    for s in slabs
        r = s.sizer_result
        isnothing(r) && continue
        if hasproperty(r, :column_strip_reinf)
            As_cs += sum(sr.As_provided for sr in r.column_strip_reinf; init = 0.0u"inch^2")
        end
        if hasproperty(r, :middle_strip_reinf)
            As_ms += sum(sr.As_provided for sr in r.middle_strip_reinf; init = 0.0u"inch^2")
        end
    end
    As_cs_in2    = ustrip(u"inch^2", As_cs)
    As_ms_in2    = ustrip(u"inch^2", As_ms)
    As_total_in2 = ustrip(u"inch^2", As_cs + As_ms)

    # Column min/max c1 (in) — mirrors speedup `cols_in = [c.c1 …]` (line 407).
    cols_in = [ustrip(u"inch", c.c1) for c in values(design.columns) if c.c1 > 0.0u"m"]
    col_min = isempty(cols_in) ? NaN : minimum(cols_in)
    col_max = isempty(cols_in) ? NaN : maximum(cols_in)

    # Embodied carbon (frozen in the summary by capture_design → compute_building_ec).
    ec_total = ustrip(u"kgCO2e", design.summary.embodied_carbon)
    struc    = design.structure
    area_m2  = 0.0
    for idx in keys(design.slabs)
        (idx < 1 || idx > length(struc.slabs)) && continue
        slab = struc.slabs[idx]
        for ci in slab.cell_indices
            (ci < 1 || ci > length(struc.cells)) && continue
            area_m2 += ustrip(u"m^2", struc.cells[ci].area)
        end
    end
    ec_per_area = area_m2 > 0.0 ? ec_total / area_m2 : NaN

    # Foundation dims/util — max over sized footings (order-independent).
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
        h_m                    = h_m,
        M0_kNm                 = M0_kNm,
        punch_ratio            = punch,
        defl_ratio             = defl,
        As_cs_in2              = As_cs_in2,
        As_ms_in2              = As_ms_in2,
        As_total_in2           = As_total_in2,
        col_min_in             = col_min,
        col_max_in             = col_max,
        ec_total_kgco2e        = ec_total,
        ec_per_area_kgco2e_m2  = ec_per_area,
        fdn_max_B_ft           = B_ft,
        fdn_max_L_ft           = L_ft,
        fdn_max_D_in           = D_in,
        fdn_max_util           = util,
    )
end

# -----------------------------------------------------------------------------
# Diff helpers — mirrored from run_flat_plate_speedup_validation.jl:755-807.
# -----------------------------------------------------------------------------

"""
    _close(a, b; rtol, atol) -> Bool

Numeric closeness with NaN-aware semantics: two NaNs compare equal.  Non-float
values fall back to `isequal`.
"""
function _close(a, b; rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    if a isa AbstractFloat && b isa AbstractFloat
        (isnan(a) && isnan(b)) && return true
        return isapprox(a, b; rtol = rtol, atol = atol)
    end
    return isequal(a, b)
end

"""
    diff_invariants(graph_inv, ref_inv; rtol, atol) -> Vector{NamedTuple}

Compare the two invariant NamedTuples column-by-column over `INVARIANT_COLS`.
Returns a vector of mismatch records `(column, graph, reference, diff)`.  An
empty vector means the graph path is bit-equivalent (within tolerance) to the
independent reference path.
"""
function diff_invariants(graph_inv, ref_inv;
                         rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    mismatches = NamedTuple[]
    for col in INVARIANT_COLS
        vg = getproperty(graph_inv, col)
        vr = getproperty(ref_inv, col)
        if !_close(vg, vr; rtol = rtol, atol = atol)
            d = (vg isa AbstractFloat && vr isa AbstractFloat) ? abs(vg - vr) : NaN
            push!(mismatches, (column = col, graph = vg, reference = vr, diff = d))
        end
    end
    return mismatches
end

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

# Run one differential case: build → graph path → reference path → diff.
# Returns `true` when all invariants match (case PASS), `false` otherwise.
function verify_case(label::String, description::String, build_fn::Function)
    println("-" ^ 70)
    println("CASE: $label")
    println("  $description")
    println()

    struc, params = build_fn()

    # ── Graph path (current design_building) ──────────────────────────────
    println("  Running GRAPH path (design_building → DesignGraph/execute_graph!) …")
    t0 = time()
    graph_design = design_building(struc, params)
    t_graph = time() - t0
    # Extract BEFORE the reference run mutates `struc` (sizer_result aliasing).
    graph_inv = extract_invariants(graph_design)
    @printf("    graph path elapsed: %.2f s\n", t_graph)

    # ── Reference path (legacy build_pipeline stage loop, direct) ─────────
    println("  Running REFERENCE path (build_pipeline stage loop, direct) …")
    t0 = time()
    ref_design = run_reference_path(struc, params)
    t_ref = time() - t0
    ref_inv = extract_invariants(ref_design)
    @printf("    reference path elapsed: %.2f s\n\n", t_ref)

    # ── Diff ───────────────────────────────────────────────────────────────
    diffs = diff_invariants(graph_inv, ref_inv)

    println("  Invariant comparison (rtol=1e-8, atol=1e-10, NaN==NaN):")
    @printf("    %-24s | %22s | %22s\n", "invariant", "graph", "reference")
    println("    " * "─"^74)
    for col in INVARIANT_COLS
        vg = getproperty(graph_inv, col)
        vr = getproperty(ref_inv, col)
        mark = any(m -> m.column === col, diffs) ? "✗" : "✓"
        @printf("    %s %-22s | %22s | %22s\n", mark, String(col), repr(vg), repr(vr))
    end
    println()

    if isempty(diffs)
        println("  ✓ PASS — all $(length(INVARIANT_COLS)) invariants match between the " *
                "graph path and the independent legacy reference.")
        return true
    else
        println("  ✗ FAIL — $(length(diffs)) invariant mismatch(es):")
        for d in diffs
            @printf("    %-24s graph=%s reference=%s diff=%s\n",
                    String(d.column), repr(d.graph), repr(d.reference), repr(d.diff))
        end
        return false
    end
end

function main()
    println("=" ^ 70)
    println("DesignGraph differential verify — graph path vs legacy stage loop")
    println("=" ^ 70)
    println()

    cases = (
        ("flat-plate DDM (reconcile columns, foundations on)",
         "gen_medium_office 54'×42'×10', 2×2 bays, 1 story, DDM flat plate, " *
         "foundations on. Stage 2 = _reconcile_columns! (needs_sync=false).",
         build_verify_building),
        ("beam/column (vault floor, _size_beams_columns! + needs_sync)",
         "gen_medium_office 30'×24'×12', 2×2 bays, 1 story, vault floor (λ=8). " *
         "Stage 2 = _size_beams_columns! (needs_sync=true) — exercises the " *
         "second sync branch.",
         build_beam_column_building),
        ("flat-plate DDM + uniform_column_sizing=:per_story (harmonize runs)",
         "gen_medium_office 54'×42'×10', 2×2 bays, 1 story, DDM flat plate, " *
         "foundations on, per-story column harmonization.",
         build_per_story_building),
    )

    all_pass = true
    for (label, description, build_fn) in cases
        ok = verify_case(label, description, build_fn)
        all_pass &= ok
        println()
    end

    println("=" ^ 70)
    if all_pass
        println("✓ ALL CASES PASS — graph path matches the independent legacy reference.")
        println("=" ^ 70)
        return 0
    else
        println("✗ ONE OR MORE CASES FAILED — see per-case output above.")
        println("=" ^ 70)
        return 1
    end
end

# Auto-run only when executed as a script (not when `include`-ed for REPL /
# test reuse) — same gate as run_flat_plate_speedup_validation.jl:927-929.
if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
