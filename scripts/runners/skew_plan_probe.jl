# Probe: does a rotated or parallelogram office mesh and solve with walls?
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/skew_plan_probe.jl [floor_type]

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Unitful, Meshes, Asap, StructuralSynthesizer, StructuralSizer
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "analyze", "skew_plan_fixtures.jl"))

floor_type = isempty(ARGS) ? :vault : Symbol(ARGS[1])
for (name, map) in (("rotated 30°", _skew_rotation(deg2rad(30))),
                    ("parallelogram 20°", _skew_shear(deg2rad(20))))
    try
        struc = _skew_office(map; floor_type)
        params = DesignParameters(diaphragm_mode=:rigid, skip_visualization=true)
        to_asap!(struc; params=params, diaphragms=:rigid)
        println(name, ": walls=", length(struc.walls), " piers=", length(struc.wall_mesh.piers),
                " links=", length(struc.asap_rigid_links), " max|u|=", maximum(abs, struc.asap_model.u))
        for w in struc.walls
            w.story == 0 || continue
            L = hypot(w.x2 - w.x1, w.y2 - w.y1)
            println("   wall tangent ", round.(((w.x2 - w.x1) / L, (w.y2 - w.y1) / L); digits=4))
        end
    catch e
        println(name, ": FAILED ", first(sprint(showerror, e), 600))
    end
end
