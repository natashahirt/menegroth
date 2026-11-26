# Four floor systems on three nova/topology plans.
#
# Same 24 m by 20 m footprint as the star/e0c0 waffle scene. The rib module
# is 1.25 m on every system that adds ribs, so the deck or slab spans between
# ribs rather than across the drawn bay.
#
#   steel_deck            steel ribs, composite metal deck (3VLI)
#   concrete_rib          concrete ribs, two-way concrete slab (the waffle scene)
#   steel_rib_composite   steel ribs, composite with a two-way concrete slab
#   bare_steel            steel ribs, non-composite, under a two-way concrete slab
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies \
#         scripts/runners/sdf_nova_topology_systems.jl
#
# Plan names replace the default three. NOVA_MAX_ITER overrides the cap
# (default 12, the waffle-scene fidelity).

include(joinpath(@__DIR__, "sdf_joist_systems.jl"))

const NOVA_PLANS = ["topology/r2c1", "nova/e1c1", "topology/r7c1"]
const NOVA_SYSTEMS = [:steel_deck, :concrete_rib, :steel_rib_composite, :bare_steel]
const NOVA_MAX_ITER = parse(Int, get(ENV, "NOVA_MAX_ITER", "12"))
const NOVA_LOG_DIR = joinpath(ROOT, "logs", "sdf_nova_topology")

"""Parameters for one of the four floor systems."""
function nova_system_parameters(plan_name::AbstractString, system::Symbol)
    params = if system === :steel_deck
        joist_system_parameters(plan_name, :steel_deck)
    elseif system === :concrete_rib
        rib_parameters(plan_name, :waffle)
    elseif system === :bare_steel
        joist_system_parameters(plan_name, :steel_twoway)
    elseif system === :steel_rib_composite
        _steel_rib_composite(plan_name)
    else
        throw(ArgumentError("Unknown floor system $system"))
    end
    params.max_iterations = NOVA_MAX_ITER
    params.skip_visualization = true
    params.description = String(plan_name)
    return params
end

"""Steel ribs at the waffle module, composite with the two-way concrete slab."""
function _steel_rib_composite(plan_name::AbstractString)
    params = system_parameters(plan_name, :two_way)
    beams = SR.SteelBeamOptions(
        composite = true,
        composite_slab_type = :solid,
        deflection_limit = 1 / 360,
        total_deflection_limit = 1 / 240,
    )
    params.floor = SR.TwoWayOptions()
    params.beams = beams
    params.columns = SR.SteelColumnOptions()
    params.materials = MaterialOptions(
        concrete = SR.NWC_4000,
        rebar = SR.Rebar_60,
        steel = SR.A992_Steel,
    )
    params.framing_opts = (
        materials = (steel = SR.A992_Steel,),
        module_spacing = (WAFFLE_PAN_M, WAFFLE_PAN_M),
        analysis = :grillage,
        beam_options = beams,
    )
    params.name = "steel ribs, composite concrete deck"
    return params
end

function _say(io, args...)
    println(io, args...)
    flush(io)
end

"""Design each plan as each system. One scene per plan, one variant per system."""
function design_nova_systems(plans, systems = NOVA_SYSTEMS)
    stamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    mkpath(NOVA_LOG_DIR)
    csv_path = joinpath(NOVA_LOG_DIR, "systems_$(stamp).csv")
    _say(stdout, "Plans: ", join(plans, ", "))
    _say(stdout, "Systems: ", join(string.(systems), ", "))
    _say(stdout, "max_iterations = ", NOVA_MAX_ITER)
    _say(stdout, "Log: ", csv_path)
    open(csv_path, "w") do io
        println(io, "plan,system,status,seconds,all_checks,critical,ratio,scene,report")
        flush(io)
        for plan_name in plans
            scene = joinpath(SCENE_DIR, "sdf_$(_slug(plan_name))_floor_systems.mgscene")
            isfile(scene) && rm(scene)
            report_dir = joinpath(NOVA_LOG_DIR, _slug(plan_name))
            mkpath(report_dir)
            for system in systems
                params = nova_system_parameters(plan_name, system)
                _say(stdout, "\n=== $plan_name  $(params.name) ===")
                report = joinpath(report_dir, "$(system).txt")
                t0 = time()
                try
                    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
                    design = design_building(struc, params; restore = false)
                    seconds = round(time() - t0; digits = 1)
                    summary = design.summary
                    scene_id = ""
                    scene_error = ""
                    try
                        scene_id = append_variant!(scene, design)
                    catch err
                        scene_error = sprint(showerror, err)
                    end
                    _write_report(report, design,
                        "Plan: $plan_name\nSystem: $(params.name)\n" *
                        "Seconds: $seconds\nScene: $(basename(scene))\n" *
                        (isempty(scene_error) ? "" : "Scene error:\n$scene_error\n"))
                    _say(stdout, "    solved  ", seconds, "s  all_checks=",
                         summary.all_checks_pass, "  critical=",
                         summary.critical_element, "  r=",
                         round(summary.critical_ratio; digits = 4))
                    isempty(scene_id) || _say(stdout, "    scene ", scene)
                    println(io, plan_name, ",", system, ",solved,", seconds, ",",
                            summary.all_checks_pass, ",\"", summary.critical_element,
                            "\",", round(summary.critical_ratio; digits = 4), ",",
                            scene, ",", report)
                catch err
                    seconds = round(time() - t0; digits = 1)
                    msg = sprint(showerror, err)
                    open(report, "w") do rio
                        println(rio, "Plan: $plan_name")
                        println(rio, "System: $(params.name)")
                        println(rio, "Seconds: $seconds")
                        println(rio)
                        println(rio, "This design did not finish.")
                        println(rio)
                        println(rio, msg)
                    end
                    _say(stdout, "    failed  ", seconds, "s")
                    _say(stdout, msg)
                    println(io, plan_name, ",", system, ",failed,", seconds,
                            ",,,,," , report)
                end
                flush(io)
            end
        end
    end
    _say(stdout, "\nWrote ", csv_path)
    return csv_path
end

if abspath(PROGRAM_FILE) == @__FILE__
    design_nova_systems(isempty(ARGS) ? NOVA_PLANS : String.(ARGS))
end
