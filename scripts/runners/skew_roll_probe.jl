# Probe: roof displacement under a unit force along the building's first axis,
# aligned vs rotated office, for several column roll angles.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/skew_roll_probe.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Unitful, Asap, StructuralSynthesizer, StructuralSizer
import Meshes
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "analyze", "skew_plan_fixtures.jl"))

function build(map)
    struc = _skew_office(map; floor_type=:vault)
    to_asap!(struc; params=DesignParameters(diaphragm_mode=:rigid, skip_visualization=true),
             diaphragms=:rigid)
    return struc
end

function vertical_elements(struc)
    filter(struc.asap_model.frame_elements) do el
        a = ustrip.(u"m", el.nodeStart.position)
        b = ustrip.(u"m", el.nodeEnd.position)
        hypot(b[1] - a[1], b[2] - a[2]) < 1e-9
    end
end

function roof_master(struc)
    best = nothing
    for link in struc.asap_rigid_links
        z = ustrip(u"m", link.nodeA.position[3])
        (isnothing(best) || z > ustrip(u"m", best.position[3])) && (best = link.nodeA)
    end
    return best
end

"""Roof master displacement (along d, across d, twist) for a unit force along d."""
function response(struc, d, roll)
    m = struc.asap_model
    for el in vertical_elements(struc)
        el.Ψ = roll
    end
    Asap.process!(m)
    master = roof_master(struc)
    load = [Asap.NodeForce(master, [d[1] * u"kN", d[2] * u"kN", 0.0u"kN"], :probe),
            Asap.NodeMoment(master, [0.0u"kN*m", 0.0u"kN*m", 1.0u"kN*m"], :probe_t)]
    cases = Vector{Asap.AbstractLoad}[Asap.AbstractLoad[load[1]], Asap.AbstractLoad[load[2]]]
    us = Asap.solve(m, cases, struc.asap_rigid_links)
    g = master.globalID
    out = map(us) do u
        along = u[g[1]] * d[1] + u[g[2]] * d[2]
        across = -u[g[1]] * d[2] + u[g[2]] * d[1]
        (along, across, u[g[6]])
    end
    return out
end

α = deg2rad(30)
e1 = (cos(α), sin(α)); e2 = (-sin(α), cos(α))
s0 = build((x, y) -> (x, y))
s1 = build(_skew_rotation(α))
println("vertical elements: ", length(vertical_elements(s0)), " / ", length(vertical_elements(s1)))
println("roof master aligned ", ustrip.(u"m", roof_master(s0).position), "  rotated ", ustrip.(u"m", roof_master(s1).position))
el = first(vertical_elements(s0))
println("column section A=", el.section.A, " Ix=", el.section.Ix, " Iy=", el.section.Iy)

for (name, s, d) in (("aligned e1", s0, (1.0, 0.0)), ("aligned e2", s0, (0.0, 1.0)),
                     ("rotated e1", s1, e1), ("rotated e2", s1, e2))
    for deg in (-60, -30, 0, 30, 60, 90)
        r = response(s, d, deg2rad(deg))
        println(rpad(name, 12), " roll ", lpad(deg, 4), "  force: along ", r[1][1], " across ", r[1][2],
                " twist ", r[1][3], "   torque: twist ", r[2][3])
    end
end
