# Fixed-mesh accuracy + speed A/B (audit #1 / direction 7.8; plan-40b3c357).
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/ab_fixed_mesh_accuracy.jl [BUILDING] [max_iterations]
#
# BUILDING:
#   small   (default) 1-story 3x3-bay plate, 60x48 ft   — fast correctness + first drift signal
#   medium  3-story 8x5-bay office, 159x108 ft          — the production measurement
#
# Runs the SAME building twice:
#   remesh  production FEA (mesh conforms to each column; a column step remeshes)
#   fixed   FEA(fixed_mesh=true, fixed_mesh_cap=max_column_size)  — mesh once at
#           the cap, re-tag the fenced zone on each column step
#
# Reports, per floor: convergence status, max punching DCR, final slab thickness,
# final column sizes, and mesh build/update counts; plus the drift of the fixed
# mesh vs the remesh and the wall-clock of each. The approved acceptance band
# (plan-40b3c357) is punching DCR +/-2%, face moments +/-3%, governing design
# (column sizes + slab thickness) unchanged, with a remesh fallback past the
# fenced zone. NO production default is flipped here — this only measures.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Logging
using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const BUILDING = isempty(ARGS) ? "small" : ARGS[1]
const MAX_ITER = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
const MAX_COL  = 30.0u"inch"   # DesignParameters / FlatPlateOptions default cap
BUILDING in ("small", "medium") || error("unknown building $BUILDING")

_gen() = BUILDING == "small" ?
    gen_medium_office(60.0u"ft", 48.0u"ft", 12.0u"ft", 3, 3, 1) :
    gen_medium_office(159.0u"ft", 108.0u"ft", 14.0u"ft", 8, 5, 3)

# Capture each floor's installability outcome. Defined ONCE (world-age safe):
# it writes into whatever dict `CAPTURE[]` currently points at, which
# `run_variant` swaps per variant.
const CAPTURE = Ref{Any}(Dict{Int, Any}())
@eval StructuralSynthesizer function _require_installable_floor(outcome, slab_idx::Int)
    $(CAPTURE)[][slab_idx] = outcome
    return outcome
end

# Trace `ev.data` may be keyed by Symbol or String; try both.
_d(ev, key) = get(ev.data, key, get(ev.data, string(key), nothing))

"""
Governing design read straight off the designed structure (not the trace):
per flat-plate slab, the final total thickness (in) and the sorted
supporting-column footprints (in). This is the robust "governing design
unchanged" acceptance signal — it reflects what was actually built.
"""
function design_readout(struc)
    h = Dict{Int, Float64}()
    cols = Dict{Int, Vector{Tuple{Float64, Float64}}}()
    for (si, slab) in enumerate(struc.slabs)
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        h[si] = round(ustrip(u"inch", StructuralSynthesizer.thickness(slab)); digits = 3)
        cs = Tuple{Float64, Float64}[]
        for col in StructuralSynthesizer._get_slab_columns(struc, slab)
            push!(cs, (round(ustrip(u"inch", col.c1); digits = 2),
                       round(ustrip(u"inch", col.c2); digits = 2)))
        end
        sort!(cs)
        cols[si] = cs
    end
    return (; h, cols)
end

"""Collect, per floor, the design outcome and the slab's punching trace."""
function run_variant(method, label)
    outcomes = Dict{Int, Any}()
    CAPTURE[] = outcomes

    params = DesignParameters(; name = "ab_fixed_mesh_$(label)", max_iterations = MAX_ITER,
                              skip_visualization = true,
                              materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
                              floor = FlatPlateOptions(method = method))
    struc = BuildingStructure(_gen())
    tc = StructuralSizer.TraceCollector()

    Asap._N_FACTORIZATIONS[] = 0
    Asap._MESH_RNG_CALLS[] = 0
    err = nothing
    design = nothing
    t = @elapsed begin
        try
            design = with_logger(NullLogger()) do
                # `restore=true` (default) runs through a DesignSession and does
                # NOT mutate the caller's `struc`; the designed structure is the
                # return value (`design.structure`). Capture it for the readout.
                design_building(struc, params; tc = tc)
            end
        catch e
            err = sprint(showerror, e)[1:min(end, 400)]
        end
    end
    designed = design === nothing ? struc : design.structure

    # Max punching DCR per floor, from the Phase-B slab trace. Takes the LAST
    # (converged) punching_ratios per floor as the as-designed DCR, and also
    # folds in any failing_ratios seen along the way (envelope).
    max_dcr = Dict{Int, Float64}()
    final_dcr = Dict{Int, Float64}()
    for ev in tc.events
        ev.stage == "size_flat_plate!" || continue
        _d(ev, :phase) == "B" || continue
        sid = ev.element_id
        m = match(r"slab_(\d+)", sid === nothing ? "" : String(sid))
        m === nothing && continue
        k = parse(Int, m.captures[1])
        pr = _d(ev, :punching_ratios)
        fr = _d(ev, :failing_ratios)
        if pr !== nothing && !isempty(pr)
            final_dcr[k] = maximum(pr)          # last write wins = as-designed
            max_dcr[k] = max(get(max_dcr, k, 0.0), maximum(pr))
        end
        if fr !== nothing && !isempty(fr)
            max_dcr[k] = max(get(max_dcr, k, 0.0), maximum(v for (_, v) in fr))
        end
    end

    return (; label, t, err, outcomes, max_dcr, final_dcr,
            factorizations = Asap._N_FACTORIZATIONS[],
            mesh_rng = Asap._MESH_RNG_CALLS[], struc = designed)
end

println("building = $BUILDING, max_iterations = $MAX_ITER, threads = $(Threads.nthreads())")
println("cap (fixed_mesh_cap) = $MAX_COL\n")

# Warm up the whole design pipeline once so the remesh-vs-fixed wall-clock is
# warm-vs-warm (the first design_building call pays 100s+ of compile).
run_variant(FEA(), "warmup")

A = run_variant(FEA(), "remesh")
B = run_variant(FEA(; fixed_mesh = true, fixed_mesh_cap = MAX_COL), "fixed")

for v in (A, B)
    @printf("[%-6s] elapsed %7.1f s   factorizations %4d   mesh_rng %6d%s\n",
            v.label, v.t, v.factorizations, v.mesh_rng,
            v.err === nothing ? "" : "   THREW: " * v.err)
end

floors = sort(collect(union(keys(A.outcomes), keys(B.outcomes))))
println("\nfloor | status remesh/fixed | as-designed DCR remesh/fixed | DCR drift")
for k in floors
    oa = get(A.outcomes, k, nothing)
    ob = get(B.outcomes, k, nothing)
    sa = oa === nothing ? "?" : string(oa.status)
    sb = ob === nothing ? "?" : string(ob.status)
    da = get(A.final_dcr, k, NaN)
    db = get(B.final_dcr, k, NaN)
    drift = (isnan(da) || isnan(db) || da == 0) ? NaN : 100 * (db - da) / da
    flag = (!isnan(drift) && abs(drift) > 2.0) ? "  <-- OUTSIDE +/-2%" : ""
    @printf("  %3d | %-22s %-22s | %7.4f / %7.4f | %+7.2f %%%s\n",
            k, sa, sb, da, db, drift, flag)
end

# Direct design-equivalence: final thickness + column sizes off each designed
# `struc`. This is the primary "governing design unchanged" sign-off check and
# does not depend on the Phase-B punching trace (which the discrete-optimizer
# evaluator buffers away from `tc`, hence the NaN DCR column above).
function report_design_equivalence(A, B)
    ra = design_readout(A.struc)
    rb = design_readout(B.struc)
    slabs = sort(collect(union(keys(ra.h), keys(rb.h))))
    println("\nslab | thickness in remesh/fixed | columns | sizes in " *
            "(remesh" * (isempty(slabs) ? "" : " -> fixed if differ") * ")")
    equiv = !isempty(slabs)
    for si in slabs
        ha = get(ra.h, si, NaN); hb = get(rb.h, si, NaN)
        ca = get(ra.cols, si, Tuple{Float64, Float64}[])
        cb = get(rb.cols, si, Tuple{Float64, Float64}[])
        hmatch = isapprox(ha, hb; atol = 1e-3)
        cmatch = ca == cb
        equiv &= hmatch & cmatch
        @printf("  %3d | %6.3f / %6.3f %-4s | %-3s | %s\n", si, ha, hb,
                hmatch ? "" : "DIFF", cmatch ? "yes" : "NO",
                cmatch ? string(ca) : string(ca) * " -> " * string(cb))
    end
    println(equiv ?
        "\nGOVERNING DESIGN UNCHANGED: identical slab thickness + column sizes " *
        "across both variants (PASS, plan-40b3c357)." :
        isempty(slabs) ?
        "\nNO FLAT-PLATE SLABS READ from designed structure (harness/readout bug, not a divergence)." :
        "\nGOVERNING DESIGN DIFFERS: investigate rows flagged DIFF/NO before sign-off.")
    return equiv
end

report_design_equivalence(A, B)

println("\nAcceptance band (plan-40b3c357): punching DCR +/-2 %, moments +/-3 %, " *
        "governing design unchanged.")
