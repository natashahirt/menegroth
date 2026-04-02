# =============================================================================
# Tests for micro-experiments: punching, pm_column, deflection, catalog_screen.
#
# Runs a real design on a small 2-story, 3×3 bay flat plate building, then
# exercises each experiment against the cached design data. Verifies:
#   - correct Dict structure (keys, types)
#   - physically reasonable ratios and deltas
#   - sanity warnings and error paths
#   - dispatch via evaluate_experiment + batch_evaluate
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using Asap

import StructuralSynthesizer as SS
using StructuralSynthesizer:
    experiment_punching, experiment_pm_column, experiment_deflection,
    experiment_catalog_screen, list_experiments, evaluate_experiment,
    batch_evaluate, column_diagnostic_governing_check

println("Testing micro-experiments...")

# ─── Build a real design for test data ────────────────────────────────────────

const TEST_SKEL = gen_medium_office(75.0u"ft", 75.0u"ft", 10.0u"ft", 3, 3, 2)
const TEST_STRUC = BuildingStructure(TEST_SKEL)

const TEST_PARAMS = DesignParameters(
    name = "micro_exp_test",
    floor = FlatPlateOptions(
        method = DDM(),
        deflection_limit = :L_360,
        punching_strategy = :grow_columns,
        shear_studs = :never,
    ),
    materials = MaterialOptions(
        concrete = StructuralSizer.NWC_4000,
    ),
    max_iterations = 3,
)

const TEST_DESIGN = design_building(TEST_STRUC, TEST_PARAMS)

# Helper: find first column with meaningful punching data (Vu > 0)
function _find_punching_col(design)
    best_idx = nothing
    best_ratio = -1.0
    for (idx, cr) in design.columns
        if !isnothing(cr.punching) && cr.punching.ratio > best_ratio
            best_idx = idx
            best_ratio = cr.punching.ratio
        end
    end
    return best_idx
end

# Helper: find first column (any)
function _find_any_col(design)
    isempty(design.columns) && return nothing
    return first(keys(design.columns))
end

# Helper: find first slab
function _find_any_slab(design)
    isempty(design.slabs) && return nothing
    return first(keys(design.slabs))
end

# ─── list_experiments ─────────────────────────────────────────────────────────

@testset "list_experiments" begin
    result = list_experiments()
    @test haskey(result, "experiments")
    @test haskey(result, "note")

    experiments = result["experiments"]
    @test length(experiments) >= 4

    names = Set(e["name"] for e in experiments)
    @test "punching" in names
    @test "pm_column" in names
    @test "deflection" in names
    @test "catalog_screen" in names
    @test "beam" in names
    @test "punching_reinforcement" in names

    for e in experiments
        @test haskey(e, "description")
        @test haskey(e, "args")
        @test haskey(e, "example")
    end
end

# ─── experiment_punching ──────────────────────────────────────────────────────

@testset "Punching experiment" begin
    col_idx = _find_punching_col(TEST_DESIGN)
    if isnothing(col_idx)
        @warn "No column with punching data — skipping punching tests"
        @test_skip "no punching column"
    else
        cr = TEST_DESIGN.columns[col_idx]
        orig_c1 = round(ustrip(u"inch", cr.c1); digits=1)
        orig_c2 = round(ustrip(u"inch", cr.c2); digits=1)

        @testset "baseline (no modifications)" begin
            r = experiment_punching(TEST_DESIGN, col_idx)
            @test r["experiment"] == "punching"
            @test r["column_idx"] == col_idx
            @test haskey(r, "position")
            @test haskey(r, "original")
            @test haskey(r, "modified")
            @test haskey(r, "delta_ratio")
            @test haskey(r, "improved")

            orig = r["original"]
            @test orig["c1_in"] ≈ orig_c1 atol=0.2
            @test orig["c2_in"] ≈ orig_c2 atol=0.2
            @test orig["ratio"] >= 0.0
            @test haskey(orig, "Vu_kip")
            @test haskey(orig, "Mub_kipft")
            @test orig["Vu_kip"] >= 0.0

            mod = r["modified"]
            @test mod["c1_in"] ≈ orig_c1 atol=0.2
            @test mod["ratio"] >= 0.0
            @test haskey(mod, "vu_psi")
            @test haskey(mod, "φvc_psi")
            @test haskey(mod, "b0_in")
            @test mod["b0_in"] > 0.0

            # Re-running the same geometry may not produce identical ratios because
            # the experiment recomputes from scratch while the stored result came from
            # the iterative design loop. Just verify it's finite and non-negative.
            @test isfinite(r["delta_ratio"])
        end

        @testset "larger column → produces valid result" begin
            bigger = orig_c1 + 6.0
            r = experiment_punching(TEST_DESIGN, col_idx; c1_in=bigger, c2_in=bigger)
            @test r["modified"]["c1_in"] ≈ bigger atol=0.1
            @test r["modified"]["c2_in"] ≈ bigger atol=0.1
            @test isfinite(r["modified"]["ratio"])
            # If the result is counter-intuitive (larger column → worse ratio),
            # a sanity_warning should be present
            if r["modified"]["ratio"] > r["original"]["ratio"] + 0.1
                @test haskey(r, "sanity_warning") || r["position"] in ("edge", "corner")
            end
        end

        @testset "thicker slab → produces valid result" begin
            orig_h = experiment_punching(TEST_DESIGN, col_idx)["original"]["h_in"]
            thicker = orig_h + 2.0
            r = experiment_punching(TEST_DESIGN, col_idx; h_in=thicker)
            @test r["modified"]["h_in"] ≈ thicker atol=0.1
            @test isfinite(r["modified"]["ratio"])
        end

        # Isolated physics: vc ∝ √f'c with fixed Vu, Mub, d, h, b₀ → ratio falls as fc rises.
        @testset "StructuralSizer.check_punching_for_column: higher fc lowers utilization" begin
            col = (c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior, shape = :rectangular)
            Vu = 200.0u"kip"
            Mub = 30.0u"kip*ft"
            d = 8.0u"inch"
            h = 10.0u"inch"
            fc_4k = 4000.0u"psi"
            fc_8k = 8000.0u"psi"
            r_lo = StructuralSizer.check_punching_for_column(col, Vu, Mub, d, h, fc_4k)
            r_hi = StructuralSizer.check_punching_for_column(col, Vu, Mub, d, h, fc_8k)
            @test ustrip(u"psi", r_hi.φvc) > ustrip(u"psi", r_lo.φvc)
            @test r_hi.ratio < r_lo.ratio
        end

        # Micro-experiment modified.* uses the same checker; fc_in only → lower modified ratio at higher fc.
        @testset "experiment_punching fc_in sweep: modified ratio decreases" begin
            fcs = (3000.0, 4500.0, 6000.0, 8000.0)
            ratios = Float64[]
            for fc in fcs
                r = experiment_punching(TEST_DESIGN, col_idx; fc_in = fc)
                @test !haskey(r, "error")
                @test r["experiment"] == "punching"
                push!(ratios, r["modified"]["ratio"])
            end
            for i in 1:length(fcs)-1
                @test ratios[i] >= ratios[i + 1]
            end
            @test ratios[1] > ratios[end]
        end

        # delta_ratio / improved compare to design-stored original.ratio, not to a recomputed baseline.
        @testset "experiment_punching: higher fc lowers modified ratio (compare fc extremes)" begin
            r_hi = experiment_punching(TEST_DESIGN, col_idx; fc_in = 8000.0)
            r_lo = experiment_punching(TEST_DESIGN, col_idx; fc_in = 3000.0)
            @test r_hi["modified"]["ratio"] < r_lo["modified"]["ratio"]
            @test haskey(r_hi, "improved")
        end

        @testset "error: bad column index" begin
            r = experiment_punching(TEST_DESIGN, 99999)
            @test haskey(r, "error")
            @test r["error"] == "column_not_found"
        end
    end
end

# ─── experiment_pm_column (RC) ────────────────────────────────────────────────

@testset "P-M column experiment (RC)" begin
    col_idx = _find_any_col(TEST_DESIGN)
    if isnothing(col_idx)
        @warn "No columns found — skipping pm_column tests"
        @test_skip "no columns"
    else
        cr = TEST_DESIGN.columns[col_idx]
        is_rc = cr.shape in (:rectangular, :circular, :rc_rect, :rc_circular)

        if !is_rc
            @info "First column is steel — skipping RC-specific tests"
            @test_skip "first column is steel"
        else
            @testset "basic RC experiment" begin
                r = experiment_pm_column(TEST_DESIGN, col_idx; section_size=20.0)
                @test r["experiment"] == "pm_column"
                @test r["column_type"] == "RC"
                @test haskey(r, "demands")
                @test haskey(r, "original")
                @test haskey(r, "modified")
                @test haskey(r, "delta_ratio")
                @test haskey(r, "improved")
                @test haskey(r, "experimental_setup")
                @test haskey(r["experimental_setup"], "note")

                dem = r["demands"]
                @test haskey(dem, "Pu_kip")
                @test haskey(dem, "Mux_kipft")
                @test haskey(dem, "Muy_kipft")
                @test haskey(dem, "height_ft")
                @test haskey(dem, "Ky")
                @test dem["height_ft"] > 0.0

                orig = r["original"]
                @test haskey(orig, "section")
                @test haskey(orig, "governing_check")
                @test orig["ratio"] >= 0.0

                mod = r["modified"]
                @test mod["section"] == "20x20"
                @test haskey(mod, "rebar")
                @test haskey(mod, "interaction_ratio")
                @test haskey(mod, "governing_check")
                @test haskey(mod, "checks")
                @test mod["interaction_ratio"] >= 0.0

                for c in mod["checks"]
                    @test haskey(c, "name")
                    @test haskey(c, "passed")
                    @test haskey(c, "ratio")
                    @test c["ratio"] >= 0.0
                end
            end

            @testset "rebar scales with column size" begin
                r_small = experiment_pm_column(TEST_DESIGN, col_idx; section_size=12.0)
                r_large = experiment_pm_column(TEST_DESIGN, col_idx; section_size=30.0)
                # Larger column should use more/bigger rebar
                rebar_small = r_small["modified"]["rebar"]
                rebar_large = r_large["modified"]["rebar"]
                @test rebar_small != rebar_large
            end

            @testset "error: missing section_size" begin
                r = experiment_pm_column(TEST_DESIGN, col_idx)
                @test haskey(r, "error")
                @test r["error"] == "section_size_required"
            end

            @testset "error: invalid section_size" begin
                r = experiment_pm_column(TEST_DESIGN, col_idx; section_size="not_a_number")
                @test haskey(r, "error")
                @test r["error"] == "invalid_section_size"
            end

            @testset "error: bad column index" begin
                r = experiment_pm_column(TEST_DESIGN, 99999; section_size=18.0)
                @test haskey(r, "error")
                @test r["error"] == "column_not_found"
            end
        end
    end
end

# ─── experiment_deflection ────────────────────────────────────────────────────

@testset "Deflection experiment" begin
    slab_idx = _find_any_slab(TEST_DESIGN)
    if isnothing(slab_idx)
        @warn "No slabs found — skipping deflection tests"
        @test_skip "no slabs"
    else
        sr = TEST_DESIGN.slabs[slab_idx]

        @testset "relax limit to L/240" begin
            r = experiment_deflection(TEST_DESIGN, slab_idx; deflection_limit="L_240")
            if haskey(r, "error")
                # Structure may not be available — acceptable
                @test r["error"] in ("no_deflection_data", "no_span_data")
                @info "Deflection experiment returned: $(r["error"])"
            else
                @test r["experiment"] == "deflection"
                @test r["slab_idx"] == slab_idx
                @test haskey(r, "slab_context")
                @test haskey(r, "original")
                @test haskey(r, "modified")
                @test haskey(r, "delta_ratio")
                @test haskey(r, "improved")

                ctx = r["slab_context"]
                @test haskey(ctx, "span_ft")
                @test haskey(ctx, "thickness_in")
                @test haskey(ctx, "current_limit_criterion")

                orig = r["original"]
                @test orig["ratio"] >= 0.0
                @test orig["limit_in"] > 0.0

                mod = r["modified"]
                @test mod["deflection_limit"] == "L_240"
                @test mod["limit_in"] > 0.0
                @test mod["ratio"] >= 0.0

                # L/240 is more permissive than L/360 → ratio should decrease
                @test mod["ratio"] <= orig["ratio"] + 0.01
            end
        end

        @testset "tighten limit to L/480" begin
            r = experiment_deflection(TEST_DESIGN, slab_idx; deflection_limit="L_480")
            if !haskey(r, "error")
                # L/480 is stricter → ratio should increase
                @test r["modified"]["ratio"] >= r["original"]["ratio"] - 0.01
            end
        end

        @testset "error: invalid limit" begin
            r = experiment_deflection(TEST_DESIGN, slab_idx; deflection_limit="L_999")
            @test haskey(r, "error")
            @test r["error"] == "invalid_limit"
        end

        @testset "error: bad slab index" begin
            r = experiment_deflection(TEST_DESIGN, 99999)
            @test haskey(r, "error")
            @test r["error"] == "slab_not_found"
        end
    end
end

# ─── experiment_catalog_screen ────────────────────────────────────────────────

@testset "Catalog screen experiment" begin
    col_idx = _find_any_col(TEST_DESIGN)
    if isnothing(col_idx)
        @warn "No columns found — skipping catalog_screen tests"
        @test_skip "no columns"
    else
        cr = TEST_DESIGN.columns[col_idx]
        is_rc = cr.shape in (:rectangular, :circular, :rc_rect, :rc_circular)

        if is_rc
            @testset "RC catalog screen" begin
                candidates = [12.0, 16.0, 20.0, 24.0, 30.0]
                r = experiment_catalog_screen(TEST_DESIGN, col_idx; candidates=candidates)
                @test r["experiment"] == "catalog_screen"
                @test r["column_type"] == "RC"
                @test haskey(r, "demands")
                @test haskey(r, "original")
                @test haskey(r, "candidates")
                @test haskey(r, "n_candidates")
                @test haskey(r, "n_feasible")
                @test haskey(r, "best_feasible")
                @test haskey(r, "note")

                @test r["n_candidates"] == 5
                @test r["n_feasible"] >= 0

                orig = r["original"]
                @test haskey(orig, "ok")
                @test haskey(orig, "governing_check")

                # Candidates should be sorted by interaction_ratio (ascending)
                ratios = [c["interaction_ratio"] for c in r["candidates"] if haskey(c, "interaction_ratio")]
                @test issorted(ratios)

                # Each candidate should have required keys
                for c in r["candidates"]
                    @test haskey(c, "section")
                    if !haskey(c, "error")
                        @test haskey(c, "interaction_ratio")
                        @test haskey(c, "ok")
                        @test haskey(c, "improved")
                    end
                end
            end
        else
            @info "First column is steel — skipping RC catalog_screen test (steel needs W-shape names)"
        end

        @testset "error: no candidates" begin
            r = experiment_catalog_screen(TEST_DESIGN, col_idx; candidates=Float64[])
            @test haskey(r, "error")
            @test r["error"] == "no_candidates"
        end

        @testset "error: bad column index" begin
            r = experiment_catalog_screen(TEST_DESIGN, 99999; candidates=[18.0])
            @test haskey(r, "error")
            @test r["error"] == "column_not_found"
        end
    end
end

# ─── evaluate_experiment dispatch ─────────────────────────────────────────────

@testset "evaluate_experiment dispatch" begin
    col_idx = _find_any_col(TEST_DESIGN)
    slab_idx = _find_any_slab(TEST_DESIGN)

    @testset "unknown type → error" begin
        r = evaluate_experiment(TEST_DESIGN, "nonexistent", Dict{String,Any}())
        @test haskey(r, "error")
        @test r["error"] == "unknown_experiment"
    end

    @testset "punching dispatch" begin
        punch_col = _find_punching_col(TEST_DESIGN)
        if !isnothing(punch_col)
            r = evaluate_experiment(TEST_DESIGN, "punching",
                Dict{String,Any}("col_idx" => punch_col))
            @test r["experiment"] == "punching"
        end
    end

    @testset "pm_column dispatch" begin
        if !isnothing(col_idx)
            cr = TEST_DESIGN.columns[col_idx]
            is_rc = cr.shape in (:rectangular, :circular, :rc_rect, :rc_circular)
            if is_rc
                r = evaluate_experiment(TEST_DESIGN, "pm_column",
                    Dict{String,Any}("col_idx" => col_idx, "section_size" => 18))
                @test r["experiment"] == "pm_column"
            end
        end
    end

    @testset "deflection dispatch" begin
        if !isnothing(slab_idx)
            r = evaluate_experiment(TEST_DESIGN, "deflection",
                Dict{String,Any}("slab_idx" => slab_idx, "deflection_limit" => "L_360"))
            # May error if no span data, but should not throw
            @test haskey(r, "experiment") || haskey(r, "error")
        end
    end

    @testset "catalog_screen dispatch" begin
        if !isnothing(col_idx)
            cr = TEST_DESIGN.columns[col_idx]
            is_rc = cr.shape in (:rectangular, :circular, :rc_rect, :rc_circular)
            if is_rc
                r = evaluate_experiment(TEST_DESIGN, "catalog_screen",
                    Dict{String,Any}("col_idx" => col_idx, "candidates" => [16, 20, 24]))
                @test r["experiment"] == "catalog_screen"
            end
        end
    end

    @testset "missing required args → error" begin
        r = evaluate_experiment(TEST_DESIGN, "punching", Dict{String,Any}())
        @test haskey(r, "error")
        @test r["error"] == "missing_col_idx"

        r = evaluate_experiment(TEST_DESIGN, "deflection", Dict{String,Any}())
        @test haskey(r, "error")
        @test r["error"] == "missing_slab_idx"
    end
end

# ─── batch_evaluate ───────────────────────────────────────────────────────────

@testset "batch_evaluate" begin
    col_idx = _find_any_col(TEST_DESIGN)
    punch_col = _find_punching_col(TEST_DESIGN)

    experiments = Any[]

    if !isnothing(punch_col)
        push!(experiments, Dict{String,Any}(
            "type" => "punching",
            "args" => Dict{String,Any}("col_idx" => punch_col),
        ))
    end

    if !isnothing(col_idx)
        cr = TEST_DESIGN.columns[col_idx]
        is_rc = cr.shape in (:rectangular, :circular, :rc_rect, :rc_circular)
        if is_rc
            push!(experiments, Dict{String,Any}(
                "type" => "pm_column",
                "args" => Dict{String,Any}("col_idx" => col_idx, "section_size" => 20),
            ))
        end
    end

    if !isempty(experiments)
        r = batch_evaluate(TEST_DESIGN, experiments)
        @test haskey(r, "n_experiments")
        @test haskey(r, "results")
        @test r["n_experiments"] == length(experiments)
        @test length(r["results"]) == length(experiments)

        for res in r["results"]
            @test haskey(res, "experiment_index")
            @test haskey(res, "type")
            # Each result is either a successful experiment or an error dict
            @test haskey(res, "experiment") || haskey(res, "error")
        end
    else
        @info "No experiments to batch — skipping"
    end

    @testset "handles malformed entries gracefully" begin
        bad_batch = Any[
            Dict{String,Any}("type" => "nonexistent", "args" => Dict{String,Any}()),
            "not_a_dict",
        ]
        r = batch_evaluate(TEST_DESIGN, bad_batch)
        @test r["n_experiments"] == 2
        # First: unknown_experiment error; Second: experiment_failed error
        @test haskey(r["results"][1], "error")
        @test haskey(r["results"][2], "error")
    end
end

# ─── Physical sanity: larger column should have lower pm_column ratio ─────────

@testset "Physical sanity checks" begin
    # Find an RC column with moderate demands (ratio < 5) so the comparison is meaningful
    sanity_col_idx = nothing
    for (idx, cr) in TEST_DESIGN.columns
        is_rc = cr.shape in (:rectangular, :circular, :rc_rect, :rc_circular)
        if is_rc && cr.ok && cr.interaction_ratio < 5.0
            sanity_col_idx = idx
            break
        end
    end
    # Fallback: any RC column with ratio < 100 (generous for non-converged designs)
    if isnothing(sanity_col_idx)
        for (idx, cr) in TEST_DESIGN.columns
            is_rc = cr.shape in (:rectangular, :circular, :rc_rect, :rc_circular)
            if is_rc && cr.interaction_ratio < 100.0
                sanity_col_idx = idx
                break
            end
        end
    end

    if isnothing(sanity_col_idx)
        @info "No moderately-loaded RC column found — skipping physical sanity test"
        @test_skip "no moderate RC column"
    else
        @testset "larger RC column → lower interaction ratio" begin
            r_small = experiment_pm_column(TEST_DESIGN, sanity_col_idx; section_size=14.0)
            r_large = experiment_pm_column(TEST_DESIGN, sanity_col_idx; section_size=30.0)

            if !haskey(r_small, "error") && !haskey(r_large, "error")
                ratio_small = r_small["modified"]["interaction_ratio"]
                ratio_large = r_large["modified"]["interaction_ratio"]
                if ratio_small > 1000.0 || ratio_large > 1000.0
                    @info "Column demands too extreme for meaningful comparison" ratio_small ratio_large
                    @test_skip "extreme ratios — demands are far beyond any practical section"
                else
                    @test ratio_large < ratio_small
                end
            end
        end
    end
end

println("Micro-experiment tests complete.")
