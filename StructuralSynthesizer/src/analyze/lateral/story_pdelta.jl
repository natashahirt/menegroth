# ==============================================================================
# Story geometric stiffness on the rigid-diaphragm masters
# ==============================================================================
#
# Wilson & Habibullah (1987), "Static and Dynamic Analysis of Multi-Story
# Buildings, Including P-Delta Effects", Earthquake Spectra 3(2) (corpus:
# wilson-habibullah-1987-pdelta). The story couple of a vertical force P over
# a story of height h is (P/h)[1 −1; −1 1] on the story drift (Eq. 7, PDF
# p. 6). The solve is on K* = K − L (Eq. 2, PDF p. 5), so the matrix built
# here is signed: compression gives a negative term.
#
# The paper's 3D form puts each level's weight at its centroid with a
# torsion term w r²/h from the floor's radius of gyration (Eqs. 11–12, PDF
# p. 8; the printed Eq. 12 shows "r" where Eq. 11, Eq. 17, and the units
# require r²), then moves it to each level's centroid (Eqs. 13–14, PDF
# pp. 9–10). This file uses the paper's "more exact form", Σ p_m r_m², from
# the vertical forces of the members that cross the story (PDF p. 8). Each
# force is placed through the rigid-floor kinematics of both masters, which
# carries the Eq. 13 transformation without a separate step:
#
#   drift_x = (u_xT − (y − y_T) θ_T) − (u_xB − (y − y_B) θ_B)
#   drift_y = (u_yT + (x − x_T) θ_T) − (u_yB + (x − x_B) θ_B)
#   K_G    −= (P/h) (a_x a_xᵀ + a_y a_yᵀ)
#
# The forces come from the displacement the caller passes. For a strength
# combination that is the factored gravity of that combination. The lateral
# loads do not change the story total (PDF p. 6), so the matrix is not
# iterated. Beam-column (P-δ) effects inside a member are not included
# (PDF p. 6).

"""
Vertical forces through one story, and the masters it spans.

`points` holds `(x, y, P)` in metres and newtons, one entry per node of a
member that crosses the bottom cut. `P > 0` is compression. A wall node is
listed once per triangle that touches it; the shares add.
`master_bottom === nothing` is a base that is fixed in plan.
"""
struct StoryAxialProfile
    z_bottom_m::Float64
    z_top_m::Float64
    master_top::Asap.Node
    master_bottom::Union{Nothing, Asap.Node}
    points::Vector{NTuple{3, Float64}}
end

"""Total vertical force through the story [N]. Compression is positive."""
story_axial_total(p::StoryAxialProfile) = sum(pt[3] for pt in p.points; init=0.0)

"""
    story_geometric_stiffness(model, profiles) -> SparseMatrixCSC

Signed `nDOFs × nDOFs` story geometric stiffness on the master DOFs. Pass it
to `Asap.solve(model, cases, links; geometric_stiffness=K_G)`.

Only the master `u_x`, `u_y`, and `θ_z` DOFs receive terms. A base master of
`nothing` contributes no DOFs: the story bottom does not move in plan.
"""
function story_geometric_stiffness(model, profiles::AbstractVector{StoryAxialProfile})
    n = model.nDOFs
    Is = Int[]; Js = Int[]; Vs = Float64[]
    for prof in profiles
        h = prof.z_top_m - prof.z_bottom_m
        h > 0 || throw(ArgumentError(
            "story_geometric_stiffness: story from $(prof.z_bottom_m) m to " *
            "$(prof.z_top_m) m has no height."))
        top = _pdelta_master_dofs(prof.master_top)
        bot = prof.master_bottom === nothing ? nothing :
              _pdelta_master_dofs(prof.master_bottom)
        for (x, y, P) in prof.points
            P == 0.0 && continue
            c = -P / h
            ax = Tuple{Int, Float64}[(top.gx, 1.0), (top.gθ, -(y - top.y))]
            ay = Tuple{Int, Float64}[(top.gy, 1.0), (top.gθ, x - top.x)]
            if bot !== nothing
                push!(ax, (bot.gx, -1.0), (bot.gθ, y - bot.y))
                push!(ay, (bot.gy, -1.0), (bot.gθ, -(x - bot.x)))
            end
            for a in (ax, ay), (i, ai) in a, (j, aj) in a
                push!(Is, i); push!(Js, j); push!(Vs, c * ai * aj)
            end
        end
    end
    return sparse(Is, Js, Vs, n, n)
end

"""
    story_axial_profiles(model, u, mesh, masters, base_z_m; loads=nothing) -> Vector{StoryAxialProfile}

Vertical member forces through each story from the full displacement `u`.

`masters` pairs each floor elevation [m] with its rigid-diaphragm master.
The story under a master runs from the next master below, or from
`base_z_m` for the lowest one. The base must be fixed in `u_x` and `u_y` at
every member node on it.

The cut is the one `check_story_cut_equilibrium` sums: pier triangles whose
bottom is on the elevation and frame members with one node on it and the
other above. Pass `loads` when `u` is not the load set last processed, so
frame fixed-end forces come from that case.
"""
function story_axial_profiles(model, u::AbstractVector{<:Real}, mesh::WallMesh,
                              masters::AbstractVector{<:Tuple{Real, Asap.Node}},
                              base_z_m::Real; loads=nothing)
    isempty(masters) && throw(ArgumentError(
        "story_axial_profiles: no rigid-diaphragm masters were given."))
    sorted = sort(collect(masters); by=first)
    zbase = Float64(base_z_m)
    Float64(first(sorted)[1]) > zbase + WALL_CUT_ZTOL_M || throw(ArgumentError(
        "story_axial_profiles: the lowest master at $(first(sorted)[1]) m is not above " *
        "the base at $(zbase) m."))
    _require_fixed_base_in_plan(model, mesh, zbase)
    qmap = loads === nothing ? nothing : _fixed_end_by_element(loads)
    profiles = StoryAxialProfile[]
    for (k, (ztop, mtop)) in enumerate(sorted)
        zbot, mbot = k == 1 ? (zbase, nothing) : (Float64(sorted[k - 1][1]), sorted[k - 1][2])
        contrib = _story_cut_contributions(model, u, mesh, zbot; qmap=qmap)
        isempty(contrib) && throw(ArgumentError(
            "story_axial_profiles: no wall or frame member crosses z = $(zbot) m."))
        pts = NTuple{3, Float64}[(c.x, c.y, -c.fz) for c in contrib]
        push!(profiles, StoryAxialProfile(zbot, Float64(ztop), mtop, mbot, pts))
    end
    return profiles
end

# ------------------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------------------

function _pdelta_master_dofs(node::Asap.Node)
    gid = node.globalID
    (length(gid) == 6 && all(>(0), gid)) || throw(ArgumentError(
        "story geometric stiffness: master DOFs are not assigned. process! the model first."))
    x, y, _ = _node_xyz(node)
    return (gx=gid[1], gy=gid[2], gθ=gid[6], x=x, y=y)
end

function _story_cut_contributions(model, u, mesh::WallMesh, z::Float64; qmap=nothing)
    contrib = NamedTuple{(:x, :y, :z, :fx, :fy, :fz, :mx, :my, :mz),
                         NTuple{9, Float64}}[]
    for pier in mesh.piers
        isempty(pier.shells) && continue
        abs(_pier_bottom(pier) - z) <= WALL_CUT_ZTOL_M || continue
        append!(contrib, _cut_contributions(pier.shells, u, z; qmap=qmap))
    end
    append!(contrib, _frame_cut_contributions(model, u, z; qmap=qmap))
    return contrib
end

"""Throw when a member node on the base can translate in plan."""
function _require_fixed_base_in_plan(model, mesh::WallMesh, z::Float64)
    function check(nd)
        abs(_node_xyz(nd)[3] - z) <= WALL_CUT_ZTOL_M || return nothing
        (nd.dof[1] || nd.dof[2]) && throw(ArgumentError(
            "story_axial_profiles: a member node at the base z = $(z) m is free in plan. " *
            "The lowest story is taken with a base that does not move; give the base a " *
            "master or fix it."))
        return nothing
    end
    for pier in mesh.piers, sh in pier.shells, nd in sh.nodes
        check(nd)
    end
    for el in _frame_elements(model)
        check(el.nodeStart)
        check(el.nodeEnd)
    end
    return nothing
end
