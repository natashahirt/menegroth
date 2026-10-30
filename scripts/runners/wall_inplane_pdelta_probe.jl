# Does Asap.solve_pdelta! amplify a wall's in-plane sway?
#
# A cantilever wall in the XZ plane carries vertical P and horizontal H at its
# top. Out-of-plane translation is fixed at every node, so only in-plane sway
# remains. The same wall as one vertical frame element (same strong-axis EI and
# area) is the control. If the shell geometric stiffness carries the in-plane
# P-delta term, both amplifications should be close.
#
# Usage: julia --project=StructuralSynthesizer scripts/runners/wall_inplane_pdelta_probe.jl

using Asap
using Unitful
using LinearAlgebra

const L = 6.0       # wall length along X [m]
const H = 12.0      # wall height along Z [m]
const t = 0.3       # thickness [m]
const E = 0.35 * 25e9
const ν = 0.2
const H_lat = 1.0e5 # total horizontal force at the top [N]

"""Wall mesh. Returns (model, top node ids)."""
function wall_model(P_total; nx=6, nz=12)
    nodes = Asap.Node[]
    for j in 0:nz, i in 0:nx
        z = j * H / nz
        fix = j == 0 ? :fixed : :free
        n = Asap.Node([i * L / nx * u"m", 0.0u"m", z * u"m"], fix)
        j > 0 && (n.dof[2] = false)   # no out-of-plane translation
        push!(nodes, n)
    end
    id(i, j) = j * (nx + 1) + i + 1
    shells = Asap.ShellTri3[]
    for j in 0:nz-1, i in 0:nx-1
        a, b, c, d = id(i, j), id(i + 1, j), id(i, j + 1), id(i + 1, j + 1)
        push!(shells, Asap.ShellTri3((nodes[a], nodes[b], nodes[d]), t * u"m", E * u"Pa", ν; id=:wall))
        push!(shells, Asap.ShellTri3((nodes[a], nodes[d], nodes[c]), t * u"m", E * u"Pa", ν; id=:wall))
    end
    top = [id(i, nz) for i in 0:nx]
    loads = Asap.AbstractLoad[]
    for k in top
        push!(loads, Asap.NodeForce(nodes[k],
            [H_lat / length(top) * u"N", 0.0u"N", -P_total / length(top) * u"N"]))
    end
    return Asap.Model(nodes, Asap.FrameElement[], shells, loads), nodes, top
end

"""The same wall as one vertical frame element with the wall's strong-axis EI."""
function stick_model(P_total; nseg=12)
    I_strong = t * L^3 / 12
    G = E / (2 * (1 + ν))
    sec = Asap.Section(t * L * u"m^2", E * u"Pa", G * u"Pa",
        I_strong * u"m^4", I_strong * u"m^4", 1.0u"m^4", 2400u"kg/m^3")
    nodes = [Asap.Node([0.0u"m", 0.0u"m", k * H / nseg * u"m"], k == 0 ? :fixed : :free)
             for k in 0:nseg]
    elems = [Asap.Element(nodes[k], nodes[k + 1], sec) for k in 1:nseg]
    loads = Asap.AbstractLoad[Asap.NodeForce(nodes[end], [H_lat * u"N", 0.0u"N", -P_total * u"N"])]
    return Asap.Model(nodes, elems, loads), nodes, [length(nodes)]
end

top_ux(model, nodes, top) = sum(model.u[nodes[k].globalID[1]] for k in top) / length(top)

function amplification(build, P_total)
    m, nodes, top = build(P_total)
    Asap.process!(m)
    Asap.solve!(m)
    u_lin = top_ux(m, nodes, top)
    m2, nodes2, top2 = build(P_total)
    Asap.solve_pdelta!(m2; max_iter=30, tol=1e-8)
    u_pd = top_ux(m2, nodes2, top2)
    return u_lin, u_pd
end

# Pick P so that the wall's story-type θ = P Δ / (H_lat h) is 0.10.
u0, _ = amplification(wall_model, 0.0)
P = 0.10 * H_lat * H / u0
println("wall linear top drift at P = 0: ", u0, " m;  P for θ = 0.10: ", P, " N")

for (name, build) in (("wall shells", wall_model), ("frame stick", stick_model))
    u_lin, u_pd = amplification(build, P)
    θ = P * u_lin / (H_lat * H)
    println(rpad(name, 12), "  linear = ", round(u_lin; sigdigits=6),
            "  P-delta = ", round(u_pd; sigdigits=6),
            "  ratio = ", round(u_pd / u_lin; digits=4),
            "  1/(1-θ) = ", round(1 / (1 - θ); digits=4))
end
