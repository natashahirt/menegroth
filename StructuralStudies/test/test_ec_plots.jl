# =============================================================================
# Test: Section 1 EC plot smoke test (synthetic DataFrame, no pipeline)
# =============================================================================
#
# Verifies that the new EC visualization functions in vis.jl render without
# error and write the expected PNG files. Uses a small synthetic DataFrame
# whose schema mirrors the columns produced by `_extract_results` after
# adding the slab_ec_kgco2e / slab_area_m2 / slab_ec_per_m2 fields.
#
# Skips the (slow) pipeline by hand-constructing the DataFrame, so this
# test runs in ~5–15 s once StructuralStudies is precompiled.
#
# Run from project root:
#   julia --project=StructuralStudies StructuralStudies/test/test_ec_plots.jl
# =============================================================================

using Test
using DataFrames

# Load vis.jl (also pulls in init.jl + StructuralPlots / CairoMakie)
include(joinpath(@__DIR__, "..", "src", "flat_plate_methods", "vis.jl"))

# Override output dir to a tmp location so the test doesn't pollute the
# checked-in figs directory.
tmp_figs = mktempdir()

# vis.jl writes figures to FP_FIGS_DIR (a const). Monkey-patch by
# redefining _save_fig to point at the tmp dir.
@eval function _save_fig(fig, name)
    ensure_dir($tmp_figs)
    path = joinpath($tmp_figs, name)
    save(path, fig; px_per_unit = 2)
    return fig
end

# ── Build a synthetic sweep DataFrame ────────────────────────────────────────
#
# Mirrors the schema of _extract_results / _blank_failure_row for a
# 3 lx × 3 ly × 2 LL × 3 method × 1 floor type sweep (54 rows).
# EC values are physically plausible (50–250 kgCO₂e/m²).

methods    = ["MDDM", "DDM (Full)", "FEA"]
spans      = [20.0, 28.0, 36.0]
live_loads = [50.0, 100.0]

rows = NamedTuple[]
for m in methods, lx in spans, ly in spans, ll in live_loads
    # Synthetic h: scales with span, slightly larger for higher LL
    h_in = 5.0 + 0.18 * lx + 0.005 * ll
    # Synthetic EC density: scales with thickness × ECC × density
    ec_per_m2 = 0.0254 * h_in * 2380.0 * 0.127 + 25.0  # rebar contribution (ECC matches NWC_4000 median)
    # FEA gives slightly different (lower) result by design
    if m == "FEA"
        ec_per_m2 *= 0.9
        h_in     *= 0.92
    end
    floor_area = (3 * lx)^2 * 0.092903     # ft² → m²
    # Synthetic MUI: concrete = h × ρ_NWC, rebar ≈ 5% by volume
    t_eq_m       = 0.0254 * h_in
    conc_kg_m2   = t_eq_m * 2380.0
    rebar_kg_m2  = 0.005 * t_eq_m * 7850.0
    mui_kg_m2    = conc_kg_m2 + rebar_kg_m2
    push!(rows, (
        method        = m,
        lx_ft         = lx,
        ly_ft         = ly,
        span_ft       = lx,
        live_psf      = ll,
        floor_type    = "flat_plate",
        h_in          = h_in,
        M0_kipft      = 0.125 * 0.001 * (sdl_mock = 70.0) * lx * ly^2,
        punch_ratio   = 0.6,
        defl_ratio    = 0.5,
        col_max_in    = 18.0,
        As_total_in2  = 12.0,
        runtime_s     = 1.0,
        h_drop_in     = 0.0,
        a_drop1_ft    = 0.0,
        a_drop2_ft    = 0.0,
        slab_ec_kgco2e = ec_per_m2 * floor_area,
        slab_area_m2   = floor_area,
        slab_ec_per_m2 = ec_per_m2,
        concrete_vol_m3    = t_eq_m * floor_area,
        rebar_vol_m3       = 0.005 * t_eq_m * floor_area,
        concrete_mass_kg   = conc_kg_m2  * floor_area,
        rebar_mass_kg      = rebar_kg_m2 * floor_area,
        slab_mass_kg       = mui_kg_m2   * floor_area,
        mui_kg_per_m2      = mui_kg_m2,
        concrete_kg_per_m2 = conc_kg_m2,
        rebar_kg_per_m2    = rebar_kg_m2,
        concrete_t_eq_m    = t_eq_m,
        rebar_vol_per_m2   = 0.005 * t_eq_m,
        converged     = true,
        ddm_eligible  = !(ly / lx > 2.0 || lx / ly > 2.0),
    ))
end
df = DataFrame(rows)

@testset "Section 1 EC plots — synthetic DataFrame" begin

    @testset "schema sanity" begin
        @test :slab_ec_per_m2  in propertynames(df)
        @test :mui_kg_per_m2   in propertynames(df)
        @test :concrete_t_eq_m in propertynames(df)
        @test :converged       in propertynames(df)
        @test all(df.slab_ec_per_m2  .> 0)
        @test all(df.mui_kg_per_m2   .> 0)
        @test all(df.concrete_t_eq_m .> 0)
    end

    @testset "plot_slab_ec writes PNG" begin
        plot_slab_ec(df)
        @test isfile(joinpath(tmp_figs, "12_slab_ec.png"))
    end

    @testset "plot_slab_mui writes PNG" begin
        plot_slab_mui(df)
        @test isfile(joinpath(tmp_figs, "13_slab_mui.png"))
    end

    @testset "plot_slab_t_eq writes PNG" begin
        plot_slab_t_eq(df)
        @test isfile(joinpath(tmp_figs, "13b_concrete_t_eq.png"))
    end

    @testset "plot_ec_heatmap writes PNG" begin
        plot_ec_heatmap(df; floor_type = "flat_plate")
        @test isfile(joinpath(tmp_figs, "14_ec_heatmap_flat_plate.png"))
    end

    @testset "plot_dual_ec_heatmaps with locked range" begin
        # Re-run to verify the dual-heatmap helper computes the range
        # automatically and dispatches to both floor types (only flat_plate
        # rows present, so flat_slab call should no-op cleanly).
        plot_dual_ec_heatmaps(df)
        @test isfile(joinpath(tmp_figs, "14_ec_heatmap_flat_plate.png"))
    end

    @testset "missing column → no crash, prints skip" begin
        df_no_ec = select(df, Not(:slab_ec_per_m2))
        @test isnothing(plot_ec_heatmap(df_no_ec; floor_type = "flat_plate"))
        @test isnothing(plot_dual_ec_heatmaps(df_no_ec))
    end

    # ── Concrete-axis overlay plots ─────────────────────────────────────────
    # Synthesize a second-concrete dataframe by scaling EC and MUI to mimic
    # the LWC behavior (higher per-m² EC, lower per-m² mass).
    @testset "plot_*_by_concrete with two presets" begin
        df_nwc = copy(df); df_nwc.concrete = fill("NWC_4000", nrow(df))
        df_lwc = copy(df); df_lwc.concrete = fill("LWC_4000", nrow(df))
        df_lwc.slab_ec_per_m2     .*= 1.95   # mirror per-m³ EC ratio
        df_lwc.concrete_kg_per_m2 .*= 0.77   # mirror density ratio
        df_lwc.mui_kg_per_m2      .*= 0.78
        df_lwc.concrete_t_eq_m    .*= 1.05   # mild thickness growth
        df2 = vcat(df_nwc, df_lwc)

        plot_slab_ec_by_concrete(df2)
        plot_slab_mui_by_concrete(df2)
        plot_slab_t_eq_by_concrete(df2)
        @test isfile(joinpath(tmp_figs, "14_slab_ec_by_concrete.png"))
        @test isfile(joinpath(tmp_figs, "15_slab_mui_by_concrete.png"))
        @test isfile(joinpath(tmp_figs, "15b_concrete_t_eq_by_concrete.png"))

        # Defensive: missing concrete column → returns nothing rather than crashing.
        @test isnothing(plot_slab_ec_by_concrete(df))
    end
end

println("\n✓ Section 1 EC plot smoke test passed.")
println("  Wrote PNGs to $tmp_figs")
