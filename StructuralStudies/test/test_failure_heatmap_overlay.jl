# =============================================================================
# Test: practical-column contour overlay on the failure-mode heatmap
# =============================================================================
#
# Smoke test for the `col_overlay_threshold` keyword added to
# `plot_failure_heatmap` / `plot_dual_failure_heatmaps`. Builds a synthetic
# DataFrame whose `col_max_in` straddles the 60" practical-column boundary
# and verifies that:
#   1. The plot writes a PNG without error when `col_overlay_threshold` is
#      set (the contour code path).
#   2. The plot writes a PNG without error when `col_overlay_threshold` is
#      `nothing` (the legacy code path — backward compatibility).
#   3. The plot writes a PNG without error when the DataFrame has no
#      `col_max_in` column at all (defensive code path — older sweeps).
#
# Skips the live pipeline; ~5–15 s once StructuralStudies is precompiled.
#
# Run from project root:
#   julia --project=StructuralStudies StructuralStudies/test/test_failure_heatmap_overlay.jl
# =============================================================================

using Test
using DataFrames

include(joinpath(@__DIR__, "..", "src", "flat_plate_methods", "vis.jl"))

# Redirect figure output to a tmp dir so the test doesn't pollute figs/.
tmp_figs = mktempdir()
@eval function _save_fig(fig, name)
    ensure_dir($tmp_figs)
    path = joinpath($tmp_figs, name)
    save(path, fig; px_per_unit = 2)
    return fig
end

# ── Synthetic DataFrame ────────────────────────────────────────────────────
#
# 4 spans × 4 spans × 1 LL × 4 methods. col_max_in straddles 60" so there is a
# real boundary for the contour to trace. Failure modes vary by span so the
# heatmap is non-trivial.
methods = ["MDDM", "DDM (Full)", "EFM (ASAP)", "FEA"]
spans   = [20.0, 28.0, 36.0, 44.0]
rows = NamedTuple[]
for m in methods, lx in spans, ly in spans
    aspect = max(lx, ly) / min(lx, ly)
    converged = aspect ≤ 2.0 && lx ≤ 36.0 && ly ≤ 36.0
    # col_max_in scales with span — crosses 60 inches around 32 ft span.
    col_max_in = 1.7 * max(lx, ly)
    failures = if !converged && aspect > 2.0
        "ddm_ineligible"
    elseif !converged
        "punching"      # let the longer-span runs fail by punching
    else
        ""
    end
    push!(rows, (
        method        = m,
        lx_ft         = lx,
        ly_ft         = ly,
        live_psf      = 50.0,
        floor_type    = "flat_plate",
        h_in          = converged ? 5.0 + 0.18 * lx : NaN,
        col_max_in    = converged ? col_max_in : NaN,
        ddm_eligible  = aspect ≤ 2.0,
        failures      = failures,
        failing_check = failures,
        converged     = converged,
    ))
end
df = DataFrame(rows)

@testset "Failure-heatmap practical-column contour overlay" begin

    @testset "df fixture has values straddling the 60\" threshold" begin
        # Sanity: the synthetic data must cover both sides of the threshold,
        # otherwise the contour would degenerate to nothing.
        cv = filter(!isnan, df.col_max_in)
        @test any(cv .< 60.0)
        @test any(cv .> 60.0)
    end

    @testset "renders with overlay threshold = 60.0\"" begin
        plot_failure_heatmap(df; floor_type = "flat_plate",
                                  file_suffix = "_overlay",
                                  col_overlay_threshold = 60.0)
        @test isfile(joinpath(tmp_figs, "12_failure_flat_plate_overlay.png"))
    end

    @testset "renders without overlay (nothing — legacy behaviour)" begin
        plot_failure_heatmap(df; floor_type = "flat_plate",
                                  file_suffix = "_no_overlay")
        @test isfile(joinpath(tmp_figs, "12_failure_flat_plate_no_overlay.png"))
    end

    @testset "renders cleanly when col_max_in is missing" begin
        df_no_col = select(df, Not(:col_max_in))
        plot_failure_heatmap(df_no_col; floor_type = "flat_plate",
                                       file_suffix = "_no_col_col",
                                       col_overlay_threshold = 60.0)
        @test isfile(joinpath(tmp_figs, "12_failure_flat_plate_no_col_col.png"))
    end

    @testset "plot_dual_failure_heatmaps forwards the overlay kwarg" begin
        plot_dual_failure_heatmaps(df; file_suffix = "_dual",
                                      col_overlay_threshold = 60.0)
        @test isfile(joinpath(tmp_figs, "12_failure_flat_plate_dual.png"))
        # Flat-slab variant should also be produced (empty data → still
        # creates a fig with placeholder, or skips cleanly).
    end
end

println("\n✓ Failure-heatmap overlay smoke test passed.")
println("  Wrote PNGs to $tmp_figs")
