# ==============================================================================
# Section 3 — Whole-Building EC Cascade from Slab Thickness
# ==============================================================================
#
# Quantifies the *system-level* embodied-carbon savings that follow when an
# explicit slab analysis (DDM / FEA) lets the slab go below the ACI 8.3.1.1
# prescriptive minimum thickness.  Sections 1 and 2 report slab-only EC; this
# study runs the **full design pipeline** (slabs → columns → foundations) on a
# multi-story medium office and sums per-system EC out of
# `BuildingDesign.summary` to expose the cascade:
#
#       thinner slab  →  lower self-weight
#                     →  lighter column demand   → smaller columns (less EC)
#                     →  lower foundation loads  → smaller footings (less EC)
#
# `BuildingDesign.summary.embodied_carbon_*` fields are frozen by
# `compute_building_ec(struc, params)` inside `capture_design`, *before*
# `design_building` calls `restore!` — see
# `StructuralSynthesizer/src/design_workflow.jl §_compute_design_summary!`.
#
# Axes (paper defaults):
#   span (ft)  ×  method  ×  slab concrete  ×  n_stories
#
# Columns (NWC_6000, MIP catalog) and foundations (spread on medium sand,
# NWC_4000) are held constant across runs so the slab is the only structural
# variable in the cascade.
#
# Usage (from Julia REPL at project root):
#
#   include("StructuralStudies/src/flat_plate_methods/building_scale_analysis.jl")
#   df = sweep_building()                       # full default grid (3×3×3×3 = 81)
#   df = sweep_building(stories=[6])            # single-height variant
#   df = sweep_building_quick()                 # 2×2×1×1 smoke test
#
# ==============================================================================

include(joinpath(@__DIR__, "flat_plate_method_comparison.jl"))

using Statistics: mean

@isdefined(SECTION3_RESULTS_DIR) ||
    (const SECTION3_RESULTS_DIR = joinpath(@__DIR__, "results"))

# ==============================================================================
# Sweep axes (paper defaults)
# ==============================================================================

"""Square-bay column spans (ft); each level scales the medium-office footprint
to `SECTION3_X_BAYS × span` × `SECTION3_Y_BAYS × span`."""
const SECTION3_SPANS = [16.0, 22.0, 28.0]

"""Three analysis methods spanning the ladder from prescriptive thickness
(`RuleOfThumb` ≡ ACI 8.3.1.1) through prescriptive moments (`DDM(:full)`
≡ ACI 318-11 §13.6) to explicit analysis (`FEA(:frame)` — 2D shell + ACI 318-11 §13.6.4/.6
strip fractions)."""
const SECTION3_METHODS = [
    (key=:rot, name="ACI Min",     method=SR.RuleOfThumb()),
    (key=:ddm, name="DDM (Full)",  method=SR.DDM(:full)),
    (key=:fea, name="FEA (frame)", method=SR.FEA(; pattern_loading=false, design_approach=:frame)),
]

"""Slab concretes — baseline NWC, higher-strength NWC, and sand-LWC. Same set
whose ECC distribution is bootstrapped in Section 2's `sweep_ecc`."""
const SECTION3_CONCRETES = ["NWC_4000", "NWC_6000", "LWC_4000"]

"""Number of stories — low, typical, and tall mid-rise so the cascade can
be read as a function of building height."""
const SECTION3_STORIES = [3, 6, 10]

# ==============================================================================
# Fixed geometry / loads
# ==============================================================================

const SECTION3_X_BAYS      = 8         # bays in long direction
const SECTION3_Y_BAYS      = 5         # bays in short direction
const SECTION3_STORY_HT_FT = 13.0      # typical office story height
const SECTION3_LL_PSF      = 50.0      # ASCE 7 Table 4.3-1 office
const SECTION3_SDL_PSF     = 20.0      # matches Sections 1 / 2

# ==============================================================================
# Skeleton & DesignParameters
# ==============================================================================

"""
    _section3_skeleton(span_ft, n_stories) -> BuildingSkeleton

Medium-office skeleton sized so each bay equals `span_ft × span_ft`. Footprint
scales: `x = SECTION3_X_BAYS * span_ft`, `y = SECTION3_Y_BAYS * span_ft`.
"""
function _section3_skeleton(span_ft::Float64, n_stories::Int)
    total_x = span_ft * SECTION3_X_BAYS * u"ft"
    total_y = span_ft * SECTION3_Y_BAYS * u"ft"
    return gen_medium_office(total_x, total_y, SECTION3_STORY_HT_FT * u"ft",
                             SECTION3_X_BAYS, SECTION3_Y_BAYS, n_stories)
end

"""
    _section3_params(method, concrete_label; max_col_in, deflection_limit) -> DesignParameters

Build per-run `DesignParameters` for Section 3.  The slab method and slab
concrete are the only things that vary across runs; everything else is held
fixed so the EC cascade is isolated to slab feedback.

Column / foundation defaults (fixed across runs):
* Columns — `NWC_6000`, `:high_capacity` MIP catalog, `:per_story`
  uniform sizing (one column section per story — typical construction).
* Foundations — spread footings on medium sand, `NWC_4000`, `:all_spread`.
"""
function _section3_params(method::SR.FlatPlateAnalysisMethod,
                          concrete_label::AbstractString;
                          max_col_in::Float64,
                          deflection_limit::Symbol = :L_360)
    preset = _concrete_preset(concrete_label)
    floor = SR.FlatPlateOptions(
        method           = method,
        material         = preset.material,
        deflection_limit = deflection_limit,
        max_column_size  = max_col_in * u"inch",
        shear_studs      = :if_needed,
    )
    return DesignParameters(
        name = "section3_$(concrete_label)_$(replace(string(typeof(method).name.name), "Type" => ""))",
        loads = GravityLoads(
            floor_LL  = SECTION3_LL_PSF  * psf,
            roof_LL   = SECTION3_LL_PSF  * psf,
            floor_SDL = SECTION3_SDL_PSF * psf,
            roof_SDL  = SECTION3_SDL_PSF * psf,
        ),
        materials = MaterialOptions(concrete = preset.concrete, rebar = SR.Rebar_60),
        columns   = SR.ConcreteColumnOptions(
            material        = SR.NWC_6000,
            catalog         = :high_capacity,
            sizing_strategy = :catalog,
        ),
        floor = floor,
        foundation_options = FoundationParameters(
            soil            = SR.medium_sand,
            options         = SR.FoundationOptions(strategy = :all_spread),
            concrete        = SR.NWC_4000,
            rebar           = SR.Rebar_60,
            pier_width      = 0.35u"m",
            min_depth       = 0.4u"m",
            group_tolerance = 0.15,
        ),
        uniform_column_sizing = :per_story,
        deflection_limit      = deflection_limit,
        max_iterations        = 150,
        skip_visualization    = true,
    )
end

# ==============================================================================
# Result extraction
# ==============================================================================

"""
    _building_row(design, span_ft, method_name, concrete_label, n_stories, elapsed)

Pack the per-building EC + sizing summary into a flat NamedTuple. All EC
fields come from `design.summary.embodied_carbon_*` (frozen kgCO₂e at
`capture_design` time). Geometry / size fingerprints come from `design.slabs`,
`design.columns`, `design.foundations` (preserved across `restore!` because
the BuildingDesign holds them by value).
"""
function _building_row(design, span_ft::Float64, method_name::String,
                       concrete_label::AbstractString, n_stories::Int,
                       elapsed::Float64)
    summary = design.summary
    struc   = design.structure

    floor_area_m2 = ustrip(u"m^2",
        sum(c.area for c in struc.cells; init = 0.0u"m^2"))

    slab_h_in = if isempty(design.slabs)
        NaN
    else
        ustrip(u"inch", mean(s.thickness for s in values(design.slabs)))
    end

    col_dims_in = Float64[]
    for c in values(design.columns)
        hasproperty(c, :c1) && c.c1 > 0.0u"m" && push!(col_dims_in, ustrip(u"inch", c.c1))
    end
    col_min_in = isempty(col_dims_in) ? NaN : minimum(col_dims_in)
    col_max_in = isempty(col_dims_in) ? NaN : maximum(col_dims_in)
    col_avg_in = isempty(col_dims_in) ? NaN : mean(col_dims_in)

    fdn_B_max_ft = 0.0
    fdn_n_sized  = 0
    for f in values(design.foundations)
        if hasproperty(f, :width) && f.width > 0.0u"m"
            fdn_n_sized += 1
            B = ustrip(u"ft", f.width)
            B > fdn_B_max_ft && (fdn_B_max_ft = B)
        end
    end

    # `DesignSummary.embodied_carbon_*` are typed `kgCO₂e` quantities since
    # T2.3 — this NamedTuple is the DataFrame / CSV boundary for the
    # building-scale analysis, so strip to bare Float64 once here.
    ec_total_kg        = ustrip(u"kgCO2e", summary.embodied_carbon)
    ec_slabs_kg        = ustrip(u"kgCO2e", summary.embodied_carbon_slabs)
    ec_columns_kg      = ustrip(u"kgCO2e", summary.embodied_carbon_columns)
    ec_beams_kg        = ustrip(u"kgCO2e", summary.embodied_carbon_beams)
    ec_foundations_kg  = ustrip(u"kgCO2e", summary.embodied_carbon_foundations)
    ec_fireproofing_kg = ustrip(u"kgCO2e", summary.embodied_carbon_fireproofing)
    intensity = floor_area_m2 > 0.0 ? ec_total_kg / floor_area_m2 : NaN

    return (
        span_ft         = span_ft,
        n_stories       = n_stories,
        concrete        = String(concrete_label),
        method          = method_name,
        floor_area_m2   = floor_area_m2,
        # Sizing fingerprints
        slab_h_in       = slab_h_in,
        col_min_in      = col_min_in,
        col_max_in      = col_max_in,
        col_avg_in      = col_avg_in,
        fdn_n_sized     = fdn_n_sized,
        fdn_B_max_ft    = fdn_B_max_ft == 0.0 ? NaN : fdn_B_max_ft,
        # Per-system EC (kgCO₂e)
        slab_ec         = ec_slabs_kg,
        column_ec       = ec_columns_kg,
        beam_ec         = ec_beams_kg,
        foundation_ec   = ec_foundations_kg,
        fireproofing_ec = ec_fireproofing_kg,
        total_ec        = ec_total_kg,
        intensity_kgco2e_per_m2 = intensity,
        # Material totals
        concrete_vol_m3 = ustrip(u"m^3", summary.concrete_volume),
        rebar_kg        = ustrip(u"kg",  summary.rebar_weight),
        steel_kg        = ustrip(u"kg",  summary.steel_weight),
        # Checks
        all_ok           = summary.all_checks_pass,
        critical_ratio   = summary.critical_ratio,
        critical_element = String(summary.critical_element),
        # Bookkeeping
        runtime_s        = round(elapsed; digits = 2),
        converged        = true,
        failure_reason   = "",
    )
end

"""Failure-row stub with the same schema as `_building_row` so success and
failure rows can coexist in the same DataFrame."""
function _blank_building_row(span_ft::Float64, method_name::String,
                             concrete_label::AbstractString, n_stories::Int,
                             elapsed::Float64, reason::String)
    return (
        span_ft         = span_ft,
        n_stories       = n_stories,
        concrete        = String(concrete_label),
        method          = method_name,
        floor_area_m2   = NaN,
        slab_h_in       = NaN,
        col_min_in      = NaN,
        col_max_in      = NaN,
        col_avg_in      = NaN,
        fdn_n_sized     = 0,
        fdn_B_max_ft    = NaN,
        slab_ec         = NaN,
        column_ec       = NaN,
        beam_ec         = NaN,
        foundation_ec   = NaN,
        fireproofing_ec = NaN,
        total_ec        = NaN,
        intensity_kgco2e_per_m2 = NaN,
        concrete_vol_m3 = NaN,
        rebar_kg        = NaN,
        steel_kg        = NaN,
        all_ok          = false,
        critical_ratio  = NaN,
        critical_element = "",
        runtime_s       = round(elapsed; digits = 2),
        converged       = false,
        failure_reason  = reason,
    )
end

# ==============================================================================
# Main sweep
# ==============================================================================

"""
    sweep_building(; spans, methods, concretes, stories, save) -> DataFrame

Run the full design pipeline (slabs → columns → foundations) for every
`(span × method × concrete × n_stories)` combination on a multi-story
medium office and return a flat DataFrame of per-building EC summaries
plus sizing fingerprints.

# Defaults
* `spans`    — `SECTION3_SPANS` (16, 22, 28 ft)
* `methods`  — `SECTION3_METHODS` (ACI Min, DDM, FEA)
* `concretes`— `SECTION3_CONCRETES` (NWC_4000, NWC_6000, LWC_4000)
* `stories`  — `SECTION3_STORIES` ([3, 6, 10])

# Output
On `save = true`, a timestamped CSV is written to
`SECTION3_RESULTS_DIR` (`section3_building_sweep_<...>.csv`). A separate
failures CSV is also written when any runs fail.

# Notes
The structure is rebuilt from the skeleton for every run rather than
snapshot/restored. Changing the slab concrete alters the initial
column-load estimates (because slab self-weight changes), so a fresh
`prepare!` is the safer path — and the multi-story design dominates the
per-run cost anyway.
"""
function sweep_building(;
    spans::Vector{Float64}   = SECTION3_SPANS,
    methods                  = SECTION3_METHODS,
    concretes::Vector{String}= SECTION3_CONCRETES,
    stories::Vector{Int}     = SECTION3_STORIES,
    save::Bool               = true,
)
    foreach(_concrete_preset, concretes)  # validate up-front

    n_total = length(spans) * length(methods) * length(concretes) * length(stories)

    print_header("Section 3 — Whole-Building EC Cascade")
    println("  Spans:      $(spans) ft  (bay = span × span)")
    println("  Methods:    $([m.name for m in methods])")
    println("  Concretes:  $(concretes)")
    println("  Stories:    $(stories)")
    println("  Geometry:   $(SECTION3_X_BAYS)×$(SECTION3_Y_BAYS) bays, " *
            "$(SECTION3_STORY_HT_FT) ft story, LL = $(SECTION3_LL_PSF) psf, " *
            "SDL = $(SECTION3_SDL_PSF) psf")
    println("  Columns:    NWC_6000 high-capacity catalog, :per_story uniform")
    println("  Foundations: spread on medium sand, NWC_4000")
    println("  Total runs: $n_total")
    println()

    rows = NamedTuple[]
    fail = NamedTuple[]
    p    = Progress(n_total; desc = "Section 3: ")

    for span in spans, n_stories in stories
        max_col = _adaptive_max_col(span)
        for concrete_label in concretes, mcfg in methods
            t0 = time()
            try
                struc  = BuildingStructure(_section3_skeleton(span, n_stories))
                params = _section3_params(mcfg.method, concrete_label;
                                          max_col_in = max_col)
                design = with_logger(NullLogger()) do
                    design_building(struc, params)
                end
                elapsed = time() - t0
                push!(rows, _building_row(design, span, mcfg.name,
                                          concrete_label, n_stories, elapsed))
            catch e
                elapsed = time() - t0
                reason  = sprint(showerror, e)
                @warn "Section 3 run failed" span n_stories method=mcfg.name concrete=concrete_label err=reason
                push!(fail, _blank_building_row(span, mcfg.name,
                                                concrete_label, n_stories,
                                                elapsed, reason))
            end
            next!(p)
        end
    end

    df      = isempty(rows) ? DataFrame() : DataFrame(rows)
    df_fail = isempty(fail) ? DataFrame() : DataFrame(fail)

    outfile = nothing
    if save && !isempty(df)
        outfile = output_filename("section3_building_sweep", SECTION3_RESULTS_DIR)
        CSV.write(outfile, df)
    end
    if save && !isempty(df_fail)
        ffile = output_filename("section3_building_sweep_failures", SECTION3_RESULTS_DIR)
        CSV.write(ffile, df_fail)
        println("  Failures:    $ffile")
    end

    print_footer(nrow(df), nrow(df_fail), outfile)
    return df
end

"""Tiny smoke-test variant: 2 spans × 2 methods × 1 concrete × 1 story
height = 4 runs. Useful for validating wiring without paying the full
~hour-long sweep cost."""
function sweep_building_quick(; save::Bool = true)
    sweep_building(;
        spans     = [20.0, 28.0],
        methods   = [
            (key=:rot, name="ACI Min",     method=SR.RuleOfThumb()),
            (key=:fea, name="FEA (frame)", method=SR.FEA(; pattern_loading=false, design_approach=:frame)),
        ],
        concretes = ["NWC_4000"],
        stories   = [3],
        save      = save,
    )
end

# ==============================================================================
# Cascade summary helpers
# ==============================================================================

"""
    cascade_table(df; baseline_method = "ACI Min") -> DataFrame

Compute per-system EC deltas vs `baseline_method` for each
`(span, n_stories, concrete)` cell. Adds columns:

* `Δslab_ec`, `Δcolumn_ec`, `Δfoundation_ec`, `Δtotal_ec` (absolute, kgCO₂e)
* `pct_slab_ec`, `pct_column_ec`, `pct_foundation_ec`, `pct_total_ec`
  (signed % change vs baseline, negative = savings)
* `pct_slab_h` — slab thickness change vs baseline (negative = thinner)

Only converged rows (`row.converged == true`) participate.
"""
function cascade_table(df::DataFrame; baseline_method::String = "ACI Min")
    isempty(df) && return DataFrame()

    work = filter(r -> r.converged === true, df)
    isempty(work) && return DataFrame()

    out = NamedTuple[]
    for sub in groupby(work, [:span_ft, :n_stories, :concrete])
        base_rows = filter(r -> r.method == baseline_method, sub)
        isempty(base_rows) && continue
        base = base_rows[1, :]
        for row in eachrow(sub)
            pct(x, b) = (isnan(x) || isnan(b) || b == 0.0) ? NaN : 100.0 * (x - b) / b
            push!(out, (
                span_ft        = row.span_ft,
                n_stories      = row.n_stories,
                concrete       = row.concrete,
                method         = row.method,
                slab_h_in      = row.slab_h_in,
                pct_slab_h     = pct(row.slab_h_in, base.slab_h_in),
                Δslab_ec       = row.slab_ec       - base.slab_ec,
                Δcolumn_ec     = row.column_ec     - base.column_ec,
                Δfoundation_ec = row.foundation_ec - base.foundation_ec,
                Δtotal_ec      = row.total_ec      - base.total_ec,
                pct_slab_ec       = pct(row.slab_ec,       base.slab_ec),
                pct_column_ec     = pct(row.column_ec,     base.column_ec),
                pct_foundation_ec = pct(row.foundation_ec, base.foundation_ec),
                pct_total_ec      = pct(row.total_ec,      base.total_ec),
            ))
        end
    end
    return DataFrame(out)
end
