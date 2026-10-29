# =============================================================================
# Runner: time one Section 3 building so the full E2 grid can be estimated
# =============================================================================
#
# One 28 ft bay, 8×5 bays, 3 stories, NWC_4000. Runs DDM, then FEA frame.
#
#   julia --project=StructuralStudies scripts/runners/time_building_sweep.jl
#
# The full grid is 3 spans × 3 methods × 3 concretes × 3 heights × 2 thickness
# regimes. RuleOfThumb runs only in the table-minimum regime, so that method
# is not doubled. This timer is one table-minimum design per method. Scale
# the 3-story FEA time by (3+6+10)/3 = 6.33, then by 2 for the computed-
# deflection regime. DDM scales the same way. ACI Min stays at one regime.
# =============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "building_scale_analysis.jl"))

const SPAN = 28.0
const N    = 3

methods = [
    (key=:ddm, name="DDM (Full)",  method=SR.DDM(:full)),
    (key=:fea, name="FEA (frame)", method=SR.FEA(; pattern_loading=true,
                                                   pattern_mode=:efm_amp,
                                                   design_approach=:frame)),
]

println("\n=== E2 TIMING: $(SPAN) ft, $(N) stories, NWC_4000, 8×5 bays ===\n")

for mcfg in methods
    t0 = time()
    struc = BuildingStructure(_section3_skeleton(SPAN, N))
    params = _section3_params(mcfg.method, "NWC_4000"; max_col_in = _resolve_max_col(SPAN))
    design = with_logger(NullLogger()) do
        design_building(struc, params)
    end
    elapsed = time() - t0
    row = _building_row(design, SPAN, mcfg.name, "NWC_4000", N, elapsed)
    @printf("  %-12s  %6.1f s   mean h %5.2f in   typical story %d h %5.2f in   roof h %5.2f in\n",
            mcfg.name, elapsed, row.slab_h_mean_in, row.typ_story, row.typ_h_in, row.roof_h_in)
end

println()
println("Full FEA share ≈ 27 table-minimum runs × (3+6+10)/3 × 2 regimes × (this FEA time)")
println("DDM scales the same way. ACI Min is table-minimum only.")
