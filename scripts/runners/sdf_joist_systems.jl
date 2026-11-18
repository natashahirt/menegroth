# Three joist systems on full-scale 2024 plans.
#
# The module is 1.25 m, the loose waffle pan. Concrete ribs cannot meet
# ACI 318-11 §8.13.3 at that spacing, so the floor becomes one-way joists.
# Steel ribs are not §8.13 construction, so they stay at 1.25 m and the
# floor type is left as given.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/sdf_joist_systems.jl
#
# Plan names may be passed as arguments. The default three share a 24 m by
# 20 m footprint and nine column points.

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const JOIST_PLANS = ["grid/x1y1", "topology/r2c1", "star/e0c0"]

const JOIST_SYSTEMS = [:concrete_composite, :steel_deck, :steel_twoway]

"""Parameters for one full-scale joist system."""
function joist_system_parameters(plan_name::AbstractString, system::Symbol)
    if system === :concrete_composite
        params = rib_parameters(plan_name, :waffle)
        params.name = "concrete joists, composite RC"
        return params
    elseif system === :steel_deck
        params = system_parameters(plan_name, :deck)
        params.framing_opts = (
            materials = (steel = SR.A992_Steel,),
            module_spacing = (WAFFLE_PAN_M, WAFFLE_PAN_M),
            analysis = :grillage,
            beam_options = params.beams,
        )
        params.name = "steel joists, composite deck"
        params.description = String(plan_name)
        params.max_iterations = 4
        params.skip_visualization = false
        return params
    elseif system === :steel_twoway
        params = system_parameters(plan_name, :two_way)
        beams = SR.SteelBeamOptions()
        params.floor = SR.TwoWayOptions()
        params.beams = beams
        params.columns = SR.SteelColumnOptions()
        params.materials = MaterialOptions(concrete = SR.NWC_4000,
                                           rebar = SR.Rebar_60,
                                           steel = SR.A992_Steel)
        params.framing_opts = (
            materials = (steel = SR.A992_Steel,),
            module_spacing = (WAFFLE_PAN_M, WAFFLE_PAN_M),
            analysis = :grillage,
            beam_options = beams,
        )
        params.name = "steel joists, two-way RC, non-composite"
        params.description = String(plan_name)
        params.max_iterations = 4
        params.skip_visualization = false
        return params
    end
    throw(ArgumentError("Unknown joist system $system"))
end

_max_over(items, f) = isempty(items) ? 0.0 : maximum(f, items)

"""One row of the comparison, taken from the solved design."""
function _joist_numbers(design)
    beams = collect(values(design.beams))
    columns = collect(values(design.columns))
    summary = design.summary
    return (
        beams = length(beams),
        columns = length(columns),
        beam_fail = count(b -> !b.ok, beams),
        column_fail = count(c -> !c.ok, columns),
        flexure = _max_over(beams, b -> b.flexure_ratio),
        shear = _max_over(beams, b -> b.shear_ratio),
        column_axial = _max_over(columns, c -> c.axial_ratio),
        column_pm = _max_over(columns, c -> c.interaction_ratio),
        ok = summary.all_checks_pass,
        critical = summary.critical_element,
        critical_ratio = summary.critical_ratio,
        ec = summary.embodied_carbon,
        steel = summary.steel_weight,
        rebar = summary.rebar_weight,
        concrete = summary.concrete_volume,
    )
end

function _print_numbers(io, numbers)
    println(io, "beams=$(numbers.beams)  beam_fail=$(numbers.beam_fail)  " *
                "flexure=$(round(numbers.flexure; digits=3))  " *
                "shear=$(round(numbers.shear; digits=3))")
    println(io, "columns=$(numbers.columns)  column_fail=$(numbers.column_fail)  " *
                "axial=$(round(numbers.column_axial; digits=3))  " *
                "pm=$(round(numbers.column_pm; digits=3))")
    println(io, "all_checks=$(numbers.ok)  critical=$(numbers.critical)  " *
                "ratio=$(round(numbers.critical_ratio; digits=3))")
    println(io, "ec=$(numbers.ec)  steel=$(numbers.steel)  rebar=$(numbers.rebar)  " *
                "concrete=$(numbers.concrete)")
end

"""Design the joist systems of each plan. One scene per plan."""
function design_joist_systems(plans, systems = JOIST_SYSTEMS)
    stamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    csv_path = joinpath(REPORT_DIR, "joist_systems_$(stamp).csv")
    mkpath(REPORT_DIR)
    println("Joist systems  ", join(plans, ", "))
    println("Log: $csv_path")
    open(csv_path, "w") do io
        println(io, "plan,system,status,seconds,beams,beam_fail,flexure,shear," *
                    "columns,column_fail,axial,pm,all_checks,critical,ratio,report")
        for plan_name in plans
            scene = joinpath(SCENE_DIR, "sdf_$(_slug(plan_name))_joist_systems.mgscene")
            isfile(scene) && rm(scene)
            report_dir = joinpath(REPORT_DIR, _slug(plan_name) * "_joist_systems")
            mkpath(report_dir)
            for system in systems
                params = joist_system_parameters(plan_name, system)
                println("  $plan_name  $(params.name)")
                report = joinpath(report_dir, "$(system).txt")
                t0 = time()
                try
                    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
                    design = design_building(struc, params)
                    seconds = round(time() - t0; digits = 1)
                    framing = _framing_summary(design)
                    numbers = _joist_numbers(design)
                    println(framing)
                    _print_numbers(stdout, numbers)
                    println("    ", seconds, "s")
                    _write_report(report, design,
                        "Plan: $plan_name\nSystem: $(params.name)\nSeconds: $seconds\n\n" *
                        framing * "\n\n" * sprint(_print_numbers, numbers))
                    try
                        append_variant!(scene, design)
                        println("    scene $scene")
                    catch err
                        println("    scene failed")
                        println(sprint(showerror, err))
                    end
                    println(io, plan_name, ",", system, ",solved,", seconds, ",",
                            numbers.beams, ",", numbers.beam_fail, ",",
                            round(numbers.flexure; digits = 3), ",",
                            round(numbers.shear; digits = 3), ",",
                            numbers.columns, ",", numbers.column_fail, ",",
                            round(numbers.column_axial; digits = 3), ",",
                            round(numbers.column_pm; digits = 3), ",",
                            numbers.ok, ",\"", numbers.critical, "\",",
                            round(numbers.critical_ratio; digits = 3), ",",
                            report)
                catch err
                    seconds = round(time() - t0; digits = 1)
                    msg = sprint(showerror, err)
                    println("    failed  ", seconds, "s")
                    println(msg)
                    open(report, "w") do rio
                        println(rio, "Plan: $plan_name\nSystem: $(params.name)\nSeconds: $seconds")
                        println(rio)
                        println(rio, msg)
                    end
                    println(io, plan_name, ",", system, ",failed,", seconds,
                            ",,,,,,,,,,,", report)
                end
                flush(io)
            end
        end
    end
    println("Wrote ", csv_path)
    return csv_path
end

_systems = haskey(ENV, "JOIST_SYSTEMS") ?
    [Symbol(strip(s)) for s in split(ENV["JOIST_SYSTEMS"], ",") if !isempty(strip(s))] :
    JOIST_SYSTEMS
design_joist_systems(isempty(ARGS) ? JOIST_PLANS : String.(ARGS), _systems)
