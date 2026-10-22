# Dead and live loads for the poker-table seed solve.
# Furniture live values are test-inspired / engineering judgment, not ASCE 7
# occupancy (see plan). Self-weight uses the judgment densities in materials.jl.

using Asap
using Unitful

const G_ACCEL = 9.80665u"m/s^2"

function wood_selfweight_pressure()
    # ρ t g, downward.
    return uconvert(u"Pa", WOOD_RHO * WOOD_T * G_ACCEL)
end

function frame_selfweight_loads(elements)
    loads = Asap.AbstractLoad[]
    for el in elements
        w = uconvert(u"N/m", el.section.ρ * el.section.A * G_ACCEL)
        push!(loads, Asap.LineLoad(el, [0.0u"N/m", 0.0u"N/m", -w], :selfweight))
    end
    return loads
end

function shell_selfweight_loads(shells)
    p = wood_selfweight_pressure()
    return Asap.AbstractLoad[Asap.AreaLoad(sh, p; direction = (0.0, 0.0, -1.0)) for sh in shells]
end

"""250 lbf accidental / edge patch, applied at a leaf apex. Engineering judgment."""
function edge_patch_load(apex::Asap.Node; P = 250.0u"lbf")
    F = uconvert(u"N", P)
    return Asap.NodeForce(apex, [0.0u"N", 0.0u"N", -F], :edge_patch)
end

"""~50 lbf per player at the flush perimeter, 10-player poker. Engineering judgment."""
function poker_rail_loads(edge_nodes; P_each = 50.0u"lbf")
    F = uconvert(u"N", P_each)
    return Asap.AbstractLoad[Asap.NodeForce(n, [0.0u"N", 0.0u"N", -F], :poker_rail) for n in edge_nodes]
end
