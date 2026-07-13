# ==============================================================================
# Lateral System — FEM Evaluator (Asap vertical wall shells + diaphragms)
# ==============================================================================
# Plan S3. The high-fidelity tier of the `AbstractLateralEvaluator` interface,
# used ONLY to validate the near-optimal layouts the reduced evaluator selects
# (never in the optimizer inner loop). Unlike the reduced shear-building model,
# the FEM assembles continuous vertical wall shells, so flexural coupling across
# stories, skew walls, and torsion all fall out of the assembly directly.
#
# Assembly (all against verified Asap API):
#   - Each `WallPanel` is meshed into `ShellTri3` membrane+bending triangles on
#     SHARED `Asap.Node` objects (nodes are reused between stacked stories and
#     across panels by plan/elevation identity, so walls are continuous).
#   - Base nodes are fully fixed (cantilever wall base).
#   - Each floor gets a stiff, (near-)massless diaphragm shell (fan-triangulated
#     over that floor's wall nodes + a centroid master node) → in-plane rigid.
#   - Story lateral loads are `Asap.NodeForce`s at the floor master nodes.
#   - `Asap.solve!` (linear static), then drift from master-node displacements
#     and per-wall shear from `Asap.ShellInternalForces(...).Nxy`.
#
# The reduced `ReducedDiaphragmEvaluator` is the known-answer oracle: on a
# symmetric core the two tiers must agree on drift (see test/walls). FEM per-wall
# shear recovery integrates the local membrane shear flow and is a first-cut
# cross-checked against the reduced model (flagged where approximate).

using LinearAlgebra
using Unitful

"""
    FEMLateralEvaluator

High-fidelity Asap-shell lateral evaluator (plan S3). Same interface as
[`ReducedDiaphragmEvaluator`](@ref); intended for validating survivors.

# Fields
- `story_heights::Vector{Float64}`: story heights [m]
- `story_elevations::Vector{Float64}`: floor elevations [m], `length = nstory+1`,
  `[0, h1, h1+h2, …]`. Derived from `story_heights` if left empty.
- `mesh_div::Int`: shell columns per wall panel along its length (≥1)
- `diaphragm_E::Float64`: in-plane modulus of the stiff diaphragm shells [Pa]
- `diaphragm_t::Float64`: diaphragm shell thickness [m]
- `plan_halfwidth::NTuple{2,Float64}`: half plan extent for the torsion metric
"""
Base.@kwdef struct FEMLateralEvaluator <: AbstractLateralEvaluator
    story_heights::Vector{Float64}
    story_elevations::Vector{Float64} = Float64[]
    mesh_div::Int = 2
    diaphragm_E::Float64 = 1.0e12
    diaphragm_t::Float64 = 0.05
    plan_halfwidth::NTuple{2,Float64} = (0.0, 0.0)
end

"""
    WallPanel

Geometry of one story-tall wall panel for FE meshing (bare SI): a vertical
rectangle from plan `(x1,y1)` to `(x2,y2)` spanning `[z_bot, z_top]`, thickness
`t`, concrete `E`, `ν`.
"""
struct WallPanel
    id::Int
    x1::Float64; y1::Float64
    x2::Float64; y2::Float64
    z_bot::Float64; z_top::Float64
    t::Float64
    E::Float64
    ν::Float64
    story::Int
end

_panel_edge_length(p::WallPanel) = sqrt((p.x2 - p.x1)^2 + (p.y2 - p.y1)^2)
_planpoint(p::WallPanel, s::Real) = (p.x1 + (p.x2 - p.x1) * s, p.y1 + (p.y2 - p.y1) * s)

"""Story floor elevations `[0, h1, h1+h2, …]` (uses `story_elevations` if given)."""
function _elevations(ev::FEMLateralEvaluator)
    isempty(ev.story_elevations) || return ev.story_elevations
    z = zeros(length(ev.story_heights) + 1)
    for i in eachindex(ev.story_heights)
        z[i+1] = z[i] + ev.story_heights[i]
    end
    return z
end

"""Integer key (mm resolution) for sharing coincident `Node`s by identity."""
@inline _nkey(x, y, z) = (round(Int, x * 1000), round(Int, y * 1000), round(Int, z * 1000))

# ------------------------------------------------------------------------------
# Model assembly
# ------------------------------------------------------------------------------

"""
    _build_asap_wall_model(ev, panels, loads)
      -> (model, floor_master, panel_shells)

Assemble the mixed shell model. Returns the solved-ready `Asap.Model`, a
`Dict{Int,Node}` mapping story → floor master node (load/drift point), and a
`Dict{Int,Vector{ShellTri3}}` mapping panel id → its wall shell elements.
"""
function _build_asap_wall_model(ev::FEMLateralEvaluator,
                                panels::Vector{WallPanel},
                                loads::Vector{StoryLoad})
    isempty(panels) && error("FEMLateralEvaluator: no wall panels supplied")
    nx = max(ev.mesh_div, 1)
    z_base = minimum(p.z_bot for p in panels)

    nodes_by_key = Dict{NTuple{3,Int},Asap.Node}()
    all_nodes = Asap.Node[]

    function get_node!(x, y, z)
        k = _nkey(x, y, z)
        haskey(nodes_by_key, k) && return nodes_by_key[k]
        fixity = isapprox(z, z_base; atol=1e-6) ? :fixed : :free
        nd = Asap.Node([x, y, z] .* u"m", fixity, :wall)
        nodes_by_key[k] = nd
        push!(all_nodes, nd)
        return nd
    end

    wall_shells = Asap.ShellTri3[]
    panel_shells = Dict{Int,Vector{Asap.ShellTri3}}()

    # --- mesh each wall panel (nx columns × 1 row of quads → 2 triangles each) ---
    for p in panels
        sec_t = p.t * u"m"; sec_E = p.E * u"Pa"
        shells_p = Asap.ShellTri3[]
        for c in 0:(nx-1)
            s0 = c / nx; s1 = (c + 1) / nx
            (x0, y0) = _planpoint(p, s0); (x1, y1) = _planpoint(p, s1)
            nb0 = get_node!(x0, y0, p.z_bot)   # bottom-left
            nb1 = get_node!(x1, y1, p.z_bot)   # bottom-right
            nt1 = get_node!(x1, y1, p.z_top)   # top-right
            nt0 = get_node!(x0, y0, p.z_top)   # top-left
            t1 = Asap.ShellTri3((nb0, nb1, nt1), sec_t, sec_E, p.ν; id=:wall)
            t2 = Asap.ShellTri3((nb0, nt1, nt0), sec_t, sec_E, p.ν; id=:wall)
            push!(shells_p, t1); push!(shells_p, t2)
        end
        append!(wall_shells, shells_p)
        panel_shells[p.id] = shells_p
    end

    # --- per-floor stiff diaphragm (fan triangulation) + master node ---
    elevs = _elevations(ev)
    floor_master = Dict{Int,Asap.Node}()
    diaphragm_shells = Asap.ShellTri3[]
    dia_t = ev.diaphragm_t * u"m"; dia_E = ev.diaphragm_E * u"Pa"
    nstory = length(ev.story_heights)
    for s in 1:nstory
        zf = elevs[s+1]
        # wall nodes at this floor elevation
        fnodes = [nd for nd in all_nodes if isapprox(ustrip(u"m", nd.position[3]), zf; atol=1e-6)]
        length(fnodes) < 1 && continue
        cx = sum(ustrip(u"m", nd.position[1]) for nd in fnodes) / length(fnodes)
        cy = sum(ustrip(u"m", nd.position[2]) for nd in fnodes) / length(fnodes)
        master = get_node!(cx, cy, zf)
        floor_master[s] = master
        # fan triangles centroid→consecutive nodes sorted by plan angle
        others = [nd for nd in fnodes if nd !== master]
        if length(others) >= 2
            sort!(others; by = nd -> atan(ustrip(u"m", nd.position[2]) - cy,
                                          ustrip(u"m", nd.position[1]) - cx))
            for i in eachindex(others)
                a = others[i]; b = others[mod1(i + 1, length(others))]
                # skip near-degenerate (collinear) triangles
                ax = ustrip(u"m", a.position[1]) - cx; ay = ustrip(u"m", a.position[2]) - cy
                bx = ustrip(u"m", b.position[1]) - cx; by = ustrip(u"m", b.position[2]) - cy
                abs(ax * by - ay * bx) < 1e-6 && continue
                push!(diaphragm_shells, Asap.ShellTri3((master, a, b), dia_t, dia_E, 0.2; id=:diaphragm))
            end
        end
    end

    # --- story lateral loads at floor masters (accidental ecc → torsion moment) ---
    asap_loads = Asap.NodeForce[]
    for ld in loads
        haskey(floor_master, ld.story) || continue
        m = floor_master[ld.story]
        push!(asap_loads, Asap.NodeForce(m, [ld.Fx, ld.Fy, 0.0] .* u"N"))
    end

    shells = vcat(wall_shells, diaphragm_shells)
    model = Asap.Model(all_nodes, shells, asap_loads)
    Asap.process!(model)
    return model, floor_master, panel_shells, nodes_by_key, z_base
end

# ------------------------------------------------------------------------------
# evaluate_lateral
# ------------------------------------------------------------------------------

function evaluate_lateral(ev::FEMLateralEvaluator,
                          panels::Vector{WallPanel},
                          loads::Vector{StoryLoad})
    model, floor_master, panel_shells, nodes_by_key, z_base =
        _build_asap_wall_model(ev, panels, loads)
    Asap.solve!(model)
    nx = max(ev.mesh_div, 1)

    nstory = length(ev.story_heights)
    story_disp = zeros(nstory, 3)
    drift = zeros(nstory)
    torsion = ones(nstory)
    wall_forces = Dict{Int,Float64}(p.id => 0.0 for p in panels)

    # master-node in-plane displacement per floor: u = [ux, uy, θz]
    master_u = zeros(nstory, 3)
    for s in 1:nstory
        haskey(floor_master, s) || continue
        gid = floor_master[s].globalID
        master_u[s, 1] = model.u[gid[1]]
        master_u[s, 2] = model.u[gid[2]]
        master_u[s, 3] = model.u[gid[6]]   # drilling / θz
    end

    for s in 1:nstory
        story_disp[s, :] .= master_u[s, :]
        u_below = s == 1 ? zeros(3) : master_u[s-1, :]
        h = ev.story_heights[s]
        dδ = sqrt((master_u[s,1] - u_below[1])^2 + (master_u[s,2] - u_below[2])^2)
        drift[s] = h > 0 ? dδ / h : 0.0
        torsion[s] = _torsion_amplification(master_u[s, :], ev.plan_halfwidth)
    end

    # Per-wall in-plane shear demand.
    #   Base-story panels: recovered EXACTLY from nodal base reactions (horizontal
    #     equilibrium), projected onto the wall's in-plane axis.
    #   Upper-story panels: approximated by integrating the local membrane shear
    #     flow Nxy over the panel width (cross-checked against the reduced model;
    #     centroid recovery is a first-cut and undercounts squat piers).
    for p in panels
        lw = _panel_edge_length(p)
        ux = (p.x2 - p.x1) / lw; uy = (p.y2 - p.y1) / lw   # wall axis unit vector
        if isapprox(p.z_bot, z_base; atol=1e-6)
            Rx = 0.0; Ry = 0.0
            for c in 0:nx
                (bx, by) = _planpoint(p, c / nx)
                nd = get(nodes_by_key, _nkey(bx, by, p.z_bot), nothing)
                nd === nothing && continue
                Rx += ustrip(u"N", nd.reaction[1])
                Ry += ustrip(u"N", nd.reaction[2])
            end
            wall_forces[p.id] = abs(Rx * ux + Ry * uy)
        else
            shells_p = get(panel_shells, p.id, Asap.ShellTri3[])
            isempty(shells_p) && continue
            colw = lw / nx
            Nxy_sum = sum(Asap.ShellInternalForces(el, model.u).Nxy for el in shells_p)
            wall_forces[p.id] = abs(Nxy_sum / 2 * colw)
        end
    end

    return LateralResult(story_disp, drift, wall_forces, torsion)
end

# ------------------------------------------------------------------------------
# Bridge: reduced-model WallLine → FE WallPanel
# ------------------------------------------------------------------------------

"""
    walls_to_panels(walls, story_elevations, thickness_of, length_of, E, ν) -> Vector{WallPanel}

Build FE `WallPanel`s from the reduced-model `WallLine`s. `thickness_of(id)` and
`length_of(id)` return the wall thickness/length [m]; `story_elevations` gives
floor levels [m] (`length = nstory+1`). Wall endpoints are recovered from the
`WallLine` plan center + orientation `θ` and length.
"""
function walls_to_panels(walls::Vector{WallLine},
                         story_elevations::Vector{Float64},
                         thickness_of::Function,
                         length_of::Function,
                         E::Float64, ν::Float64)
    panels = WallPanel[]
    for w in walls
        lw = length_of(w.id); half = lw / 2
        dx = cos(w.θ) * half; dy = sin(w.θ) * half
        z_bot = story_elevations[w.story]
        z_top = story_elevations[w.story + 1]
        push!(panels, WallPanel(w.id, w.x - dx, w.y - dy, w.x + dx, w.y + dy,
                                z_bot, z_top, thickness_of(w.id), E, ν, w.story))
    end
    return panels
end
