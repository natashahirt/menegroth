# =============================================================================
# Diaphragm Shell Creation (uses Asap.Shell meshing)
# =============================================================================

# Phase 8 (plan joists-roles-materials) — the slab FEA mesh must respect the
# interior framing (joist) lines. Each auto-generated `role===:joist` Beam is
# projected to an interior polyline that Asap's constrained-Delaunay mesher
# (`Asap.Shell(...; interior_constrained_lines=...)`, external/Asap Phase A3)
# turns into aligned triangle edges, and the joist's landing `Node` objects are
# handed back as `interior_nodes` so the shell mesh and the frame `Element`s
# share the exact same `Node` (true DOF sharing after `process!`).

"""One joist projected into a slab's plane for the diaphragm mesher.

- `polyline`  : ordered `(x, y)` vertices (metres) → `interior_constrained_lines`.
- `node_objs` : the actual frame `Asap.Node`s at the joist's landing/interior
  vertices → `interior_nodes` (same objects, reused, for DOF sharing).
- `refine_nodes` : throwaway sample `Node`s along the span → `refinement_targets`.
- `midpoint`  : `(x, y)` at half arclength, used to assign the joist to a face.
"""
struct _DiaphragmJoistLine
    polyline::Vector{NTuple{2, Float64}}
    node_objs::Vector{Asap.Node}
    refine_nodes::Vector{Asap.Node}
    midpoint::NTuple{2, Float64}
end

"""Ordered skeleton-vertex chain of a (possibly multi-segment) joist `beam`.

Walks the beam's `segment_indices` → `edge_idx` → `skel.edge_indices` pairs into
a single path. Single-segment joists (the common case after Phase 5's host
`edge_chains` subdivision) return `[v1, v2]` directly."""
function _joist_vertex_chain(struc::BuildingStructure, beam::Beam)
    skel = struc.skeleton
    n_edges = length(skel.edge_indices)
    pairs = Tuple{Int, Int}[]
    for si in segment_indices(beam)
        (1 <= si <= length(struc.segments)) || continue
        e = struc.segments[si].edge_idx
        (1 <= e <= n_edges) || continue
        push!(pairs, skel.edge_indices[e])
    end
    isempty(pairs) && return Int[]
    length(pairs) == 1 && return Int[pairs[1][1], pairs[1][2]]

    adj = Dict{Int, Vector{Int}}()
    for (a, b) in pairs
        push!(get!(Vector{Int}, adj, a), b)
        push!(get!(Vector{Int}, adj, b), a)
    end
    endpoints = sort!(Int[v for (v, ns) in adj if length(ns) == 1])
    start = isempty(endpoints) ? minimum(keys(adj)) : first(endpoints)
    ordered = Int[start]
    prev = 0
    cur = start
    for _ in 1:length(pairs)
        nxt = 0
        for cand in adj[cur]
            if cand != prev && !(cand in ordered)
                nxt = cand
                break
            end
        end
        nxt == 0 && break
        push!(ordered, nxt)
        prev = cur
        cur = nxt
    end
    return ordered
end

"""`(x, y)` at fractional arclength `f ∈ [0, 1]` along `polyline` (metres)."""
function _point_on_polyline(polyline::Vector{NTuple{2, Float64}}, f::Float64)
    n = length(polyline)
    n == 1 && return polyline[1]
    seglens = Float64[hypot(polyline[i + 1][1] - polyline[i][1],
                            polyline[i + 1][2] - polyline[i][2]) for i in 1:(n - 1)]
    total = sum(seglens)
    total <= 0 && return polyline[1]
    s = clamp(f, 0.0, 1.0) * total
    acc = 0.0
    for i in 1:(n - 1)
        if acc + seglens[i] >= s || i == n - 1
            r = seglens[i] > 0 ? clamp((s - acc) / seglens[i], 0.0, 1.0) : 0.0
            return (polyline[i][1] + r * (polyline[i + 1][1] - polyline[i][1]),
                    polyline[i][2] + r * (polyline[i + 1][2] - polyline[i][2]))
        end
        acc += seglens[i]
    end
    return polyline[end]
end

"""Standard even–odd ray-cast: is `(px, py)` strictly inside polygon `poly`?

Used only on a joist's span midpoint (guaranteed interior to its cell), so the
on-edge degeneracy of the ray-cast test never bites here."""
function _point_in_polygon_xy(px::Float64, py::Float64, poly::Vector{NTuple{2, Float64}})
    inside = false
    n = length(poly)
    j = n
    for i in 1:n
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > py) != (yj > py)) &&
           (px < (xj - xi) * (py - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

"""De-duplicate `Node`s by object identity (joists share landing `Node`s)."""
function _unique_nodes(ns::Vector{Asap.Node})
    seen = Base.IdSet{Asap.Node}()
    out = Asap.Node[]
    for nd in ns
        if !(nd in seen)
            push!(seen, nd)
            push!(out, nd)
        end
    end
    return out
end

"""Collect this slab's joist framing lines as [`_DiaphragmJoistLine`](@ref)s.

Mirrors the Phase 7 `framing_levels → member_groups → role===:joist` traversal
in [`_create_shell_area_loads!`](@ref) (kept byte-for-byte consistent so the
mesh's interior lines and the `AreaLoad.interior_beams` describe the *same*
joists). Polyline vertices use the offset `Asap.Node` positions (not raw
skeleton coords) so the constrained edges coincide exactly with the embedded
`interior_nodes`."""
function _collect_slab_joist_lines(struc::BuildingStructure, slab::Slab,
                                   nodes::Vector{Asap.Node})
    lines = _DiaphragmJoistLine[]
    for fl in slab.framing_levels
        fl.group_id === nothing && continue
        grp = get(struc.member_groups, fl.group_id, nothing)
        grp === nothing && continue
        for mi in grp.member_indices
            (mi >= 1 && mi <= length(struc.beams)) || continue
            beam = struc.beams[mi]
            beam.role === :joist || continue
            vchain = _joist_vertex_chain(struc, beam)
            length(vchain) >= 2 || continue
            all(v -> 1 <= v <= length(nodes), vchain) || continue

            pts = NTuple{2, Float64}[(ustrip(u"m", nodes[v].position[1]),
                                      ustrip(u"m", nodes[v].position[2])) for v in vchain]
            node_objs = Asap.Node[nodes[v] for v in vchain]
            z = ustrip(u"m", nodes[first(vchain)].position[3])

            # ENGINEERING JUDGMENT (FEA discretisation, not a code provision):
            # 3 interior samples per joist span (fractional arclength 1/4, 1/2,
            # 3/4) anchor the mesh grading along the constrained edge without
            # over-refining. Any point in [3, 5] is defensible; 3 is the low end
            # of the requested range because the diaphragm shells are tributary
            # geometry, not a stress-recovery mesh.
            refine_nodes = Asap.Node[
                Asap.Node([_point_on_polyline(pts, k / 4)[1] * u"m",
                           _point_on_polyline(pts, k / 4)[2] * u"m",
                           z * u"m"], :free) for k in 1:3]

            push!(lines, _DiaphragmJoistLine(pts, node_objs, refine_nodes,
                                             _point_on_polyline(pts, 0.5)))
        end
    end
    return lines
end

"""
    create_slab_diaphragm_shells(struc, slab, nodes; E, ν, t_factor) -> Vector{<:Asap.ShellElement}

Create shell elements for a slab's diaphragm action from its cell faces.
Uses Asap.Shell() for automatic triangulation.

Phase 8: when the slab carries auto-generated `role===:joist` framing (Phase 5),
each joist is projected into the slab plane and passed to the mesher as an
`interior_constrained_lines` polyline (so the triangulation has aligned edges
along every joist) plus `interior_nodes` (the actual frame `Node`s reused at the
landings, giving true DOF sharing). Faces with no joists mesh exactly as before.

# Arguments
- `struc`: BuildingStructure containing the slab
- `slab`: Slab object with sizing result
- `nodes`: Vector of Asap.Node (indexed same as skeleton vertices)
- `E`: Young's modulus (default: from slab result material, then NWC_4000)
- `ν`: Poisson's ratio (default: from slab result material, then NWC_4000)
- `t_factor`: Thickness multiplier (default 1.0)

# Returns
Vector of ShellTri3 elements.
"""
function create_slab_diaphragm_shells(struc::BuildingStructure, slab::Slab, nodes::Vector{Asap.Node};
                                       E=nothing, ν::Float64=NWC_4000.ν, t_factor::Float64=1.0)
    skel = struc.skeleton
    
    # Get slab thickness (with optional scaling)
    t = thickness(slab) * t_factor
    
    # Determine E: use provided, or try slab concrete, or default
    if E === nothing
        E = uconvert(u"Pa", NWC_4000.E)  # fallback
        if hasfield(typeof(slab.result), :concrete) && slab.result.concrete !== nothing
            if hasfield(typeof(slab.result.concrete), :E)
                E = slab.result.concrete.E
            end
            if hasfield(typeof(slab.result.concrete), :ν)
                ν = slab.result.concrete.ν
            end
        end
    end
    
    E_pa = uconvert(u"Pa", E)
    
    # Collect face indices for this slab
    face_indices = [struc.cells[ci].face_idx for ci in slab.cell_indices]

    # Phase 8: joist framing lines this slab's diaphragm mesh must respect.
    # Empty ⇒ every face meshes exactly as before (no behavior change).
    joist_lines = _collect_slab_joist_lines(struc, slab, nodes)

    # Create shells from face meshes using Asap.Shell
    shells = Asap.ShellElement[]
    section = Asap.ShellSection(t, E_pa, ν; ρ=0.0u"kg/m^3")  # zero mass for diaphragm
    
    for face_idx in face_indices
        vert_indices = skel.face_vertex_indices[face_idx]
        corners = tuple([nodes[vi] for vi in vert_indices]...)

        # Assign each joist to the face whose polygon contains its span midpoint
        # (a joist spans a single cell, so its midpoint is strictly interior).
        face_poly = NTuple{2, Float64}[(ustrip(u"m", nodes[vi].position[1]),
                                        ustrip(u"m", nodes[vi].position[2]))
                                       for vi in vert_indices]
        face_lines = _DiaphragmJoistLine[jl for jl in joist_lines
                       if _point_in_polygon_xy(jl.midpoint[1], jl.midpoint[2], face_poly)]

        if isempty(face_lines)
            # Use Asap's Shell() for automatic triangulation (n=2 for coarse mesh)
            face_shells = Asap.Shell(corners, section; n=2, id=:diaphragm,
                                     edge_support_type=:free, interior_support_type=:free)
        else
            # Joist lines present → constrained-Delaunay mesh that respects them.
            constrained = Vector{NTuple{2, Float64}}[jl.polyline for jl in face_lines]
            # Reuse the exact frame Node objects at the joist landings (DOF share);
            # dedup because adjacent joists share a landing Node.
            interior_nodes = _unique_nodes(reduce(vcat, (jl.node_objs for jl in face_lines);
                                                  init = Asap.Node[]))
            refine_targets = reduce(vcat, (jl.refine_nodes for jl in face_lines);
                                    init = Asap.Node[])

            # ENGINEERING JUDGMENT (FEA discretisation, not a code provision):
            # refine near the joist lines so triangle quality along the
            # constrained edges stays acceptable. Coarse baseline is kept at the
            # historical n=2; near-joist target edge length = (short face side)/6
            # (~6 elements across the short span near a joist). Grading, not a
            # structural factor — no code clause applies.
            xs = Float64[p[1] for p in face_poly]
            ys = Float64[p[2] for p in face_poly]
            h_near = min(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys)) / 6

            # interior_support_type=:free — the constrained lines impose NO
            # boundary condition; the joist Element itself carries the stiffness,
            # the shell just shares its DOFs (Asap Shell docstring, Phase A3).
            face_shells = Asap.Shell(corners, section; n=2, id=:diaphragm,
                                     edge_support_type=:free,
                                     interior_support_type=:free,
                                     interior_nodes=interior_nodes,
                                     interior_constrained_lines=constrained,
                                     refinement_edge_length=h_near * u"m",
                                     refinement_targets=refine_targets)
        end
        append!(shells, face_shells)
    end
    
    # Assign global DOFs to each shell
    for shell in shells
        Asap.populate_globalID!(shell)
    end
    
    return shells
end

"""
    _build_shell_props(params, mode, explicit_props) -> NamedTuple

Real modulus, Poisson's ratio, and thickness factor for a `:shell` diaphragm.

`E` is `explicit_props.E` when that is set, otherwise `params.diaphragm_E`,
otherwise the concrete modulus from [`resolve_concrete`](@ref). `:rigid` is
not a shell. The in-plane rigid link is the rigid diaphragm, and this
function does not substitute a penalty modulus.
"""
function _build_shell_props(params::DesignParameters, mode::Symbol, explicit_props::Union{Nothing, NamedTuple})
    mode == :shell || throw(ArgumentError(
        "_build_shell_props: mode :$mode is not a semirigid shell. " *
        "A :rigid diaphragm is an in-plane rigid link, not a shell modulus."))
    # Resolve concrete E from materials cascade (user's material choice)
    _mat_conc = resolve_concrete(params)
    concrete_E = uconvert(u"Pa", _mat_conc.E)

    E_default = isnothing(params.diaphragm_E) ? concrete_E : params.diaphragm_E

    ν_default = params.diaphragm_ν
    t_factor = 1.0
    
    # Override with explicit props if provided
    if !isnothing(explicit_props)
        E_default = get(explicit_props, :E, E_default)
        ν_default = get(explicit_props, :ν, ν_default)
        t_factor = get(explicit_props, :t_factor, t_factor)
    end
    
    return (E=E_default, ν=ν_default, t_factor=t_factor)
end

# =============================================================================
# Shell Diaphragm Implementation
# =============================================================================

"""
Create semirigid shell diaphragms for all slabs.

`mode` must be `:shell`. Properties are the real slab modulus (or `props`
from [`_build_shell_props`](@ref)). `:rigid` is rejected: that diaphragm is
an in-plane rigid link, not a shell.
"""
function _create_shell_diaphragms(struc::BuildingStructure, nodes::Vector{Asap.Node};
                                   mode::Symbol=:shell,
                                   props::Union{Nothing, NamedTuple}=nothing)
    mode == :shell || throw(ArgumentError(
        "_create_shell_diaphragms: mode :$mode is not a semirigid shell. " *
        "A :rigid diaphragm is an in-plane rigid link, not a shell."))
    shells = Asap.ShellElement[]

    # Real slab properties. Overridden by `props` when the caller resolved them.
    E_default = uconvert(u"Pa", NWC_4000.E)
    ν_default = NWC_4000.ν
    t_factor = 1.0
    
    # Override with custom properties if provided
    if props !== nothing
        E_default = get(props, :E, E_default)
        ν_default = get(props, :ν, ν_default)
        t_factor = get(props, :t_factor, t_factor)
    end
    
    for slab in struc.slabs
        slab_shells = create_slab_diaphragm_shells(struc, slab, nodes; 
                                                    E=E_default, ν=ν_default, t_factor=t_factor)
        append!(shells, slab_shells)
    end
    
    return shells
end

"""
Free `θz` on nodes that already translate in plan.

The rigid diaphragm ties `(u_x, u_y, θ_z)` only when that DOF is free on
both ends. A node whose `θz` no element restrains keeps it fixed (see
[`_free_restrained_node_rotations!`](@ref)), which would make the link
release `θz` and leave the floor unable to rotate in plan.

Supports (any fixed translation) are left alone. `θx` and `θy` are not changed.
"""
function _free_plan_rotation_for_rigid_diaphragm!(nodes)
    for node in nodes
        dof = node.dof
        length(dof) >= 6 || continue
        if dof[1] && dof[2]
            dof[6] = true
        end
    end
    return nodes
end

"""
    _build_rigid_diaphragm_links(struc, nodes) -> Vector{Asap.RigidLink}

Build the master/slave `Asap.RigidLink` set that enforces a truly rigid
diaphragm at every story (Phase 9b). One master node is elected per story
(lowest skeleton-vertex index for determinism); every other frame node on
that story is rigid-linked to the master.

The tie is applied only to the in-plane rigid-body DOFs of the diaphragm:
`(u_x, u_y, θ_z)`. Out-of-plane DOFs `(u_z, θ_x, θ_y)` remain free so gravity
bending behavior at each node is untouched — this is the standard rigid-
diaphragm kinematic constraint (Bathe *Finite Element Procedures* §4.4; Cook
*Concepts and Applications of Finite Element Analysis* §6.3). `Asap.RigidLink`
release order is `(u_x, u_y, u_z, θ_x, θ_y, θ_z)` with `true = released`.

Story membership is read from `struc.skeleton.stories[k].vertices`
(rebuilt by `rebuild_stories!`). Stories with fewer than two frame nodes
produce no links — a single-node story has no rigid tie to enforce.

The master is one of those frame nodes. It is not a new node. A node tied
only in plan still needs its own `u_z`, `θ_x`, and `θ_y` stiffness;
[`require_diaphragm_node_stiffness`](@ref) refuses the link set when either
end lacks it.

Slave DOFs that are already fixed at their `Asap.Node` (i.e. a support at
that story) are silently skipped by `_build_rigidlink_reduction` with a
warning; this is by design (`external/Asap/src/Elements/rigidlink.jl:132`).
Callers who want the tie to have observable effect must ensure at least
some story vertices are not supports (typical for stories at column tops
above a supported ground level).
"""
function _build_rigid_diaphragm_links(struc::BuildingStructure,
                                      nodes::Vector{Asap.Node})
    links = Asap.RigidLink[]
    skel = struc.skeleton
    # In-plane rigid-body DOFs targeted by the diaphragm tie (Bathe §4.4;
    # Cook §6.3). Order in `Asap.RigidLink.release`:
    # (u_x, u_y, u_z, θ_x, θ_y, θ_z). `release[i] = true` = DOF stays free.
    # The diaphragm-plane DOFs are indices 1 (u_x), 2 (u_y), 6 (θ_z);
    # gravity-plane DOFs 3, 4, 5 always stay free so out-of-plane bending
    # at each node is untouched.
    tied_indices = (1, 2, 6)
    is_free_inplane(v_idx) =
        (1 <= v_idx <= length(nodes)) &&
        length(nodes[v_idx].dof) >= 2 &&
        nodes[v_idx].dof[1] && nodes[v_idx].dof[2]

    for (_, story) in skel.stories
        # A tie is only meaningful between vertices whose in-plane
        # translation DOFs are actually free. Filtering out supports here
        # also suppresses the noisy "slave DOF is a support" warnings from
        # `_build_rigidlink_reduction` (external/Asap/src/Elements/rigidlink.jl:132).
        free_verts = sort([v for v in story.vertices if is_free_inplane(v)])
        length(free_verts) >= 2 || continue
        master_idx = first(free_verts)
        master = nodes[master_idx]
        for slave_idx in Iterators.drop(free_verts, 1)
            slave = nodes[slave_idx]
            slave === master && continue    # defensive; never true after filter
            # Per-link release: tie a target DOF only when it is free on BOTH
            # master AND slave. The rigid path frees θz first
            # (`_free_plan_rotation_for_rigid_diaphragm!`); a DOF that is
            # still fixed is released here rather than tied into a support.
            # u_z / θ_x / θ_y are always released — they carry gravity/bending.
            release = ntuple(6) do i
                (i in tied_indices) || return true       # gravity/bending
                # Tie only if both endpoints have this DOF free.
                (master.dof[i] && slave.dof[i]) ? false : true
            end
            push!(links, Asap.RigidLink(master, slave;
                                        release = release,
                                        id = :rigid_diaphragm))
        end
    end
    return links
end
