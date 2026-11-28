# Size one 3×3 flat plate with the ACI 318-11 §13.5.3.3 increase on and off
# and print h, column sizes, iterations and where the increase was used.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/compare_moment_transfer_13_5_3_3.jl [span_ft] [method]
#
# method: ddm (default) or fea.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_SKIP_SOLVER_WARMUP"] = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")

using Asap
using StructuralSizer
using StructuralSynthesizer
using Unitful
using Printf

const SR = StructuralSizer

span_ft = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 24.0
method_key = length(ARGS) >= 2 ? ARGS[2] : "ddm"
method = method_key == "fea" ? SR.FEA(; pattern_loading = false) : SR.DDM()

function run_case(increase::Bool)
    skel = gen_medium_office(3span_ft * u"ft", 3span_ft * u"ft", 12.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(method = method, moment_transfer_increase = increase)
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    slab = first(struc.slabs)
    t = @elapsed r = SR.size_flat_plate!(struc, slab, ConcreteColumnOptions();
                                          method = method, opts = opts, verbose = false)
    return (r = r, t = t, struc = struc)
end

for increase in (false, true)
    out = run_case(increase)
    r = out.r
    println("\n── §13.5.3.3 increase = $increase  (span $(span_ft) ft, $(method_key)) ──")
    @printf("converged=%s  h=%.2f in  iterations=%d  time=%.1f s\n",
            string(r.converged), ustrip(u"inch", r.h_final), r.iterations, out.t)
    r.slab_result === nothing && continue
    details = r.slab_result.punching_check.details
    for (i, col) in enumerate(out.struc.columns)
        pr = details[i]
        pr === nothing && continue
        mt = get(pr, :moment_transfer, nothing)
        prov = mt === nothing ? "eq_13_1" :
            "x=$(mt.provision_x) γf=$(round(mt.γf_x, digits=3)), y=$(mt.provision_y) γf=$(round(mt.γf_y, digits=3))"
        @printf("  col %2d %-8s %4.0f×%-4.0f in  ratio=%.3f  %s\n", i, string(col.position),
                ustrip(u"inch", col.c1), ustrip(u"inch", col.c2), pr.ratio, prov)
    end
end
