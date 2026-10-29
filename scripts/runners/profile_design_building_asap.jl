# Profile `design_building` and report how much wall time is spent inside Asap.
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/profile_design_building_asap.jl [case ...]
#
# Cases: default, flat_ddm, flat_fea, steel. No arguments runs default and flat_ddm.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Profile, Logging
using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const ASAP_SRC = normpath(joinpath(@__DIR__, "..", "..", "external", "Asap", "src"))

function make_params(case::String; viz::Bool)
    base = (; name = case, max_iterations = 3, skip_visualization = !viz,
              materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60))
    case == "default"  && return DesignParameters(; base...)
    case == "flat_ddm" && return DesignParameters(; base..., floor = FlatPlateOptions(method = DDM()))
    case == "flat_fea" && return DesignParameters(; base..., floor = FlatPlateOptions(method = FEA()))
    case == "steel"    && return DesignParameters(; base..., beams = SteelBeamOptions(),
                                                   columns = SteelColumnOptions())
    error("unknown case $case")
end

make_struc() = BuildingStructure(gen_medium_office(159.0u"ft", 108.0u"ft", 14.0u"ft", 8, 5, 3))

_pkg(f) = occursin("Asap/src", f) ? :asap :
          occursin("StructuralSizer/src", f) ? :sizer :
          occursin("StructuralSynthesizer/src", f) ? :synth : :other

"""
Inclusive sample counts per package function over busy samples (those whose
backtrace passes through `design_building`). Returns
`(busy, in_asap, asap_rows, pkg_rows)`.
"""
function asap_breakdown()
    data, lidict = Profile.retrieve()
    asap = Dict{String, Int}(); pkg = Dict{String, Int}()
    busy = 0; in_asap = 0
    seen_a = Set{String}(); seen_p = Set{String}()
    i = 1
    while i <= length(data)
        empty!(seen_a); empty!(seen_p); is_busy = false
        while i <= length(data) && data[i] != 0
            for fr in get(lidict, data[i], ())
                f = string(fr.file)
                fr.func === :design_building && (is_busy = true)
                p = _pkg(f)
                p === :other && continue
                key = string(fr.func, " @ ", basename(f), ":", fr.line)
                p === :asap ? push!(seen_a, string(fr.func, " @ ", basename(f))) : push!(seen_p, key)
            end
            i += 1
        end
        # Each backtrace is terminated by a run of zeros (thread/task metadata).
        while i <= length(data) && data[i] == 0
            i += 1
        end
        is_busy || continue
        busy += 1
        isempty(seen_a) || (in_asap += 1)
        for k in seen_a; asap[k] = get(asap, k, 0) + 1; end
        for k in seen_p; pkg[k] = get(pkg, k, 0) + 1; end
    end
    srt(d) = sort(collect(d); by = x -> -x[2])
    return busy, in_asap, srt(asap), srt(pkg)
end

function run_case(case::String; viz::Bool = false)
    println("\n", "="^72, "\n  case = $case  (visualization model = $viz, threads = $(Threads.nthreads()))\n", "="^72)
    params = make_params(case; viz)
    t_first = @elapsed with_logger(NullLogger()) do
        design_building(make_struc(), params)           # compile warm-up
    end
    @printf("  first (cold) call: %.2f s\n", t_first)
    Asap._MESH_RNG_CALLS[] = 0
    Asap._N_FACTORIZATIONS[] = 0
    StructuralSizer._DISCRETE_MEMO_HITS[] = 0
    StructuralSizer._RC_NLP_MEMO_HITS[] = 0
    GC.gc()
    struc = make_struc()
    Profile.clear()
    Profile.init(n = 10^8, delay = 0.005)
    local design
    t = @elapsed with_logger(NullLogger()) do
        design = @profile design_building(struc, params)
    end
    @printf("  wall time: %.2f s\n", t)
    for (k, v) in sort(collect(design.phase_timings); by = x -> -x[2])
        @printf("    %-18s %8.3f s\n", k, v)
    end
    println("  floor = ", typeof(params.floor), ", beams = ", typeof(params.beams),
            ", columns = ", typeof(params.columns))
    @printf("  counters: mesh rng calls %d, factorizations %d, discrete memo hits %d, rc nlp memo hits %d\n",
            Asap._MESH_RNG_CALLS[], Asap._N_FACTORIZATIONS[],
            StructuralSizer._DISCRETE_MEMO_HITS[], StructuralSizer._RC_NLP_MEMO_HITS[])
    total, in_asap, rows, prow = asap_breakdown()
    @printf("  busy samples: %d, inside Asap: %d (%.1f%%)\n", total, in_asap, 100 * in_asap / max(total, 1))
    println("  top Asap functions (inclusive % of busy samples):")
    for (k, v) in first(rows, 10)
        @printf("    %6.1f%%  %s\n", 100 * v / total, k)
    end
    println("  top StructuralSizer/Synthesizer frames (inclusive % of busy samples):")
    for (k, v) in first(prow, 45)
        @printf("    %6.1f%%  %s\n", 100 * v / total, k)
    end
end

cases = isempty(ARGS) ? ["default", "flat_ddm"] : ARGS
for c in cases
    try
        run_case(c)
    catch e
        @error "case $c failed" exception = (e, catch_backtrace())
    end
end
