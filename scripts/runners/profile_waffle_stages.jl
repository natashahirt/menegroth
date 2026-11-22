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

# Attribute the member stage's wall time to its sub-phases.
ENV["SS_MEMBER_TIMING"] = "1"
SY.reset_member_timers!()

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

# Member-stage wall-time attribution. The first group is a partition of the
# member stage (sums to ~members); the second group is cross-cutting sub-measures
# (rib sizing happens inside both `screen_rib_stems` and `size_beams`, so these
# overlap the partition above).
println("\n-- member sub-phase wall time (SS_MEMBER_TIMING) --")
partition = [:screen_rib_stems, :reanalyze_fe, :iterate_members, :report_rib_deflection,
             :verify_installed]
internals = [:size_beams, :grow_heads, :size_columns, :update_stiffness]
crosscut  = [:rib_demands, :rib_kernel, :rib_deflection,
             :grillage_bays, :resolve_heads, :check_heads]
function _show_timers(keys)
    for k in keys
        t = get(SY._MEMBER_PHASE_TIMERS, k, nothing)
        t === nothing && continue
        n = get(SY._MEMBER_PHASE_COUNTS, k, 0)
        println("    ", rpad(string(k), 24), rpad(string(round(t; digits = 1), " s"), 12),
                "(", n, " calls)")
    end
end
println("  [partition of the member stage]")
_show_timers(partition)
println("  [iterate_members internals]")
_show_timers(internals)
println("  [cross-cutting: rib sizing + deflection]")
_show_timers(crosscut)

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
