# Slab Design Factors geometries, three floor systems.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralStudies \
#     scripts/runners/run_slab_design_factors.jl                 # grid/x1y1, all three systems
#   julia --project=StructuralStudies scripts/runners/run_slab_design_factors.jl validation
#   julia --project=StructuralStudies scripts/runners/run_slab_design_factors.jl \
#     grid/x1y1 validation/office --systems=deck
#
# `validation` is office, school, and warehouse. A bare plan name is a path
# under the Slab Design Factors Geometries directory, without `.json`.

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "slab_design_factors", "study.jl"))

function _args(args)
    systems = SYSTEMS
    names = String[]
    for a in args
        if startswith(a, "--systems=")
            systems = Symbol.(split(a[length("--systems=") + 1:end], ','))
        elseif a == "smoke"
            append!(names, SMOKE_PLANS)
        elseif a == "validation"
            append!(names, VALIDATION_PLANS)
        else
            push!(names, a)
        end
    end
    isempty(names) && append!(names, SMOKE_PLANS)
    return names, systems
end

names, systems = _args(ARGS)
run_study(names, systems)
