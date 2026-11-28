# Tributary-area coverage for Slab Design Factors plans.
#
# Sums the floor faces, the tributary polygons, and the area written onto the
# floor beams. A closed partition has polygon area equal to the gross faces
# and beam area equal to the polygon area.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralStudies \
#     scripts/runners/run_sdf_tributary_balance.jl
#   julia --project=StructuralStudies scripts/runners/run_sdf_tributary_balance.jl \
#     star/e10c2 nova/e1c1 --systems=two_way

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "slab_design_factors", "study.jl"))

systems = [:one_way, :two_way]
names = String[]
for a in ARGS
    if startswith(a, "--systems=")
        systems = Symbol.(split(a[length("--systems=") + 1:end], ','))
    else
        push!(names, a)
    end
end
isempty(names) && (names = COVERAGE_PLANS)
print_header("Tributary coverage")
df = coverage_report(names, systems)
path = output_filename("sdf_coverage", RESULTS_DIR)
CSV.write(path, df)
write_run_meta(path; note = "tributary area and floor-load balance")
println("Wrote $path")
