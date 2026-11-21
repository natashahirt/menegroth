# Equivalence harness for #20 (resolve _rc_section_check against the full-catalog
# capacity cache instead of a single-section cache).
#
# Designs the SAME flat-plate building twice in one process:
#   1. baseline  — SS_DISABLE_COL_CATALOG_SLOT set, so _rc_section_check always
#                  builds a one-section cache (old behavior).
#   2. optimized — the ENV unset, so a catalog section whose full-catalog cache
#                  the sizing stage already built is checked by indexing into it
#                  (the #20 optimization, now the default).
#
# The P-M diagram at the catalog index is the SAME object the one-section cache
# would rebuild, so the two designs must be byte-for-byte identical in every
# sized quantity. Any difference fails the harness.
#
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#       julia --project=StructuralSynthesizer scripts/runners/equiv_col_catalog_slot.jl
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_SKIP_SOLVER_WARMUP"]   = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
const _SR = StructuralSizer
using Unitful

"""Build a fresh, undesigned structure + params. A multi-story DDM flat plate so
the column checks (member and §10.12 joint) run over several settle rounds, the
path the #20 catalog-slot reuse touches."""
function _fresh_case()
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 3)
    params = DesignParameters(
        name = "equiv-col-catalog-slot",
        floor = FlatPlateOptions(),
        materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
        columns = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60),
        max_iterations = 10,
        skip_visualization = true,
    )
    return BuildingStructure(skel), params
end

"""A comparable fingerprint of every sized quantity, keyed so the two runs line
up regardless of iteration order."""
function _fingerprint(design)
    cols = Dict{Int, NTuple{6, Float64}}()
    for (i, r) in design.columns
        pun = r.punching === nothing ? NaN : r.punching.ratio
        cols[i] = (ustrip(u"inch", r.c1), ustrip(u"inch", r.c2), r.rho_g,
                   r.axial_ratio, r.interaction_ratio, pun)
    end
    slabs = Dict{Int, Float64}()
    for (i, sr) in design.slabs
        slabs[i] = ustrip(u"inch", sr.thickness)
    end
    return (columns = cols, slabs = slabs)
end

function _run(label)
    struc, params = _fresh_case()
    t0 = time()
    design = design_building(struc, params; restore = false)
    @info "$label design_building done" seconds = round(time() - t0; digits = 1)
    return _fingerprint(design)
end

# 1) Baseline: force the one-section-cache path.
ENV["SS_DISABLE_COL_CATALOG_SLOT"] = "1"
baseline = _run("baseline (catalog slot OFF)")

# 2) Optimized: default path with the #20 catalog-slot reuse enabled.
delete!(ENV, "SS_DISABLE_COL_CATALOG_SLOT")
optimized = _run("optimized (catalog slot ON)")

# Compare.
diffs = String[]
baseline.columns == optimized.columns || begin
    allk = union(keys(baseline.columns), keys(optimized.columns))
    for k in sort(collect(allk))
        b = get(baseline.columns, k, nothing)
        o = get(optimized.columns, k, nothing)
        isequal(b, o) || push!(diffs, "column #$k: baseline=$b optimized=$o")
    end
end
baseline.slabs == optimized.slabs || begin
    allk = union(keys(baseline.slabs), keys(optimized.slabs))
    for k in sort(collect(allk))
        b = get(baseline.slabs, k, nothing)
        o = get(optimized.slabs, k, nothing)
        isequal(b, o) || push!(diffs, "slab #$k: baseline=$b optimized=$o")
    end
end

println("\n=== #20 EQUIVALENCE HARNESS ===")
println("columns compared: ", length(baseline.columns), " / ", length(optimized.columns))
println("slabs compared:   ", length(baseline.slabs), " / ", length(optimized.slabs))
if isempty(diffs)
    println("RESULT: PASS — catalog slot ON and OFF produce byte-identical sizing.")
else
    println("RESULT: FAIL — ", length(diffs), " differences:")
    for d in diffs
        println("  ", d)
    end
    exit(1)
end
