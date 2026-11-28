# =============================================================================
# Runner: canonical slab-thickness sweep (E1)
# =============================================================================
#
# Triangular half-grid of rectangular bays, 16–52 ft, flat plate and flat
# slab, live loads 50/100/150/250 psf, six core methods, two thickness
# regimes. The reported slab is the intermediate story of a 3-story model.
# RuleOfThumb runs only at the ACI table minimum.
#
#   julia --project=StructuralStudies scripts/runners/run_slab_thickness_e1.jl
#   julia --project=StructuralStudies scripts/runners/run_slab_thickness_e1.jl smoke
#   julia --project=StructuralStudies scripts/runners/run_slab_thickness_e1.jl reduced
#
# `smoke` is one 20 ft square bay, NWC_4000, 150 psf, both regimes, DDM and
# FEA frame. It also repeats the computed-deflection DDM case from a 3 in
# seed. The two seeds must give the same thickness.
#
# `reduced` is the triangular half-grid of 20 ft and 28 ft, flat plate,
# NWC_4000, 150 psf, the six core methods, both regimes. It is the runtime
# sample. It is not the full E1 grid.
# =============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

const E1_SPANS = collect(16.0:4.0:52.0)
const E1_LL    = [50.0, 100.0, 150.0, 250.0]
const E1_CONC  = ["NWC_4000", "NWC_6000", "LWC_4000"]
const E1_REGIMES = [
    ("table_minimum", nothing),
    ("computed_deflection", COMPUTED_DEFLECTION_SEED),
]

mode = length(ARGS) > 0 ? lowercase(ARGS[1]) : "full"

if mode == "smoke"
    methods = [
        (key=:ddm, name="DDM (Full)",  method=SR.DDM(:full)),
        (key=:fea, name="FEA (frame)", method=SR.FEA(; pattern_loading=true,
                                                       pattern_mode=:efm_amp,
                                                       design_approach=:frame)),
    ]
    println("\n=== E1 SMOKE (20 ft, 3 stories, NWC_4000, 150 psf) ===\n")
    local base = _make_params(; concrete_label = "NWC_4000", max_col_in = _resolve_max_col(20.0))
    local struc = BuildingStructure(_build_skeleton(20.0, 20.0, _adaptive_story_ht(20.0), 3; n_stories=3))
    prepare!(struc, base)
    rows = NamedTuple[]
    regimes = vcat(E1_REGIMES, [("computed_seed_3in", 3.0u"inch")])
    for (mh_label, mh_val) in regimes, mcfg in methods
        mh_label == "computed_seed_3in" && !(mcfg.method isa SR.DDM) && continue
        row = _run_method(struc, base, mcfg;
                          lx_ft = 20.0, ly_ft = 20.0, live_psf = 150.0,
                          concrete_label = "NWC_4000", min_h = mh_val)
        isnothing(row) && continue
        push!(rows, merge(row, (min_h_rule = mh_label,)))
        println("  $(mh_label) / $(mcfg.name): h=$(row.h_in) in  story=$(row.story) ($(row.story_role))  " *
                "governing=$(row.governing_check)  Vu=$(row.Vu_kip) kip  Vu_fea=$(row.Vu_fea_kip) kip  " *
                "pattern=$(row.pattern_loading)  mode=$(row.pattern_mode)")
    end
    df = DataFrame(rows)
    ddm = filter(r -> r.method == "DDM (Full)" &&
                      r.min_h_rule in ("computed_deflection", "computed_seed_3in"), df)
    if nrow(ddm) == 2 && ddm.h_in[1] != ddm.h_in[2]
        println("SEED CHECK FAILED: 2 in and 3 in seeds gave $(ddm.h_in) in")
    elseif nrow(ddm) == 2
        println("Seed check: DDM computed thickness is $(ddm.h_in[1]) in from both 2 in and 3 in seeds.")
    end
elseif mode == "reduced"
    spans = [20.0, 28.0]
    pairs = [(lx, ly) for lx in spans for ly in spans if ly <= lx]
    println("\n=== E1 REDUCED TRIANGLE $(pairs) ===\n")
    local rows = NamedTuple[]
    for (lx, ly) in pairs
        span = max(lx, ly)
        local base = _make_params(; concrete_label = "NWC_4000",
                                   max_col_in = _resolve_max_col(span))
        local struc = BuildingStructure(_build_skeleton(lx, ly, _adaptive_story_ht(span), 3; n_stories=3))
        prepare!(struc, base)
        for (mh_label, mh_val) in E1_REGIMES, mcfg in CORE_METHODS
            mcfg.method isa SR.RuleOfThumb && !isnothing(mh_val) && continue
            row = _run_method(struc, base, mcfg;
                              lx_ft = lx, ly_ft = ly, live_psf = 150.0,
                              concrete_label = "NWC_4000", min_h = mh_val)
            isnothing(row) && continue
            push!(rows, merge(row, (min_h_rule = mh_label,)))
            println("  $(lx)×$(ly) $(mh_label) / $(mcfg.name): h=$(row.h_in) in  " *
                    "story=$(row.story) ($(row.story_role))  governing=$(row.governing_check)")
        end
    end
    println("Reduced rows: $(length(rows))")
else
    println("\n=== E1 CANONICAL GRID ===\n")
    df = dual_heatmap_sweep(;
        spans_x        = E1_SPANS,
        spans_y        = E1_SPANS,
        live_loads     = E1_LL,
        concretes      = E1_CONC,
        methods        = CORE_METHODS,
        n_bays         = 3,
        n_stories      = 3,
        half_grid      = true,
        sdl            = 20.0,
        min_h_variants = E1_REGIMES,
    )
    println("\n--- ECC bootstrap on the sized rows ---")
    sweep_ecc(df; n_samples = 2000)
end
