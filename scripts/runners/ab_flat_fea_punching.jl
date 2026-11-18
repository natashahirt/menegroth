# Why do medium-office flat-plate FEA floors fail to converge on punching?
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/ab_flat_fea_punching.jl VARIANT [max_iterations]
#
# VARIANT:
#   current  the tree as it is: one mesh per design, columns grow on the old mesh
#   remesh   rebuild the shell mesh whenever the column sizes no longer match the
#            mesh key, so the column patches follow the grown columns
#
# Prints, per floor, every punching pass: the failing column ratios, and the
# column sizes the FEA analysis saw on each call.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Logging
using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const VARIANT = isempty(ARGS) ? "current" : ARGS[1]
const MAX_ITER = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 3
VARIANT in ("current", "remesh") || error("unknown variant $VARIANT")

const FEA_CALLS = Vector{NamedTuple}()

@eval StructuralSizer function _build_or_update_fea!(
        cache::FEAModelCache, struc::FlatPlateKernelState, slab, columns, h, Ecs, ν_concrete, qu, Lc;
        kwargs...)
    remeshed = false
    if $(VARIANT == "remesh") && cache.initialized
        key = fea_mesh_key(struc, slab, columns;
                           target_edge = get(kwargs, :target_edge, nothing),
                           drop_panel = get(kwargs, :drop_panel, nothing))
        if key != cache.mesh_key
            fresh = FEAModelCache()
            for f in fieldnames(FEAModelCache)
                f === :mesh_key || setfield!(cache, f, getfield(fresh, f))
            end
            cache.mesh_key = key
            remeshed = true
        end
    end
    push!($(FEA_CALLS), (
        slab = first(slab.cell_indices),
        h_in = ustrip(u"inch", h),
        c_in = [round(ustrip(u"inch", c.c1); digits = 1) for c in columns],
        rebuilt = !cache.initialized,
        remeshed = remeshed,
    ))
    return invoke(_build_or_update_fea!,
                  Tuple{FEAModelCache, Any, Any, Any, Any, Any, Any, Any, Any},
                  cache, struc, slab, columns, h, Ecs, ν_concrete, qu, Lc; kwargs...)
end

const OUTCOMES = Dict{Int, Any}()
@eval StructuralSynthesizer function _require_installable_floor(outcome, slab_idx::Int)
    $(OUTCOMES)[slab_idx] = outcome
    return outcome
end

params = DesignParameters(; name = "ab_flat_fea_punching_$VARIANT", max_iterations = MAX_ITER,
                          skip_visualization = true,
                          materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
                          floor = FlatPlateOptions(method = FEA()))
struc = BuildingStructure(gen_medium_office(159.0u"ft", 108.0u"ft", 14.0u"ft", 8, 5, 3))
tc = StructuralSizer.TraceCollector()

println("variant = $VARIANT, max_iterations = $MAX_ITER, threads = $(Threads.nthreads())")
t = @elapsed begin
    try
        with_logger(NullLogger()) do
            design_building(struc, params; tc = tc)
        end
    catch e
        println("design_building threw after the floors: ", sprint(showerror, e)[1:min(end, 400)])
    end
end
@printf("elapsed %.1f s, mesh rng calls %d, factorizations %d\n",
        t, Asap._MESH_RNG_CALLS[], Asap._N_FACTORIZATIONS[])

for k in sort(collect(keys(OUTCOMES)))
    o = OUTCOMES[k]
    msg = join((d.message for d in o.diagnostics), "; ")
    @printf("\nfloor %d: status %s, iterations %d, %s\n",
            k, o.status, o.iterations, isempty(msg) ? "ok" : msg)
    sid = "slab_$k"
    for ev in tc.events
        ev.stage == "size_flat_plate!" && ev.element_id == sid || continue
        get(ev.data, "phase", "") == "B" || continue
        if haskey(ev.data, "failing_ratios")
            r = sort(collect(ev.data["failing_ratios"]); by = x -> -x[2])
            println("  punching pass: ", length(r), " failing, worst ",
                    join(("$(c)=$(v)" for (c, v) in first(r, 6)), ", "))
        elseif haskey(ev.data, "punching_ratios")
            println("  punching ok, max ratio ", maximum(ev.data["punching_ratios"]))
        end
    end
end

println("\nFEA calls (slab = first cell index of the floor):")
for c in FEA_CALLS
    @printf("  slab %d  h %.2f in  %s%s  columns %s\n", c.slab, c.h_in,
            c.rebuilt ? "build" : "update", c.remeshed ? " (remeshed)" : "",
            join(unique(c.c_in), "/"))
end
