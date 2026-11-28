# One joist-system design with the full stack trace on failure.
#
# The batch runner prints only the error message. This prints where it came from.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/diag_joist_system_trace.jl star/e10c2 concrete_composite

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

plan_name = length(ARGS) >= 1 ? ARGS[1] : "star/e10c2"
system = Symbol(length(ARGS) >= 2 ? ARGS[2] : "concrete_composite")

params = if system === :concrete_composite
    p = rib_parameters(plan_name, :waffle)
    p.name = "concrete joists, composite RC"
    p
else
    throw(ArgumentError("only concrete_composite is wired here, got $system"))
end

t0 = time()
try
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    design = design_building(struc, params)
    println("solved  ", round(time() - t0; digits = 1), " s  pass=", design.summary.all_checks_pass,
            "  critical=", design.summary.critical_element)
catch err
    println("failed  ", round(time() - t0; digits = 1), " s")
    showerror(stdout, err, catch_backtrace())
    println()
end
