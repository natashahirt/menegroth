# Compare the frame model as built (rotations free wherever an element restrains
# them) against the former behavior (every floor-node rotation locked), for
# steel beams (pinned ends) and concrete beams (fixed ends), under gravity and
# under a lateral roof load.
# Run: SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/check_node_rotation_lock.jl
using Unitful, Asap
using StructuralSynthesizer, StructuralSizer
const SS = StructuralSynthesizer

function build(params)
    skel = gen_medium_office(60.0u"ft", 60.0u"ft", 12.0u"ft", 3, 3, 3)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
    initialize!(struc; floor_type=:flat_plate, floor_opts=opts)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    to_asap!(struc; params=params)
    return struc
end

edges_of(struc, members) = [struc.segments[si].edge_idx for m in members for si in SS.segment_indices(m)]
max_end_moment(model, idxs) = maximum(i -> maximum(abs, model.frame_elements[i].forces[[5, 6, 11, 12]]), idxs) / 1e3

function lock_rotations!(model)
    for nd in model.nodes
        (nd.dof[1] && nd.dof[2] && nd.dof[3]) || continue
        nd.dof[4] = nd.dof[5] = nd.dof[6] = false
    end
end

function run_case(params, label; locked::Bool, lateral::Bool)
    struc = build(params)
    model = struc.asap_model
    locked && lock_rotations!(model)
    ztop = maximum(ustrip(u"m", nd.position[3]) for nd in model.nodes)
    roof = [nd for nd in model.nodes if abs(ustrip(u"m", nd.position[3]) - ztop) < 1e-6]
    lateral && (model.loads = Asap.AbstractLoad[Asap.NodeForce(nd, [10.0u"kN", 0.0u"kN", 0.0u"kN"]) for nd in roof])
    Asap.solve!(model; reprocess=true)
    drift = maximum(abs(ustrip(u"m", nd.displacement[1])) for nd in roof)
    println(rpad(label, 16), rpad(locked ? "locked" : "free", 8), rpad(lateral ? "lateral" : "gravity", 9),
            "max|M| beam=", round(max_end_moment(model, edges_of(struc, struc.beams)); digits=2),
            "  col=", round(max_end_moment(model, edges_of(struc, struc.columns)); digits=2), " kN·m",
            "  roof ux=", round(drift * 1000; digits=3), " mm")
end

for (params, label) in ((DesignParameters(), "steel beams"),
                        (DesignParameters(beams=ConcreteBeamOptions()), "concrete beams"))
    for lateral in (false, true), locked in (true, false)
        run_case(params, label; locked, lateral)
    end
end
