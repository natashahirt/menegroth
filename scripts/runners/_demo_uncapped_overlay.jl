# =============================================================================
# Demo: minimal uncapped-columns sweep + failure-heatmap overlay
# =============================================================================
#
# Sanity-check the `_uncapped_max_col` helper and the `col_overlay_threshold`
# overlay on a small grid (3 spans × 3 spans × 1 LL × 2 methods × flat-plate)
# without paying the ~20-minute cost of `run_heatmap_sweep.jl quick uncapped`.
#
# IMPORTANT: method `name` strings MUST match `METHOD_ORDER` from `vis.jl` —
# otherwise `plot_failure_heatmap` won't find the rows and the panel renders
# as "Non Convergence" (grey) even when the cells converged.
#
# Run from project root:
#   julia --project=StructuralStudies scripts/runners/_demo_uncapped_overlay.jl
# =============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

# Two fast methods. Names match `METHOD_ORDER` in `vis.jl` so the plotter
# matches our rows back to the right panels.
const _DEMO_METHODS = [
    (key=:ddm, name="DDM (Full)", method=SR.DDM(:full)),
    (key=:fea, name="FEA",        method=SR.FEA(; pattern_loading=false, design_approach=:frame)),
]
@eval flat_plate_method_comparison_methods() = _DEMO_METHODS  # documentation only

const _DEMO_SPANS = (24.0, 30.0, 36.0)   # 3×3 grid — enough cells to read off

# Helper: print + flush so progress is visible in real time even when stdout
# is redirected to a file (Julia full-buffers redirected stdout by default).
_say(args...) = (println(args...); flush(stdout))

_say("\n=== UNCAPPED DEMO ($(length(_DEMO_SPANS))×$(length(_DEMO_SPANS)) grid, ",
     "$(length(_DEMO_METHODS)) methods, 1 LL, flat-plate only) ===\n")
df = NamedTuple[]
n_total = length(_DEMO_SPANS)^2 * length(_DEMO_METHODS)
n_done  = 0
for span_x in _DEMO_SPANS, span_y in _DEMO_SPANS
    ht      = _adaptive_story_ht(max(span_x, span_y))
    max_col = _uncapped_max_col(max(span_x, span_y))   # uncapped column ceiling
    base_params = _make_params(; floor_type = :flat_plate, sdl_psf = 20.0,
                                  max_col_in = max_col)
    skel  = _build_skeleton(span_x, span_y, ht, 3)
    struc = BuildingStructure(skel)
    prepare!(struc, base_params)
    for mcfg in _DEMO_METHODS
        n_done += 1
        _say(@sprintf("  [%d/%d] %dx%d  %-12s  …", n_done, n_total,
                      round(Int, span_x), round(Int, span_y), mcfg.name))
        t0 = time()
        row = _run_method(struc, base_params, mcfg;
                          lx_ft = span_x, ly_ft = span_y, live_psf = 50.0,
                          floor_type = :flat_plate)
        dt = time() - t0
        if !isnothing(row)
            push!(df, row)
            tag = hasproperty(row, :converged) && row.converged ? "OK" : "FAIL"
            _say(@sprintf("        → %-4s  (%.1fs)  col_max=%.1f\"  failures=%s",
                          tag, dt, coalesce(row.col_max_in, NaN),
                          coalesce(row.failures, "-")))
        end
    end
end

println("\n=== Rendering failure heatmap with 60\" practical-column contour ===\n")

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))
using CairoMakie
CairoMakie.activate!()

using DataFrames
df_table = DataFrame(df)
Base.invokelatest(plot_failure_heatmap, df_table;
                  floor_type = "flat_plate",
                  file_suffix = "_uncapped_demo",
                  col_overlay_threshold = 60.0)

println("\nDone. Saved to ",
        joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "figs",
                 "12_failure_flat_plate_uncapped_demo.png"))
