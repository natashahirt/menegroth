#=
Stage-split a whole grid/x1y1 dense-waffle `design_building` run, the gravity
grillage counterpart to profile_design_building_stages.jl (which profiles the
rigid-diaphragm core office). The waffle has no walls / no rigid diaphragm, so
the rigid-link factorization cache (#7) does not apply and the non-link solve
already reuses its symbolic factor. This run shows where the waffle's time
actually goes — in particular whether the `members` stage is dominated by FE
factorizations/solves or by the rib-sizing compute (MIP / P-M / catalog), which
is invisible to the factorization probe and therefore shows up as members
wall-time with a low factorization count.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/profile_waffle_stages.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))
const SY = StructuralSynthesizer

plan_name = "grid/x1y1"
params = rib_parameters(plan_name, :waffle)
params.framing_opts = merge(params.framing_opts,
    (module_spacing = (uconvert(u"m", 30.0u"inch"), uconvert(u"m", 30.0u"inch")),))
params.name = "waffle, 30 in pans"
params.description = plan_name

println("Profiling grid/x1y1 dense-waffle design_building (max_iterations=$(params.max_iterations))…")
flush(stdout)
struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))

local design
t_design = @elapsed begin
    design, probe = SY.with_sizing_probe() do
        design_building(struc, params; restore = false)
    end
end

println("\ndesign_building total: ", round(t_design; digits = 1), " s")

println("\n-- design.phase_timings (coarse) --")
for (phase, secs) in sort(collect(design.phase_timings); by = last, rev = true)
    println("    ", rpad(string(phase), 24), round(secs; digits = 2), " s")
end

SY.probe_report(probe)

println("probe recorded ", length(probe.log.events), " analysis events across ",
        length(probe.building_models), " building model id(s) and ",
        length(probe.spans), " stage spans.")

# Exactness fingerprint: the installed sizing must be bit-identical to the
# pre-memo baseline (critical ratio and embodied carbon unchanged).
s = design.summary
println("\n-- exactness fingerprint --")
println("all_checks_pass  = ", s.all_checks_pass)
println("critical_element = ", s.critical_element)
println("critical_ratio   = ", s.critical_ratio)
let ec = compute_building_ec(design.structure, params)
    println("total_ec         = ", round(ustrip(u"kgCO2e", ec.total_ec); digits = 4), " kgCO2e")
    println("EC intensity     = ", round(ustrip(u"kgCO2e/m^2", ec.ec_per_floor_area); digits = 4),
            " kgCO2e/m^2")
end
