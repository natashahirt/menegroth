#=
Unsymmetric wall-mesh study.

Two walls of different length, plus two columns, share one rigid diaphragm
and one horizontal story force. Each (div, rows) pair is the same quad split
`to_asap!` uses. The printout is each piece's share of the applied force,
from the base cut. Equilibrium is the check that those shares add to 1.

    julia --project=StructuralSynthesizer scripts/runners/wall_mesh_convergence.jl
=#

using StructuralSynthesizer
using Asap
using Unitful

const P_N = 1.0e6
const H = 4.0
const E = 30e9
const ν = 0.2
const T = 0.30

"""In-plane rigid tie: ux, uy, θz. Release is true where the DOF stays free."""
function _tie(master, slave)
    release = ntuple(i -> !(i in (1, 2, 6)), 6)
    return Asap.RigidLink(master, slave; release=release, id=:rigid_diaphragm)
end

function _panel_shells!(nodes, shells_out, x1, y1, x2, y2, nx, ny)
    function node(x, y, z)
        for nd in nodes
            p = nd.position
            dx = ustrip(u"m", p[1]) - x
            dy = ustrip(u"m", p[2]) - y
            dz = ustrip(u"m", p[3]) - z
            dx * dx + dy * dy + dz * dz < 1e-18 && return nd
        end
        fix = isapprox(z, 0.0; atol=1e-9) ? :fixed : :free
        nd = Asap.Node([x, y, z] .* u"m", fix, :wall)
        push!(nodes, nd)
        return nd
    end
    mine = Asap.ShellTri3[]
    for (s0, s1, r0, r1) in wall_panel_quads(nx, ny)
        xa = x1 + (x2 - x1) * s0
        ya = y1 + (y2 - y1) * s0
        xb = x1 + (x2 - x1) * s1
        yb = y1 + (y2 - y1) * s1
        z0 = H * r0
        z1 = H * r1
        nb0 = node(xa, ya, z0)
        nb1 = node(xb, yb, z0)
        nt1 = node(xb, yb, z1)
        nt0 = node(xa, ya, z1)
        t1 = Asap.ShellTri3((nb0, nb1, nt1), T * u"m", E * u"Pa", ν; id=:wall)
        t2 = Asap.ShellTri3((nb0, nt1, nt0), T * u"m", E * u"Pa", ν; id=:wall)
        push!(shells_out, t1, t2)
        push!(mine, t1, t2)
    end
    return mine
end

function _column(nodes, x, y)
    a = 1.0
    I = a^4 / 12
    sec = Asap.Section(a^2 * u"m^2", E * u"Pa", (E / 2.4) * u"Pa",
                       I * u"m^4", I * u"m^4", (0.141 * a^4) * u"m^4",
                       0.0u"kg/m^3")
    base = Asap.Node([x, y, 0.0] .* u"m", :fixed)
    top = Asap.Node([x, y, H] .* u"m", :free)
    push!(nodes, base, top)
    return Asap.Element(base, top, sec), top
end

"""Shares of the story force: long wall, short wall, columns. Sum should be 1."""
function shares(nx, ny)
    nodes = Asap.Node[]
    shells = Asap.ShellTri3[]
    long = _panel_shells!(nodes, shells, 0.0, 0.0, 8.0, 0.0, nx, ny)
    short = _panel_shells!(nodes, shells, 0.0, 6.0, 3.0, 6.0, nx, ny)
    col1, top1 = _column(nodes, 8.0, 3.0)
    col2, top2 = _column(nodes, -1.0, 3.0)
    # The master is a column top, which already has stiffness. A new node
    # tied only in plan would leave its vertical and bending DOFs free.
    # `require_diaphragm_node_stiffness` throws on that node before the solve.
    master = top1
    tops = Asap.Node[]
    for sh in shells, nd in sh.nodes
        isapprox(ustrip(u"m", nd.position[3]), H; atol=1e-9) || continue
        nd === master && continue
        nd in tops && continue
        push!(tops, nd)
    end
    links = Asap.RigidLink[_tie(master, nd) for nd in tops]
    push!(links, _tie(master, top2))
    load = Asap.NodeForce(master, [P_N * u"N", 0.0u"N", 0.0u"N"])
    frame = Asap.Element[col1, col2]
    require_diaphragm_node_stiffness(links, frame, shells)
    model = Asap.Model(nodes, frame, shells, Asap.AbstractLoad[load])
    Asap.solve!(model, links)
    walls = [
        Wall([1], H * u"m"; thickness=T * u"m", x1=0.0, y1=0.0, x2=8.0, y2=0.0),
        Wall([2], H * u"m"; thickness=T * u"m", x1=0.0, y1=6.0, x2=3.0, y2=6.0),
    ]
    mesh = WallMesh([long, short], wall_assemblies(walls))
    eq = check_story_cut_equilibrium(model, model.u, mesh, [load], 0.0)
    v_long = wall_pier_cut(long, model.u, 0.0; wall_indices=[1]).Fx / P_N
    v_short = wall_pier_cut(short, model.u, 0.0; wall_indices=[2]).Fx / P_N
    v_col = eq.cut[1] / P_N - v_long - v_short
    return (long=v_long, short=v_short, columns=v_col, passed=eq.passed,
            nshell=length(shells))
end

function main()
    println("div  rows  nshell  long   short  columns  sum   closed")
    prev = nothing
    for rows in (1, 2, 4, 8), div in (2, 4, 8, 16)
        s = shares(div, rows)
        println(lpad(div, 3), "  ", lpad(rows, 4), "  ", lpad(s.nshell, 6), "  ",
                round(s.long; digits=4), "  ", round(s.short; digits=4), "  ",
                round(s.columns; digits=4), "  ",
                round(s.long + s.short + s.columns; digits=4), "  ", s.passed)
        if prev !== nothing && prev.rows == rows
            println("      Δlong ", round(s.long - prev.long; digits=4),
                    "  Δshort ", round(s.short - prev.short; digits=4))
        end
        prev = (rows=rows, long=s.long, short=s.short)
    end
    println("height check at 8 divisions")
    prev = nothing
    for rows in (8, 16)
        s = shares(8, rows)
        println(lpad(8, 3), "  ", lpad(rows, 4), "  ", lpad(s.nshell, 6), "  ",
                round(s.long; digits=4), "  ", round(s.short; digits=4), "  ",
                round(s.columns; digits=4), "  ",
                round(s.long + s.short + s.columns; digits=4), "  ", s.passed)
        if prev !== nothing
            println("      Δlong ", round(s.long - prev.long; digits=4),
                    "  Δshort ", round(s.short - prev.short; digits=4))
        end
        prev = (long=s.long, short=s.short)
    end
    return nothing
end

main()
