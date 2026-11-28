# Rib census of the SDF waffle after framing, before sizing.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/waffle_rib_census.jl [plan]

include(joinpath(@__DIR__, "sdf_rib_design.jl"))
const SY = StructuralSynthesizer

function census(plan_name)
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    params = rib_parameters(plan_name, :waffle)
    SY.prepare!(struc, params)
    skel = struc.skeleton
    for (si, slab) in enumerate(struc.slabs)
        poly = SY._slab_interior_polygon_m(struc, slab)
        c = poly === nothing ? (NaN, NaN) :
            (sum(p[1] for p in poly) / length(poly), sum(p[2] for p in poly) / length(poly))
        levels = slab.framing_levels
        n = isempty(levels) ? 0 : length(SY.level_member_indices(struc, levels[1]))
        groups = isempty(levels) ? () :
            (levels[1].group_id, levels[1].edge_group_id, levels[1].solid_group_id)
        println("slab ", si, "  centroid ", round.(c; digits = 2),
                "  type ", slab.floor_type, "  levels ", length(levels),
                "  members ", n, "  groups ", groups)
    end
end

census(isempty(ARGS) ? "grid/x1y1" : ARGS[1])
