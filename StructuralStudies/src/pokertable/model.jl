# Mixed Asap model: plywood/walnut shell top + axial aluminum chassis.

using Asap
using Unitful
using LinearAlgebra: norm

# Piano hinge along +Y (table width): tie u,v,w and θx,θz; release θy.
const HINGE_RELEASE = (false, false, false, false, true, false)

function _axial(n1, n2, sec, id)
    return Asap.Element(n1, n2, sec, id; release = :freefree)
end

# Welded X / king-post chassis. Pin-ended legs leave a sway mechanism once
# the removable end modules are off (dining).
function _welded(n1, n2, sec, id)
    return Asap.Element(n1, n2, sec, id; release = :fixedfixed)
end

function _xy_inch(node)
    return (ustrip(u"inch", node.position[1]), ustrip(u"inch", node.position[2]))
end

# Asap.Model copies the supplied node list as-is; a repeated Node object
# gets two DOF slots and only the last globalID, so the first six free
# DOFs have no stiffness and LU is singular.
function _unique_nodes(nodes)
    seen = Set{UInt64}()
    out = Asap.Node[]
    for n in nodes
        id = objectid(n)
        id in seen && continue
        push!(seen, id)
        push!(out, n)
    end
    return out
end

function _near_x(nodes, x_in; tol = 0.45)
    return filter(n -> abs(_xy_inch(n)[1] - x_in) < tol, nodes)
end

function _closest_on_hinge(nodes, x_hinge, y; x_tol = 0.35, y_tol = 0.35)
    best = nothing
    best_d = Inf
    for n in nodes
        x, yn = _xy_inch(n)
        abs(x - x_hinge) > x_tol && continue
        d = hypot(x - x_hinge, yn - y)
        if d < best_d
            best_d = d
            best = n
        end
    end
    return best_d <= hypot(x_tol, y_tol) ? best : nothing
end

# Pair only the designed hinge stations. Independently meshed Steiner
# points do not line up; zipping them with RigidLinks fights itself.
function pair_hinge_links(core_nodes, leaf_nodes, x_hinge, stations_y)
    links = Asap.RigidLink[]
    used = Set{UInt64}()
    for y in stations_y
        ln = _closest_on_hinge(leaf_nodes, x_hinge, y)
        cn = _closest_on_hinge(core_nodes, x_hinge, y)
        (ln === nothing || cn === nothing) && continue
        objectid(cn) in used && continue
        push!(used, objectid(cn))
        push!(links, Asap.RigidLink(cn, ln; release = HINGE_RELEASE, id = :hinge))
    end
    return links
end

function pick_rail_nodes(nodes, g::TableGeom; n = 10)
    # Ten roughly equally spaced nodes on the outer poker outline.
    hw = half_width(g)
    hc = half_core(g)
    a = leaf_depth(g)
    targets = Tuple{Float64,Float64}[]
    # long sides: 3 each, ends: 2 each
    for x in (-hc * 0.5, 0.0, hc * 0.5)
        push!(targets, (x, hw), (x, -hw))
    end
    push!(targets, (hc + a, 0.0), (-hc - a, 0.0))
    chosen = Asap.Node[]
    used = Set{UInt64}()
    for (tx, ty) in targets
        best = nothing
        best_d = Inf
        for n in nodes
            objectid(n) in used && continue
            x, y = _xy_inch(n)
            d = hypot(x - tx, y - ty)
            if d < best_d
                best_d = d
                best = n
            end
        end
        if best !== nothing
            push!(used, objectid(best))
            push!(chosen, best)
        end
    end
    return chosen
end

function build_aluminum!(g::TableGeom, base)
    frames = Asap.FrameElement[]
    for (A, F) in zip(base.A, base.F)
        push!(frames, _welded(F, A, SEC_LEG, :leg))
    end
    for A in base.A
        push!(frames, _welded(A, base.C, SEC_SPIDER, :spider))
        push!(frames, _welded(A, base.K, SEC_ROD, :rod))
    end
    push!(frames, _welded(base.C, base.K, SEC_KING, :king))
    for ch in base.chords
        for i in 1:(length(ch) - 1)
            push!(frames, _welded(ch[i], ch[i + 1], SEC_RAIL, :chord))
        end
    end
    for ch in base.spreaders
        for i in 1:(length(ch) - 1)
            push!(frames, _welded(ch[i], ch[i + 1], SEC_RAIL, :spreader))
        end
    end
    if g.leaf_support === :struts
        for (i, S) in enumerate(base.S)
            end_idx = i == 1 ? (1:2) : (3:4)
            for A in base.A[end_idx]
                push!(frames, _axial(A, S, SEC_MODULE, :upper))
            end
            for F in base.F[end_idx]
                push!(frames, _axial(F, S, SEC_MODULE, :lower))
            end
        end
    elseif g.leaf_support === :endleg
        for (i, S) in enumerate(base.S)
            end_idx = i == 1 ? (1:2) : (3:4)
            for A in base.A[end_idx]
                push!(frames, _axial(A, S, SEC_MODULE, :upper))
            end
            push!(frames, _axial(base.E[i], S, SEC_MODULE, :endleg))
        end
    end
    return frames
end

function mesh_top(g::TableGeom, base; deploy_leaves::Bool)
    core_corners = core_boundary_nodes(g)
    core_interior = vcat(base.A, base.ring)
    core_shells = Asap.Shell(core_corners, WOOD_SECTION;
        interior_nodes = core_interior,
        edge_support_type = :free,
        target_edge_length = g.mesh_edge,
        id = :core,
    )
    leaf_shells = Asap.ShellTri3[]
    leaf_nodes = Asap.Node[]
    links = Asap.RigidLink[]
    if deploy_leaves
        for (side, S) in zip((-1, +1), base.S)
            corners = leaf_boundary_nodes(g, side)
            shells = Asap.Shell(corners, WOOD_SECTION;
                interior_nodes = [S],
                edge_support_type = :free,
                target_edge_length = g.mesh_edge,
                id = side > 0 ? :leaf_p : :leaf_m,
            )
            append!(leaf_shells, shells)
            append!(leaf_nodes, Asap.get_nodes(shells))
            append!(links, pair_hinge_links(
                Asap.get_nodes(core_shells),
                Asap.get_nodes(shells),
                side * half_core(g),
                hinge_ys(g),
            ))
        end
    end
    shells = vcat(core_shells, leaf_shells)
    return (; core_shells, leaf_shells, shells, links, core_nodes = Asap.get_nodes(core_shells), leaf_nodes)
end

"""
    solve_table(g; state=:poker, case=:DL_edge)

`state` is `:poker` or `:dining`. `case` is `:D` (self-weight only) or
`:DL_edge` (self-weight + 250 lbf on the +x leaf / dining edge).
"""
function solve_table(g::TableGeom = TableGeom(); state::Symbol = :poker, case::Symbol = :DL_edge)
    deploy = state === :poker
    base = base_nodes(g)
    frames = build_aluminum!(g, base)
    if !deploy
        # Dining / bare conversion: no end modules.
        frames = filter(el -> el.id ∉ (:upper, :lower, :endleg), frames)
    end
    top = mesh_top(g, base; deploy_leaves = deploy)

    seed_nodes = Asap.Node[]
    append!(seed_nodes, base.A, base.F, base.ring, [base.C, base.K])
    deploy && append!(seed_nodes, base.S, base.E)
    append!(seed_nodes, top.core_nodes, top.leaf_nodes)

    loads = Asap.AbstractLoad[]
    append!(loads, frame_selfweight_loads(frames))
    append!(loads, shell_selfweight_loads(top.shells))
    if case === :DL_edge
        if deploy
            push!(loads, edge_patch_load(base.S[2]))
            rail = pick_rail_nodes(vcat(top.core_nodes, top.leaf_nodes), g)
            append!(loads, poker_rail_loads(rail))
        else
            # Dining accidental load at the +x core edge, centerline.
            edge = let
                hc = half_core(g)
                cands = _near_x(top.core_nodes, hc)
                isempty(cands) && error("no core edge node at x=$(hc)")
                argmin(n -> abs(_xy_inch(n)[2]), cands)
            end
            push!(loads, edge_patch_load(edge))
        end
    elseif case !== :D
        error("unknown load case $case")
    end

    model = Asap.Model(_unique_nodes(seed_nodes), frames, top.shells, loads)
    Asap.solve!(model, top.links; reprocess = true)
    Asap.reactions!(model)

    return (; model, g, state, case, base, frames, top, loads)
end

function aluminum_mass_lb(frames)
    mass = 0.0u"kg"
    for el in frames
        L = norm(ustrip.(u"m", el.nodeEnd.position .- el.nodeStart.position)) * u"m"
        mass += el.section.ρ * el.section.A * L
    end
    return uconvert(u"lb", mass)
end

function wood_plan_area(g::TableGeom; deploy::Bool)
    A = g.core_length * g.width
    deploy && (A += π * leaf_depth(g) * half_width(g))
    return A * u"inch^2"
end

function wood_mass_lb(g::TableGeom; deploy::Bool)
    return uconvert(u"lb", WOOD_RHO * WOOD_T * wood_plan_area(g; deploy))
end
