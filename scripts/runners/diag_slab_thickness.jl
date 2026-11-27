# Decisive fact for the composite-path question: how thick (and heavy) is the
# slab that steel_rib_composite stacks on the steel joists? A thick two-way RC
# slab = two full floor systems stacked, and the story shell meshes it as a
# two-way plate that concentrates load onto the stiff composite girders.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies \
#         scripts/runners/diag_slab_thickness.jl [plan] [system]

include(joinpath(@__DIR__, "sdf_nova_topology_systems.jl"))

using Printf
_as(x, u) = x isa Unitful.Quantity ? ustrip(u, x) : Float64(x)

function main()
    plan = length(ARGS) >= 1 ? ARGS[1] : "topology/r2c1"
    system = length(ARGS) >= 2 ? Symbol(ARGS[2]) : :steel_rib_composite
    @printf("=== %s  %s ===\n", plan, system)
    params = nova_system_parameters(plan, system)

    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    prepare!(struc, params)
    to_asap!(struc; params = params, diaphragms = :none)
    SR.size_slabs!(struc; options = SS.resolve_floor_options(params), max_iterations = 10)

    @printf("\n%-5s %-8s %-10s %7s %9s %9s %9s\n",
            "slab", "t(mm)", "floor", "sw(kPa)", "sdl(kPa)", "ll(kPa)", "fact(kPa)")
    for (si, slab) in enumerate(struc.slabs)
        th = _as(SS.thickness(slab), u"m") * 1000
        ci = first(slab.cell_indices)
        c = struc.cells[ci]
        @printf("%-5d %-8.0f %-10s %7.2f %9.2f %9.2f %9.2f\n",
                si, th, slab.floor_type, _as(c.self_weight, u"kN/m^2"),
                _as(c.sdl, u"kN/m^2"), _as(c.live_load, u"kN/m^2"),
                _as(SS.total_factored_pressure(c), u"kN/m^2"))
    end

    # Count joists to confirm the stacked grillage still exists under the slab.
    njoist = count(b -> b.role === :joist, struc.beams)
    @printf("\njoists (role=:joist) under the slab: %d\n", njoist)
end

main()
