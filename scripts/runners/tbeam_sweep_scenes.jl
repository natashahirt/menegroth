#=
Generate viewer scenes for the three plans validated by the T-beam cache
exactness sweep (tbeam_cache_exactness_sweep.jl).

Each plan is designed ONCE with the capacity cache ON (the production default)
using the same `rib_parameters(plan, :waffle)` configuration the sweep compared,
then written to its own `.mgscene` via `append_variant!`. Fidelity defaults to
`max_iterations=12` (override with `SCENE_MAX_ITER`); the swept geometries all
converge well under that cap, so full fidelity is affordable here.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies \
        scripts/runners/tbeam_sweep_scenes.jl [plan ...]
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SCENE_PLANS = ["grid/x1y1", "special/rhombus_8x12", "star/e0c0"]
const SCENE_MAX_ITER = parse(Int, get(ENV, "SCENE_MAX_ITER", "12"))

"""Design one plan's waffle (cache ON) and write its scene; return a summary row."""
function _scene_for_plan(plan_name::AbstractString)
    params = rib_parameters(plan_name, :waffle)
    params.max_iterations = SCENE_MAX_ITER

    scene = joinpath(SCENE_DIR, "sdf_$(_slug(plan_name))_waffle_sweep.mgscene")
    isfile(scene) && rm(scene)

    println("\n=== $plan_name (max_iterations=$SCENE_MAX_ITER) ===")
    flush(stdout)

    t0 = time()
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    design = design_building(struc, params; restore = false)
    seconds = round(time() - t0; digits = 1)

    s = design.summary
    append_variant!(scene, design)

    println("    all_checks_pass  ", s.all_checks_pass)
    println("    critical         ", s.critical_element, "  r=",
            round(s.critical_ratio; digits = 4))
    println("    scene            ", scene, "   (", seconds, "s)")
    return (; plan = plan_name, scene, seconds,
            ok = s.all_checks_pass, critical = string(s.critical_element))
end

function main(args)
    plans = isempty(args) ? SCENE_PLANS : String.(args)
    println("T-beam sweep scenes over ", length(plans), " plan(s)")
    rows = NamedTuple[]
    for plan_name in plans
        try
            push!(rows, _scene_for_plan(plan_name))
        catch err
            println("    ERROR on $plan_name: ", sprint(showerror, err))
            push!(rows, (; plan = plan_name, scene = "", seconds = 0.0,
                         ok = false, critical = "ERROR"))
        end
    end

    println("\n==== scenes ====")
    for r in rows
        println("    ", rpad(r.plan, 24),
                r.critical == "ERROR" ? "ERROR" :
                    "$(basename(r.scene))  (all_checks=$(r.ok))")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
