# =============================================================================
# Debug runner: capture the FULL stacktrace for the BoundsError in the
# flat-plate slab/column pipeline. The normal sweep wraps the pipeline in
# `try/catch` + `sprint(showerror, e)`, which loses the backtrace; this script
# bypasses that wrapper so we can see the failing line.
# =============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

using StructuralSizer
using StructuralSynthesizer

println("\n=== DEBUG: reproducing BoundsError with full stacktrace ===\n")

# Smallest possible setup: 24 ft square bay, FEA, single LL.
span_x, span_y = 24.0, 24.0
ht       = _adaptive_story_ht(span_x)
max_col  = 60.0   # capped (well within high_capacity catalog 18-72")
params   = _make_params(; floor_type   = :flat_plate,
                          sdl_psf      = 20.0,
                          live_psf     = 50.0,
                          max_col_in   = max_col,
                          method       = StructuralSizer.FEA(; pattern_loading = false,
                                                                design_approach = :frame))
skel  = _build_skeleton(span_x, span_y, ht, 3)
struc = BuildingStructure(skel)
prepare!(struc, params)

println("Setup complete. Running pipeline INLINE (no try/catch wrapper)...\n")

stages = build_pipeline(params)
for (i, stage) in enumerate(stages)
    println(">>> Stage $i: $(stage.fn)")
    try
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params = params)
        println("    OK")
    catch e
        println("    >>> EXCEPTION caught at stage $i:")
        println(sprint(Base.showerror, e))
        println("\n>>> Stacktrace:")
        for (k, frame) in enumerate(stacktrace(catch_backtrace()))
            println("  [$k] ", frame)
            k >= 30 && (println("  ... (truncated)"); break)
        end
        rethrow()
    end
end
