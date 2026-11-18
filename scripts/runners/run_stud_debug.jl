# ==============================================================================
# Debug: 1-story vs 3-story flat plate with moment distribution
# ==============================================================================
using Unitful
using Unitful: @u_str
using Logging

using StructuralSizer
using StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer

# Both bending directions. Circular columns match; rectangles do not.
_dist(struc, cols, opts, slab) = SR.column_moment_distribution_factors(
    struc, cols, opts; span_axis = SR._get_span_axis(slab))
_both(pred, dist) = all(pred, dist.primary) && all(pred, dist.secondary)

function run_case(; span_ft::Float64, n_bays::Int, n_stories::Int,
                    ll_psf::Float64, sdl_psf::Float64, label::String)
    story_ht = max(12.0, round(span_ft / 3.0))
    max_col  = clamp(round(span_ft * 1.1), 36.0, 72.0)

    println("═══════════════════════════════════════════════════════════════")
    println("  $label")
    println("  Span: $(span_ft) ft  │  Stories: $n_stories  │  LL: $(ll_psf) psf")
    println("  Story height: $(story_ht) ft  │  Max column: $(max_col) in")
    println("═══════════════════════════════════════════════════════════════")

    total = span_ft * n_bays * u"ft"
    ht    = story_ht * u"ft"
    skel  = gen_medium_office(total, total, ht, n_bays, n_bays, n_stories)

    fp = SR.FlatPlateOptions(
        method                 = SR.FEA(; pattern_loading = false),
        material               = SR.RC_4000_60,
        punching_strategy      = :reinforce_first,
        punching_reinforcement = :headed_studs_generic,
        max_column_size        = max_col * u"inch",
        stud_diameter          = 0.5u"inch",
    )

    params = SS.DesignParameters(
        loads = SS.GravityLoads(
            floor_LL  = ll_psf * SR.psf,
            roof_LL   = ll_psf * SR.psf,
            floor_SDL = sdl_psf * SR.psf,
            roof_SDL  = sdl_psf * SR.psf,
        ),
        materials = SS.MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60),
        columns   = SR.ConcreteColumnOptions(grade = SR.NWC_6000, catalog = :high_capacity),
        floor     = fp,
        max_iterations = 150,
        foundation_options = SS.FoundationParameters(
            soil            = SR.medium_sand,
            options         = SR.FoundationOptions(strategy = :all_spread),
            concrete        = SR.NWC_4000,
            rebar           = SR.Rebar_60,
            pier_width      = 0.35u"m",
            min_depth       = 0.4u"m",
            group_tolerance = 0.15,
        ),
    )

    struc = SS.BuildingStructure(skel)
    SS.prepare!(struc, params)

    ll = uconvert(u"kN/m^2", ll_psf * SR.psf)
    for cell in struc.cells
        cell.live_load = ll
    end
    SS.sync_asap!(struc)

    println("  Columns in structure: $(length(struc.columns))")

    # Show distribution factors for each slab
    vc = struc.skeleton.geometry.vertex_coords
    for slab in struc.slabs
        slab_cells = Set(slab.cell_indices)
        cols = SR.find_supporting_columns(struc, slab_cells)
        factors = _dist(struc, cols, params.columns, slab)
        stories = [c.story for c in cols]
        println("  Slab (story=$(first(stories))): $(length(cols)) cols, " *
                "dist_factors = $(round.(factors; digits=3))")
    end

    println("  Running pipeline...")

    t0 = time()
    try
        stages = SS.build_pipeline(params)
        for (i, stage) in enumerate(stages)
            print("    Stage $i... ")
            stage.fn(struc)
            stage.needs_sync && SS.sync_asap!(struc; params)
            println("done.")
        end
        elapsed = round(time() - t0; digits=1)
        println("  ✓ SUCCESS ($elapsed s)")
    catch e
        elapsed = round(time() - t0; digits=1)
        println()
        println("  ✗ FAILURE ($elapsed s): $(sprint(showerror, e))")
    end
    println()
end

# ── Case 1: Single-story, 36 ft span ──
run_case(span_ft=36.0, n_bays=3, n_stories=1,
         ll_psf=50.0, sdl_psf=20.0,
         label="Case 1: 1-story, 36 ft span, LL=50 psf")

# ── Case 2: Three-story, 36 ft span ──
run_case(span_ft=36.0, n_bays=3, n_stories=3,
         ll_psf=50.0, sdl_psf=20.0,
         label="Case 2: 3-story, 36 ft span, LL=50 psf")

# ── Case 3: Circular column distribution factor test ──
# Tests _col_flexural_stiffness with circular cross-sections.
# Uses a 2-story building with columns manually set to :circular.
println("═══════════════════════════════════════════════════════════════")
println("  Case 3: Circular column distribution factors (2-story)")
println("═══════════════════════════════════════════════════════════════")
let
    span_ft = 28.0
    n_bays = 3
    n_stories = 2
    story_ht = 12.0

    total = span_ft * n_bays * u"ft"
    ht    = story_ht * u"ft"
    skel  = gen_medium_office(total, total, ht, n_bays, n_bays, n_stories)

    fp = SR.FlatPlateOptions(
        method            = SR.FEA(; pattern_loading = false),
        material          = SR.RC_4000_60,
        punching_strategy = :reinforce_first,
        punching_reinforcement = :headed_studs_generic,
        max_column_size   = 48.0u"inch",
        stud_diameter     = 0.5u"inch",
    )
    col_opts = SR.ConcreteColumnOptions(
        grade = SR.NWC_6000,
        section_shape = :circular,
        catalog = :high_capacity,
    )
    params = SS.DesignParameters(
        loads = SS.GravityLoads(
            floor_LL  = 50.0SR.psf, roof_LL  = 50.0SR.psf,
            floor_SDL = 20.0SR.psf, roof_SDL = 20.0SR.psf,
        ),
        materials = SS.MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60),
        columns   = col_opts,
        floor     = fp,
        max_iterations = 150,
        foundation_options = SS.FoundationParameters(
            soil            = SR.medium_sand,
            options         = SR.FoundationOptions(strategy = :all_spread),
            concrete        = SR.NWC_4000,
            rebar           = SR.Rebar_60,
            pier_width      = 0.35u"m",
            min_depth       = 0.4u"m",
            group_tolerance = 0.15,
        ),
    )

    struc = SS.BuildingStructure(skel)
    SS.prepare!(struc, params)

    # Convert all columns to circular (D = max(c1, c2))
    for col in struc.columns
        if !isnothing(col.c1) && !isnothing(col.c2)
            D = max(col.c1, col.c2)
            col.c1 = D
            col.c2 = D
            col.shape = :circular
        end
    end
    SS.sync_asap!(struc)

    # Print distribution factors
    for slab in struc.slabs
        slab_cells = Set(slab.cell_indices)
        cols = SR.find_supporting_columns(struc, slab_cells)
        factors = _dist(struc, cols, col_opts, slab)
        stories = [c.story for c in cols]
        shapes  = [c.shape for c in cols]
        println("  Slab (story=$(first(stories))): $(length(cols)) cols, " *
                "shape=$(first(shapes)), " *
                "dist_factors = $(round.(factors; digits=3))")
    end

    # Verify: equal circular columns → factor ≈ 0.5 on story 1, 1.0 on story 2
    slab1_cells = Set(struc.slabs[1].cell_indices)
    cols1 = SR.find_supporting_columns(struc, slab1_cells)
    f1 = _dist(struc, cols1, col_opts, struc.slabs[1])
    slab2_cells = Set(struc.slabs[2].cell_indices)
    cols2 = SR.find_supporting_columns(struc, slab2_cells)
    f2 = _dist(struc, cols2, col_opts, struc.slabs[2])

    pass1 = _both(f -> 0.45 ≤ f ≤ 0.55, f1)
    pass2 = _both(f -> f ≈ 1.0, f2)
    println("  Story 1 factors ≈ 0.5: $(pass1 ? "✓ PASS" : "✗ FAIL")")
    println("  Story 2 factors = 1.0: $(pass2 ? "✓ PASS" : "✗ FAIL")")

    # Also test with unequal circular columns: make story-2 columns smaller
    for col in struc.columns
        if col.story == 2 && !isnothing(col.c1)
            D_small = col.c1 * 0.75  # 75% of story-1 diameter
            col.c1 = D_small
            col.c2 = D_small
        end
    end
    f1_unequal = _dist(struc, cols1, col_opts, struc.slabs[1])
    println("  Unequal (D_above = 0.75×D_below):")
    println("    Story 1 factors = $(round.(f1_unequal; digits=3))")
    # K ∝ D⁴/L → (0.75)⁴ = 0.3164, so factor_below = 1/(1+0.3164) ≈ 0.76
    pass3 = _both(f -> 0.70 ≤ f ≤ 0.82, f1_unequal)
    println("    Factors ≈ 0.76 (K_below dominates): $(pass3 ? "✓ PASS" : "✗ FAIL")")
    println()
end

# ── Case 4: Mixed-concrete distribution factor test ──
# Story 1 columns use NWC_6000 (higher Ec), story 2 columns use NWC_4000 (lower Ec).
# Equal geometry → factor ≠ 0.5 because Ec differs.
println("═══════════════════════════════════════════════════════════════")
println("  Case 4: Mixed-concrete distribution factors (2-story)")
println("═══════════════════════════════════════════════════════════════")
let
    span_ft = 28.0
    n_bays = 3
    n_stories = 2
    story_ht = 12.0

    total = span_ft * n_bays * u"ft"
    ht    = story_ht * u"ft"
    skel  = gen_medium_office(total, total, ht, n_bays, n_bays, n_stories)

    col_opts = SR.ConcreteColumnOptions(grade = SR.NWC_6000, catalog = :high_capacity)
    fp = SR.FlatPlateOptions(
        method            = SR.FEA(; pattern_loading = false),
        material          = SR.RC_4000_60,
        punching_strategy = :reinforce_first,
        punching_reinforcement = :headed_studs_generic,
        max_column_size   = 48.0u"inch",
        stud_diameter     = 0.5u"inch",
    )
    params = SS.DesignParameters(
        loads = SS.GravityLoads(
            floor_LL  = 50.0SR.psf, roof_LL  = 50.0SR.psf,
            floor_SDL = 20.0SR.psf, roof_SDL = 20.0SR.psf,
        ),
        materials = SS.MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60),
        columns   = col_opts,
        floor     = fp,
        max_iterations = 150,
        foundation_options = SS.FoundationParameters(
            soil            = SR.medium_sand,
            options         = SR.FoundationOptions(strategy = :all_spread),
            concrete        = SR.NWC_4000,
            rebar           = SR.Rebar_60,
            pier_width      = 0.35u"m",
            min_depth       = 0.4u"m",
            group_tolerance = 0.15,
        ),
    )

    struc = SS.BuildingStructure(skel)
    SS.prepare!(struc, params)
    SS.sync_asap!(struc)

    # Assign per-column concrete: story 1 → NWC_6000, story 2 → NWC_4000
    for col in struc.columns
        col.concrete = col.story == 1 ? SR.NWC_6000 : SR.NWC_4000
    end

    # Compute Ec values for reference
    Ec_6000 = ustrip(SR.ksi, SR.Ec(SR.NWC_6000.fc′, ustrip(SR.pcf, SR.NWC_6000.ρ)))
    Ec_4000 = ustrip(SR.ksi, SR.Ec(SR.NWC_4000.fc′, ustrip(SR.pcf, SR.NWC_4000.ρ)))
    println("  Ec(6000 psi) = $(round(Ec_6000; digits=0)) ksi")
    println("  Ec(4000 psi) = $(round(Ec_4000; digits=0)) ksi")

    # Equal geometry, different Ec → K_below/K_above = Ec_below/Ec_above
    # factor_below = Ec_6000 / (Ec_6000 + Ec_4000)
    expected = Ec_6000 / (Ec_6000 + Ec_4000)
    println("  Expected factor (story 1) = $(round(expected; digits=3))")

    for slab in struc.slabs
        slab_cells = Set(slab.cell_indices)
        cols = SR.find_supporting_columns(struc, slab_cells)
        factors = _dist(struc, cols, col_opts, slab)
        stories = [c.story for c in cols]
        concs   = [isnothing(c.concrete) ? "default" : "$(ustrip(u"psi", c.concrete.fc′)) psi"
                   for c in cols]
        println("  Slab (story=$(first(stories))): $(length(cols)) cols, " *
                "concrete=$(first(concs)), " *
                "dist_factors = $(round.(factors; digits=3))")
    end

    # Verify story 1 factors
    slab1_cells = Set(struc.slabs[1].cell_indices)
    cols1 = SR.find_supporting_columns(struc, slab1_cells)
    f1 = _dist(struc, cols1, col_opts, struc.slabs[1])
    pass1 = _both(f -> abs(f - expected) < 0.02, f1)
    println("  Story 1 factors ≈ $(round(expected; digits=3)): $(pass1 ? "✓ PASS" : "✗ FAIL")")

    # Story 2 (roof) → 1.0
    slab2_cells = Set(struc.slabs[2].cell_indices)
    cols2 = SR.find_supporting_columns(struc, slab2_cells)
    f2 = _dist(struc, cols2, col_opts, struc.slabs[2])
    pass2 = _both(f -> f ≈ 1.0, f2)
    println("  Story 2 factors = 1.0: $(pass2 ? "✓ PASS" : "✗ FAIL")")

    # Also test: without per-column concrete, should fall back to default (all 0.5)
    for col in struc.columns
        col.concrete = nothing
    end
    f1_default = _dist(struc, cols1, col_opts, struc.slabs[1])
    pass3 = _both(f -> 0.45 ≤ f ≤ 0.55, f1_default)
    println("  Fallback (no per-col concrete) → 0.5: $(pass3 ? "✓ PASS" : "✗ FAIL")")
    println()
end
