# O4 carbon oversize probe (Part B, plan.md §Objectives O4) — Phase 1.
#
# For each benchmark: design the flat plate once, then measure — read-only,
# holding every column's own final demands fixed — TWO oversize gaps:
#
#   1. plan-area  (`flat_plate_column_oversize`)        : smallest footprint,
#   2. carbon     (`flat_plate_column_oversize_carbon`) : lowest embodied carbon.
#
# The question Phase 1 answers: is there carbon reducible *beyond* what plan-area
# minimization already captures? WP 2.5 made the column objective rebar-inclusive
# but was carbon-neutral on medium_office because `_fit` minimizes plan AREA, not
# carbon. If the carbon gap here is ~0 everywhere, a carbon-ordered `_fit` buys
# nothing and Phase 2 should stop. If it is material on some typology, that
# typology justifies the Phase 2 selection change.
#
# Read-only: never changes any sizing.
#
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#       julia --project=StructuralSynthesizer scripts/runners/column_oversize_carbon_probe.jl
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_SKIP_SOLVER_WARMUP"]   = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
using Unitful
using Statistics: median, quantile

"""One flat-plate benchmark: `(label, x_bays, y_bays, n_stories)`. Taller
buildings carry more axial on the lower stories, forcing higher reinforcement
ratios into small sections — where a larger low-ρ section can embody less carbon
than the installed small high-ρ one. Those are the cases most likely to show a
carbon gap that plan-area minimization misses."""
# Low-rise only: 3-story designs cleanly, but 6+-story sway frames throw
# `no finite k on Fig. R10.10.1.1` (a sway column with both ends effectively
# pinned → infinite effective-length factor; a pre-existing ACI-slenderness
# pipeline limitation, orthogonal to carbon). Vary bay count instead to vary
# interior-column axial (and hence reinforcement ratio), which is what drives any
# carbon-vs-area disagreement.
const CASES = [
    ("3x3 x3 stories", 3, 3, 3),
    ("4x4 x3 stories", 4, 4, 3),
    ("5x5 x3 stories", 5, 5, 3),
    ("4x4 x2 stories", 4, 4, 2),
]

function _design(xb, yb, ns)
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", xb, yb, ns)
    params = DesignParameters(
        name = "carbon-oversize-probe",
        floor = FlatPlateOptions(),
        materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
        columns = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60),
        max_iterations = 10,
        skip_visualization = true,
    )
    struc = BuildingStructure(skel)
    design_building(struc, params; restore = false)
    return struc, params
end

"""Aggregate + distribution summary for one probe result dict keyed as
`(installed, lightest)` carbon fields, returning a NamedTuple of stats."""
function _summarize_carbon(ov)
    idxs = sort(collect(keys(ov)))
    isempty(idxs) && return nothing
    fracs = Float64[ov[i].reducible for i in idxs]
    # Quantities are already in kgCO2e (Asap's unit module); strip the unit
    # without naming it so the runner needn't import Asap's `@u_str` registry.
    c_in = sum(ustrip(ov[i].carbon_installed) for i in idxs)
    c_lt = sum(ustrip(ov[i].carbon_lightest) for i in idxs)
    return (; n = length(idxs), fracs,
            c_in, c_lt,
            total = c_in > 0 ? (c_in - c_lt) / c_in : 0.0,
            idxs)
end

function _report(label, struc, params, rc_opts)
    println("\n", "="^72)
    println("=== $label ===")
    ov_area   = StructuralSynthesizer.flat_plate_column_oversize(struc, params, rc_opts)
    ov_carbon = StructuralSynthesizer.flat_plate_column_oversize_carbon(struc, params, rc_opts)
    println("columns assessed: area=$(length(ov_area))  carbon=$(length(ov_carbon))")

    cs = _summarize_carbon(ov_carbon)
    if cs === nothing
        println("No assessable columns (no stored punching demand).")
        return (; label, total_carbon_gap = 0.0, n = 0, differ = 0)
    end

    # Plan-area aggregate gap, for side-by-side context.
    ai = sort(collect(keys(ov_area)))
    area_in = sum(ov_area[i].area_installed for i in ai)
    area_lt = sum(ov_area[i].area_lightest for i in ai)
    area_gap = area_in > zero(area_in) ? Float64((area_in - area_lt) / area_in) : 0.0

    println("\nCARBON oversize (fraction of embodied carbon removable at final demands):")
    println("  median : ", round(100 * median(cs.fracs); digits = 1), "%")
    println("  mean   : ", round(100 * sum(cs.fracs) / cs.n; digits = 1), "%")
    println("  p90    : ", round(100 * quantile(cs.fracs, 0.9); digits = 1), "%")
    println("  max    : ", round(100 * maximum(cs.fracs); digits = 1), "%")
    println("  # already min-carbon : ", count(f -> f <= 1e-9, cs.fracs), " / ", cs.n)
    println("\nAggregate gaps across all columns:")
    println("  plan-area reducible : ", round(100 * area_gap; digits = 1), "%")
    println("  CARBON   reducible : ", round(100 * cs.total; digits = 1),
            "%   (", round(cs.c_in - cs.c_lt; digits = 0), " of ",
            round(cs.c_in; digits = 0), " kgCO2e)")

    # The key Part-B signal: columns where the min-CARBON section is NOT the
    # min-AREA section — i.e. a larger low-ρ section beats a smaller high-ρ one.
    differ = 0
    for i in cs.idxs
        haskey(ov_area, i) || continue
        lc = StructuralSizer.bounding_box(ov_carbon[i].lightest)
        la = StructuralSizer.bounding_box(ov_area[i].lightest)
        (lc.width ≈ la.width && lc.depth ≈ la.depth) || (differ += 1)
    end
    println("  columns where min-carbon ≠ min-area section : ", differ, " / ", cs.n,
            "  (the carbon-ordered-`_fit` lever)")

    # Worst carbon offenders.
    worst = sort(cs.idxs; by = i -> -ov_carbon[i].reducible)
    println("\nTop carbon-oversized columns:")
    for i in first(worst, min(6, length(worst)))
        r = ov_carbon[i]
        bi = StructuralSizer.bounding_box(r.installed)
        bl = StructuralSizer.bounding_box(r.lightest)
        f(x) = round(ustrip(u"inch", x); digits = 1)
        println("  col #$i (story $(r.story), $(r.source)): ",
                "$(f(bi.width))x$(f(bi.depth)) in  ->  $(f(bl.width))x$(f(bl.depth)) in   (",
                round(100 * r.reducible; digits = 0), "% less carbon)")
    end
    return (; label, total_carbon_gap = cs.total, n = cs.n, differ)
end

summary = NamedTuple[]
for (label, xb, yb, ns) in CASES
    try
        t0 = time()
        struc, params = _design(xb, yb, ns)
        @info "design done" label seconds = round(time() - t0; digits = 1)
        rc_opts = StructuralSynthesizer._flat_plate_column_opts(params)
        push!(summary, _report(label, struc, params, rc_opts))
    catch err
        # One benchmark that fails to design (e.g. the sway-pinned infinite-k
        # case on tall frames) must not sink the rest of the sweep.
        @error "case failed to design; skipping" label exception = (err, catch_backtrace())
    end
    flush(stdout)  # defeat pipe block-buffering so per-case results stream out
end

println("\n", "#"^72)
println("# PHASE 1 SUMMARY — reducible CARBON gap per benchmark")
println("#"^72)
for s in summary
    println(rpad(s.label, 18), " : ",
            lpad(string(round(100 * s.total_carbon_gap; digits = 1)), 6), "%  carbon reducible  |  ",
            s.differ, "/", s.n, " columns min-carbon≠min-area")
end
maxgap = isempty(summary) ? 0.0 : maximum(s.total_carbon_gap for s in summary)
println("\nGATE: max reducible carbon across benchmarks = ",
        round(100 * maxgap; digits = 1), "%")
println(maxgap < 0.01 ?
        "  -> ~0 everywhere: carbon-ordered `_fit` buys nothing. STOP (report only)." :
        "  -> material on at least one typology: Phase 2 (carbon-ordered `_fit`) is justified.")
