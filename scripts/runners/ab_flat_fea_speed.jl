# Isolate the medium-office flat-plate FEA failure against the speed changes.
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/ab_flat_fea_speed.jl VARIANT [max_iterations]
#
# VARIANT:
#   current          the tree as it is
#   no_restore_skip  never reuse the saved factored displacement; always re-solve
#   default_rng      shell mesher on Random.default_rng(), as before the seeded mesher
#
# Floors that are not installable are reported instead of thrown, so every
# floor's status, iteration count and failing check is printed.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Logging, Random
using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const VARIANT = isempty(ARGS) ? "current" : ARGS[1]
const MAX_ITER = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 3
VARIANT in ("current", "no_restore_skip", "default_rng") || error("unknown variant $VARIANT")

if VARIANT == "no_restore_skip"
    @eval StructuralSizer function _solve_dl_cases!(cache::FEAModelCache, qD::Pressure, qL::Pressure;
                                                   verbose::Bool = false,
                                                   U_qu::Union{Nothing, Vector{Float64}} = nothing)
        cache.element_data_D = _solve_load_case!(cache, qD; verbose=verbose)
        cache.U_D = copy(cache.model.u)
        cache.element_data_L = _solve_load_case!(cache, qL; verbose=verbose)
        qu_restore = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
        for load in cache.model.loads
            load isa Asap.AreaLoad && (load.pressure = uconvert(u"Pa", qu_restore))
        end
        Asap.update!(cache.model; loads_only=true)
        Asap.solve!(cache.model)
    end
elseif VARIANT == "default_rng"
    @eval Asap _mesh_rng() = $(Random.default_rng)()
end

const OUTCOMES = Dict{Int, Any}()
@eval StructuralSynthesizer function _require_installable_floor(outcome, slab_idx::Int)
    $(OUTCOMES)[slab_idx] = outcome
    return outcome
end

params = DesignParameters(; name = "ab_flat_fea_$VARIANT", max_iterations = MAX_ITER,
                          skip_visualization = true,
                          materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
                          floor = FlatPlateOptions(method = FEA()))
struc = BuildingStructure(gen_medium_office(159.0u"ft", 108.0u"ft", 14.0u"ft", 8, 5, 3))

println("variant = $VARIANT, max_iterations = $MAX_ITER, threads = $(Threads.nthreads())")
t = @elapsed begin
    try
        with_logger(NullLogger()) do
            design_building(struc, params)
        end
    catch e
        println("design_building threw after the floors: ", sprint(showerror, e)[1:min(end, 400)])
    end
end
@printf("elapsed %.1f s, mesh rng calls %d, factorizations %d\n",
        t, Asap._MESH_RNG_CALLS[], Asap._N_FACTORIZATIONS[])

for k in sort(collect(keys(OUTCOMES)))
    o = OUTCOMES[k]
    raw = o.details
    h = hasproperty(raw, :slab_result) && hasproperty(raw.slab_result, :thickness) ?
        uconvert(u"inch", raw.slab_result.thickness) : get(raw, :h, missing)
    msg = join((d.message for d in o.diagnostics), "; ")
    @printf("floor %d: status %s, iterations %d, h %s, %s\n",
            k, o.status, o.iterations, string(h), isempty(msg) ? "ok" : msg)
end
