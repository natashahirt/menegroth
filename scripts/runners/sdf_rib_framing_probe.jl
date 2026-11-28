# Rib framing of one SDF plan without sizing: ribs per slab and their bays.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/sdf_rib_framing_probe.jl grid/x1y1 [system]

include(joinpath(@__DIR__, "sdf_rib_design.jl"))
const SY = StructuralSynthesizer

function probe(plan_name::AbstractString, system::Symbol)
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    params = rib_parameters(plan_name, system)
    SY.prepare!(struc, params)
    skel = struc.skeleton
    for (si, slab) in enumerate(struc.slabs)
        poly = SY._slab_interior_polygon_m(struc, slab)
        xs = poly === nothing ? [NaN] : [p[1] for p in poly]
        ys = poly === nothing ? [NaN] : [p[2] for p in poly]
        n_rib = 0
        groups = Set{UInt64}()
        for level in slab.framing_levels
            for bi in SY.level_member_indices(struc, level)
                n_rib += 1
                g = SY.group_id(struc.beams[bi])
                g === nothing || push!(groups, g)
            end
        end
        println("slab ", si, "  x ", round(minimum(xs); digits = 2), "–", round(maximum(xs); digits = 2),
                "  y ", round(minimum(ys); digits = 2), "–", round(maximum(ys); digits = 2),
                "  cells ", length(slab.cell_indices),
                "  levels ", length(slab.framing_levels),
                "  ribs ", n_rib, "  groups ", length(groups),
                "  holes ", length(SY._slab_hole_loops_m(struc, slab)))
    end
    println("beams ", length(struc.beams), "  edges ", length(skel.edge_indices))
end

probe(ARGS[1], Symbol(get(ARGS, 2, "waffle")))
