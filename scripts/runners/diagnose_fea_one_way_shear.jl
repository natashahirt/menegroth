# =============================================================================
# Diagnostic: analytical vs finite-width FEA one-way shear
# =============================================================================
#
# One 20 ft bay, 150 psf, and one 28 ft bay, 50 psf. Prints the thickness,
# the governing check, the analytical Vu, and the diagnostic FEA cut.
# The cut does not size the slab.
#
#   julia --project=StructuralStudies scripts/runners/diagnose_fea_one_way_shear.jl
# =============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

const CASES = [(20.0, 150.0), (28.0, 50.0)]
const FEA = (key=:fea, name="FEA (frame)",
             method=SR.FEA(; pattern_loading=false, design_approach=:frame))

if get(ARGS, 1, "") == "stories"
    println("\n=== 3-story FEA, pattern off then on (20 ft, 150 psf) ===\n")
    base = _make_params(; concrete_label="NWC_4000", max_col_in=_adaptive_max_col(20.0))
    struc = BuildingStructure(_build_skeleton(20.0, 20.0, _adaptive_story_ht(20.0), 3; n_stories=3))
    prepare!(struc, base)
    for pattern in (false, true)
        cfg = (key=:fea, name="FEA (frame)",
               method=SR.FEA(; pattern_loading=pattern, pattern_mode=:efm_amp,
                             design_approach=:frame))
        row = _run_method(struc, base, cfg;
                          lx_ft=20.0, ly_ft=20.0, live_psf=150.0, concrete_label="NWC_4000")
        isnothing(row) && continue
        println("  pattern=$(pattern): h=$(row.h_in) in  story=$(row.story) ($(row.story_role))  " *
                "governing=$(row.governing_check)  reason=$(row.failure_reason)")
    end
    exit(0)
end

println("\n=== FEA one-way shear diagnostic (pattern loading off) ===\n")
for (span, ll) in CASES
    base = _make_params(; concrete_label="NWC_4000", max_col_in=_adaptive_max_col(span))
    struc = BuildingStructure(_build_skeleton(span, span, _adaptive_story_ht(span), 3; n_stories=1))
    prepare!(struc, base)
    row = _run_method(struc, base, FEA;
                      lx_ft=span, ly_ft=span, live_psf=ll, concrete_label="NWC_4000")
    isnothing(row) && (println("  $(span) ft / $(ll) psf: no result"); continue)
    println("  $(span) ft / $(ll) psf: h=$(row.h_in) in  governing=$(row.governing_check)  " *
            "Vu=$(row.Vu_kip) kip  Vu_fea=$(row.Vu_fea_kip) kip  ratio_fea=$(row.Vu_fea_ratio)")
end
