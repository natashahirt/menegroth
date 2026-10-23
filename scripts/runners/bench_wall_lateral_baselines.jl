# Baseline wall-clock times for the existing reduced lateral evaluator and the
# existing isolated FEMLateralEvaluator. One symmetric core: four walls, two
# stories. Does not time a unified building model.
#
# Run with SS_ENABLE_VISUALIZATION=false:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/bench_wall_lateral_baselines.jl

using Printf
using StructuralSizer

# A cold gravity start would build and solve the unified building model.
println("cold gravity: skipped")

const H = 3.0
const K_WALL = 1.0e7
const FX = 1.0e5
const T_WALL = 0.3
const E_WALL = 25.0e9
const NU_WALL = 0.2

# One static case. Two story-force records travel in that single solve.
const loads = [
    StoryLoad(1, FX, 0.0, 0.0, 0.0),
    StoryLoad(2, FX, 0.0, 0.0, 0.0),
]
const load_case_count = 1

function core_walls(k::Float64)
    walls = WallLine[]
    for story in 1:2
        append!(walls, (
            WallLine(10 * story + 1,  0.0, -5.0, 0.0,   k, story),
            WallLine(10 * story + 2,  0.0,  5.0, 0.0,   k, story),
            WallLine(10 * story + 3, -5.0,  0.0, pi/2,  k, story),
            WallLine(10 * story + 4,  5.0,  0.0, pi/2,  k, story),
        ))
    end
    return walls
end

function core_panels(t::Float64, E::Float64, ν::Float64, h::Float64)
    plan = (
        (-2.0, -5.0,  2.0, -5.0),
        (-2.0,  5.0,  2.0,  5.0),
        (-5.0, -2.0, -5.0,  2.0),
        ( 5.0, -2.0,  5.0,  2.0),
    )
    panels = WallPanel[]
    for story in 1:2
        z0 = (story - 1) * h
        z1 = story * h
        for (i, spec) in enumerate(plan)
            x1, y1, x2, y2 = spec
            push!(panels, WallPanel((story - 1) * 4 + i, x1, y1, x2, y2,
                                    z0, z1, t, E, ν, story))
        end
    end
    return panels
end

function wallclock_seconds(f)
    f()
    GC.gc()
    local result
    seconds = @elapsed begin
        result = f()
    end
    size(result.story_disp, 1) == 2 || error("baseline core did not return two stories")
    return seconds
end

walls = core_walls(K_WALL)
panels = core_panels(T_WALL, E_WALL, NU_WALL, H)
reduced = ReducedDiaphragmEvaluator(story_heights=[H, H], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.0)
fem = FEMLateralEvaluator(story_heights=[H, H], mesh_div=3, plan_halfwidth=(5.0, 5.0))

reduced_s = wallclock_seconds(() -> evaluate_lateral(reduced, walls, loads))
fem_s = wallclock_seconds(() -> evaluate_lateral(fem, panels, loads))

@printf("reduced_s %.6f\n", reduced_s)
@printf("isolated_fem_s %.6f\n", fem_s)
println("load_case_count ", load_case_count)
println("story_load_count ", length(loads))
