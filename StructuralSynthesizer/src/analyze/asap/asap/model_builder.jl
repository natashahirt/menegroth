"""Fix every skeleton node that no frame element, shell, or rigid link uses."""
function _fix_unconnected_nodes!(nodes, frame_elements, shell_elements, rigid_links)
    used = Set{UInt64}()
    for el in frame_elements
        el isa Asap.Element || continue
        push!(used, objectid(el.nodeStart), objectid(el.nodeEnd))
    end
    for sh in shell_elements, nd in sh.nodes
        push!(used, objectid(nd))
    end
    for link in rigid_links
        push!(used, objectid(link.nodeA), objectid(link.nodeB))
    end
    for nd in nodes
        objectid(nd) in used && continue
        nd.dof .= false
    end
    return nodes
end

"""
    _create_offset_nodes(skel, col_offset_by_vertex, support_set) -> Vector{Asap.Node}

Create Asap nodes from skeleton vertices, applying structural offsets for edge/corner columns.
Shared by `to_asap!` and `build_analysis_model!`. Supports are fully fixed.
Other nodes start with rotations fixed; [`_free_restrained_node_rotations!`](@ref)
frees them once the elements exist.
"""
function _create_offset_nodes(skel::BuildingSkeleton, col_offset_by_vertex, support_set::Set{Int})
    vc = skel.geometry.vertex_coords
    n_verts = length(skel.vertices)
    nodes = Vector{Asap.Node}(undef, n_verts)
    @inbounds for v_idx in 1:n_verts
        off = get(col_offset_by_vertex, v_idx, nothing)
        x = (vc[v_idx, 1] + (isnothing(off) ? 0.0 : off[1])) * u"m"
        y = (vc[v_idx, 2] + (isnothing(off) ? 0.0 : off[2])) * u"m"
        z = vc[v_idx, 3] * u"m"
        dofs = v_idx in support_set ? [false, false, false, false, false, false] : [true, true, true, false, false, false]
        nodes[v_idx] = Asap.Node([x, y, z], dofs)
    end
    return nodes
end

"""
    _free_restrained_node_rotations!(nodes, frame_elements, shell_elements) -> nodes

Free the rotational DOFs of every non-support node that some element
restrains, so beam end moments reach the columns and the frame sways with
its real stiffness.

A node on a shell frees all three rotations. Otherwise a rotation is
freed only when the elements at that node couple it to a translation or
to a support. A positive diagonal is not enough: interior pieces of a
subdivided member are bending-continuous, so they carry torsion between
landing nodes, but a bending release at the member end drops torsion on
the end piece. Following that torsion from landing to landing frees a
rigid twist and the stiffness is singular. The twist stays fixed.
Bending rotations still free wherever they couple to translation at the
joint. A rotation that only released ends meet stays fixed. Throws when
the freed rotations are still singular (a released member at a skew with
nothing else at the node), naming the node.
"""
function _free_restrained_node_rotations!(nodes, frame_elements, shell_elements)
    shell_nodes = Set{UInt64}()
    for sh in shell_elements, nd in sh.nodes
        push!(shell_nodes, objectid(nd))
    end

    Asap.process_elements!(frame_elements)
    blocks = IdDict{Asap.Node, Matrix{Float64}}()
    # Largest |coupling| of each rotation to a translation or to a support.
    anchor = IdDict{Asap.Node, Vector{Float64}}()
    for el in frame_elements
        el isa Asap.Element || continue
        _note_rotation_anchor!(blocks, anchor, el.nodeStart, el.nodeEnd,
                               el.K, 4:6, 1:3, 10:12)
        _note_rotation_anchor!(blocks, anchor, el.nodeEnd, el.nodeStart,
                               el.K, 10:12, 7:9, 4:6)
    end
    scale = maximum((maximum(diag(B)) for B in values(blocks)); init=0.0)
    tol = 1e-9 * scale

    for nd in nodes
        dof = nd.dof
        (dof[1] && dof[2] && dof[3]) || continue
        if objectid(nd) in shell_nodes
            dof[4] = dof[5] = dof[6] = true
            continue
        end
        B = get(blocks, nd, nothing)
        B === nothing && continue
        mag = anchor[nd]
        restrained = findall(i -> B[i, i] > tol && mag[i] > tol, 1:3)
        isempty(restrained) && continue
        if eigmin(Symmetric(B[restrained, restrained])) <= tol
            p = ustrip.(u"m", nd.position)
            throw(ArgumentError(
                "node at ($(p[1]), $(p[2]), $(p[3])) m: the connected frame " *
                "elements restrain its rotation only about a skew axis. Fix or " *
                "release that member end explicitly, or add a member that " *
                "restrains the node."))
        end
        for i in restrained
            dof[3 + i] = true
        end
    end
    return nodes
end

"""
Fix every node that no frame or shell element uses.

A skeleton vertex that this model does not draw still has a node. A free
translation there is a zero row in the stiffness.
"""
function _fix_unused_nodes!(nodes, frame_elements, shell_elements)
    used = Set{UInt64}()
    for el in frame_elements
        push!(used, objectid(el.nodeStart), objectid(el.nodeEnd))
    end
    for sh in shell_elements, nd in sh.nodes
        push!(used, objectid(nd))
    end
    for nd in nodes
        objectid(nd) in used && continue
        fill!(nd.dof, false)
    end
    return nodes
end

function _add_rotation_block!(blocks, node, K)
    B = get!(() -> zeros(3, 3), blocks, node)
    B .+= K
    return blocks
end

"""Add one element end's rotational stiffness and its coupling to an anchor.

`r`, `t`, and `o` are this end's rotations, this end's translations, and the
other end's rotations. Translation coupling anchors the rotation. So does
coupling to the other end when that end is a support. Coupling to another
free node's rotation does not: that only ties two free twists together.
"""
function _note_rotation_anchor!(blocks, anchor, node, other, K, r, t, o)
    _add_rotation_block!(blocks, node, @view K[r, r])
    mag = get!(() -> zeros(3), anchor, node)
    other_fixed = !(other.dof[1] && other.dof[2] && other.dof[3])
    @inbounds for i in 1:3
        row = 0.0
        ri = r[i]
        for j in 1:3
            row = max(row, abs(K[ri, t[j]]))
            other_fixed && (row = max(row, abs(K[ri, o[j]])))
        end
        row > mag[i] && (mag[i] = row)
    end
    return nothing
end

"""
    _inert_frame_edges(skel) -> Set{Int}

Skeleton edges that keep a frame slot and add no stiffness or mass.

`:walls` is meshed as shells. `:absent` is parked geometry: the edge stays so
a later pass can move it into a member group, and until then it is not a
member.
"""
function _inert_frame_edges(skel)
    ids = Set{Int}()
    for group in (:walls, :absent)
        union!(ids, get(skel.groups_edges, group, Int[]))
    end
    return ids
end

"""
    _zero_wall_frame_section(E, G) -> Asap.Section

Frame section for a `:walls` or `:absent` edge.

The edge keeps its `model.frame_elements` slot so callers can still index that
vector by skeleton edge. Area, `Ix`, `Iy`, `J`, and density are zero, so
the frame adds neither stiffness nor mass (`EA`, `EI`, and `GJ` are zero;
translational mass is `ρ·A·L`). `E` and `G` are stored only because
`Asap.Section` requires them. Shear areas stay at the Bernoulli–Euler
default (infinite): a zero shear area would select the Timoshenko kernel
and make the shear factor `0/0`.
"""
function _zero_wall_frame_section(E, G)
    return Asap.Section(
        0.0u"m^2",
        E,
        G,
        0.0u"m^4",    # Ix
        0.0u"m^4",    # Iy
        0.0u"m^4",    # J
        0.0u"kg/m^3",
    )
end

"""
    _apply_column_roll!(element, θ)

Set a vertical member's Asap roll so its section x axis is at `θ` from global X.

`θ` is [`Column`](@ref)`.θ`, the angle of c1 from global X. The section x axis
is `b = c1` for an `RCColumnSection` and the flange width for a W shape, so
`Ix` resists sway along c2 and `Iy` sway along c1. Asap's local y for a
vertical member is `(-sin Ψ, cos Ψ, 0)` drawn upward and `(sin Ψ, cos Ψ, 0)`
drawn downward, and its `Ix` acts with local y. The roll is therefore `θ` for
a member drawn bottom to top and `-θ` for one drawn top to bottom. It replaces
the constructor's `Ψ = π/2`, which would put c2 along global X. A member that
is not vertical is left alone.
"""
function _apply_column_roll!(element, θ::Real)
    a = ustrip.(u"m", element.nodeStart.position)
    b = ustrip.(u"m", element.nodeEnd.position)
    dz = b[3] - a[3]
    hypot(b[1] - a[1], b[2] - a[2]) <= 1e-9 * max(abs(dz), 1.0) || return element
    dz == 0 && return element
    element.Ψ = sign(dz) * Float64(θ)
    return element
end

"""
    _roll_columns_to_section_axes!(frame_elements, struc)

Roll each column's frame elements to `Column.θ`. Beams and braces stay as
Asap built them. See [`_apply_column_roll!`](@ref).
"""
function _roll_columns_to_section_axes!(frame_elements, struc)
    for col in struc.columns
        for si in segment_indices(col)
            eidx = struc.segments[si].edge_idx
            1 <= eidx <= length(frame_elements) || continue
            _apply_column_roll!(frame_elements[eidx], col.θ)
        end
    end
    return frame_elements
end

"""
    to_asap!(struc; params=DesignParameters(), diaphragms=nothing, shell_props=nothing)

Converts a BuildingStructure into an Asap.Model.
Uses TributaryLoads for accurate load distribution based on tributary polygons.

# Arguments
- `struc`: BuildingStructure to convert
- `params::DesignParameters`: Design parameters (load combinations, frame defaults, etc.)
- `diaphragms::Union{Symbol, Nothing}=nothing`: Override diaphragm mode from params
  - `:none` — No diaphragm modeling. Not an ASCE 7 category.
  - `:rigid` — In-plane rigid diaphragm via master/slave DOF reduction (Phase 9b).
    A single master node is elected per story and every other frame node on
    that story is `Asap.RigidLink`-ed to it, tying `(u_x, u_y, θ_z)` and
    leaving `(u_z, θ_x, θ_y)` free. Kinematic constraint is exact (Bathe §4.4;
    see `external/Asap/src/Elements/rigidlink.jl`) and keeps `K` SPD when
    every tied node already sits on a column, beam, or wall shell.
    [`require_diaphragm_node_stiffness`](@ref) throws if one does not: a node
    created only to hold the diaphragm has no stiffness in the free DOFs, and
    the reduced model is singular. This link is the drift authority. A
    penalty shell is not.
  - `:shell` — Semirigid shell elements from slab geometry, at the slab's real
    modulus (Phase 9a: shells join the assembled `K` via the 4-argument
    `Asap.Model` constructor). The modulus is not a penalty value.
  - `:flexible` — No rigid link and no diaphragm shell. The lateral stage
    builds the lines of seismic-system walls and their collector ties
    ([`flexible_diaphragm_layout!`](@ref)) and splits story forces among
    them. A strut is refused. No story force is applied to the building.
  - `:semirigid` — Membrane triangles over every slab face, meshed after the
    walls so each wall node on a slab edge is shared ([`_create_semirigid_floors`](@ref)).
    They carry in-plane force only; slab gravity keeps the tributary path. The
    modulus is the slab modulus times the first of
    `params.semirigid_stiffness_factors`. The layout is `struc.diaphragm_layout`.
  - `nothing` — Use `params.diaphragm_mode` (default)
- `shell_props::Union{Nothing, NamedTuple}=nothing`: Custom shell properties
  - `E`: Young's modulus (overrides `params.diaphragm_E`)
  - `ν`: Poisson's ratio (overrides `params.diaphragm_ν`)
  - `t_factor`: Thickness multiplier (default: 1.0)
- `load_routing::Symbol=:auto`: how slab gravity pressure reaches the frame
  (plan `joists-roles-materials`, Phase 7).
  - `:auto` (default) — route via `Asap.AreaLoad(shells; distribute_to=beams)`
    when diaphragm shells are present (`diaphragms=:shell` and non-empty
    slabs), otherwise fall through to the per-cell tributary path.
    This preserves the historical frame-only behavior exactly: with the default
    `diaphragms=:none`, no shells exist so `:auto` resolves to `:cell_tributary`.
  - `:cell_tributary` — always use the per-cell tributary loads
    (`_create_cell_tributary_loads!`), the pre-Phase-7 behavior.
  - `:shell_area` — always route through the shell mesh via `Asap.AreaLoad`,
    with auto-generated `:joist` beams passed as `interior_beams` and the slab's
    `spans.axis` as the one-way `axis`. Falls back to `:cell_tributary` (with a
    warning) when no diaphragm shells were built.

A `:walls` or `:absent` edge keeps `model.frame_elements[edge_idx]` aligned
with skeleton edge `edge_idx`, with the same release and eccentricity as any
other edge. Its section is [`_zero_wall_frame_section`](@ref) (zero area,
`Ix`, `Iy`, `J`, and density). A wall is meshed as shells, so the placeholder
must not be counted again. An `:absent` edge is parked geometry, not a
member. With neither group, every edge stays on the placeholder section.

Each entry in `struc.walls` is meshed into the same model as `ShellTri3`
elements (two columns along the wall, two triangles per quad). A wall node
reuses a frame, slab-mesh, or earlier wall node when the 3D distance is at
most 1 mm. A wall end that still sits on its architectural vertex is drawn
through the frame node there, so a column centerline offset and the wall
share that joint. An end moved off its vertex keeps the stated coordinate.
Two existing nodes equally near within that tolerance throw
`ArgumentError`. The pier runs from `skeleton.stories[wall.story].elevation`
up by `base.L`. A missing story or a non-positive `base.L` throws
`ArgumentError`. Material is `Wall.concrete`, or `params.materials.concrete`
when that is unset; if neither is set, throws `ArgumentError`. The shell
carries that concrete's modulus, Poisson's ratio, and density. No wall line
load is added. A wall node the mesh creates is fixed when it is within 1 mm
of the lowest wall-base elevation, and free otherwise. A reused node keeps
its dof vector. `:rigid` adds those wall nodes that lie on a story elevation to the
rigid-link set already built for the frame. `:shell` adds no links (the
1 mm tolerance shares the slab mesh). `:none` adds no diaphragm. An empty
`walls` vector adds no shells.

# Examples
```julia
# Simple: use defaults
to_asap!(struc)

# With custom parameters
params = DesignParameters(
    load_combinations = [strength_1_2D_1_6L, strength_1_4D],
    diaphragm_mode = :rigid,
)
to_asap!(struc; params=params)

# Override diaphragm mode
to_asap!(struc; params=params, diaphragms=:shell)

# Shell diaphragm with custom properties
to_asap!(struc; diaphragms=:shell, shell_props=(E=25e9u"Pa", ν=0.15))
```
"""
function to_asap!(struc::BuildingStructure{T, A, P}; 
                  params::DesignParameters=DesignParameters(),
                  diaphragms::Union{Symbol, Nothing}=nothing,
                  shell_props::Union{Nothing, NamedTuple}=nothing,
                  load_routing::Symbol=:auto,
                  mesh_div::Int=WALL_MESH_DIV,
                  mesh_rows::Int=WALL_MESH_ROWS) where {T, A, P}
    
    # Determine diaphragm mode: explicit argument overrides params.
    # :auto classifies the floor and keeps the result only when wind and
    # seismic agree; otherwise the floor is the semirigid membrane.
    diaphragm_mode = isnothing(diaphragms) ? params.diaphragm_mode : diaphragms
    diaphragm_mode == :auto && (diaphragm_mode = resolve_auto_diaphragm(struc, params))
    diaphragm_mode in (:none, :rigid, :shell, :flexible, :semirigid) ||
        error("diaphragms must be :none, :rigid, :shell, :flexible, :semirigid, or :auto")
    diaphragm_mode == :semirigid && isempty(struc.slabs) && throw(ArgumentError(
        "to_asap!: a :semirigid diaphragm meshes the slabs, and this structure has none."))
    # :flexible has no diaphragm constraint, and a story force is not applied.
    diaphragm_mode == :flexible && _require_flexible_diaphragm_support!(struc)
    load_routing in (:auto, :cell_tributary, :shell_area) ||
        error("load_routing must be :auto, :cell_tributary, or :shell_area")
    
    skel = struc.skeleton
    
    # 1. Nodes — from cached coordinate matrix, with structural offsets for columns.
    # Both endpoints of each column edge share the same XY offset so the column
    # line shifts as a rigid body and beams that frame into the column follow.
    col_offset_by_vertex = Dict{Int, NTuple{2, Float64}}()
    for col in struc.columns
        off = col.structural_offset
        (off[1] == 0.0 && off[2] == 0.0) && continue
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            (edge_idx < 1 || edge_idx > length(skel.edge_indices)) && continue
            v1, v2 = skel.edge_indices[edge_idx]
            col_offset_by_vertex[v1] = off
            col_offset_by_vertex[v2] = off
        end
    end

    support_set = Set(get(skel.groups_vertices, :support, Int[]))
    nodes = _create_offset_nodes(skel, col_offset_by_vertex, support_set)

    # 2. Frame Elements — placeholder section (replaced during sizing).
    # A :walls or :absent edge keeps its slot (model.frame_elements[edge_idx]
    # is still that skeleton edge) but gets a zero section. Walls are meshed
    # as shells. An :absent edge is parked and is not a member. With neither
    # group, every edge stays on the placeholder.
    # Use steel from materials cascade if available, else defaults
    _mat_steel = params.materials.steel
    frame_E = isnothing(_mat_steel) ? params.default_frame_E : uconvert(u"Pa", _mat_steel.E)
    frame_G = isnothing(_mat_steel) ? params.default_frame_G : uconvert(u"Pa", _mat_steel.G)
    frame_ρ = isnothing(_mat_steel) ? params.default_frame_ρ : uconvert(u"kg/m^3", _mat_steel.ρ)
    default_section = Asap.Section(
        4.18e-3u"m^2",    # A (approx W10x22 — placeholder geometry)
        frame_E, frame_G,
        89.8e-6u"m^4",    # Ix
        11.4e-6u"m^4",    # Iy
        0.5e-6u"m^4",     # J
        frame_ρ
    )
    inert_edges = _inert_frame_edges(skel)
    inert_section = isempty(inert_edges) ? nothing : _zero_wall_frame_section(frame_E, frame_G)
    # Per-beam end releases resolved from segment fields + (role, material) dispatch.
    # Non-beam edges (columns/struts/walls) and unmodeled edges default to
    # :fixedfixed.
    edge_release = _build_edge_release_map(struc, params)
    # Phase 7 seat-offset dispatch (see StructuralSizer/src/materials/steel.jl
    # :joist ENGINEERING JUDGMENT marker; StructuralSizer/src/members/defaults.jl).
    # On this initial `to_asap!` (pre-sizing) member sections are unknown, so the
    # map is empty/zero. `sync_asap!` repopulates it once member depths exist —
    # that is where the steel-joist-on-girder seat offset is actually applied.
    edge_eccentricity = _build_edge_eccentricity_map(struc, params)
    frame_elements = map(enumerate(skel.edge_indices)) do (edge_idx, (v1, v2))
        release = get(edge_release, edge_idx, :fixedfixed)
        section = edge_idx in inert_edges ? inert_section : default_section
        return Asap.Element(nodes[v1], nodes[v2], section; release=release)
    end
    _roll_columns_to_section_axes!(frame_elements, struc)
    # The map is the physical offset (positive local y = global up). Sign
    # slot 3 after the column roll, using the roll the element will keep.
    for (edge_idx, el) in enumerate(frame_elements)
        ecc = get(edge_eccentricity, edge_idx, (0.0, 0.0, 0.0, 0.0))
        el.eccentricity = Asap.orient_up_eccentricity(
            ecc, el.nodeStart, el.nodeEnd; roll = el.Ψ)
    end
    
    # 3. Diaphragm construction (Phase 9).
    #  :shell    → semirigid: real slab shells contribute to K (Phase 9a).
    #  :rigid    → in-plane RigidLink master/slave constraints tie every
    #              frame node on a story to a master node (Bathe §4.4 / Cook
    #              §6.3 kinematic reduction, see
    #              external/Asap/src/Elements/rigidlink.jl). The tie is
    #              (u_x, u_y, θ_z) only. Gravity DOFs (u_z, θ_x, θ_y) stay
    #              free, so `load_routing=:auto` falls back to per-cell
    #              TributaryLoads. This link is the drift authority.
    #  :flexible → no shells and no links. Tributary areas were required above.
    #  :none     → neither shells nor links.
    # Wall shells are meshed before the rigid-link pass so a wall base node
    # is already fixed when the link set is built. They are appended to
    # `shell_elements` only after load routing is resolved, so a wall mesh
    # cannot flip `:auto` onto `:shell_area`.
    shell_elements = Asap.ShellElement[]
    rigid_links = Asap.RigidLink[]

    if diaphragm_mode == :shell && !isempty(struc.slabs)
        effective_props = _build_shell_props(params, :shell, shell_props)
        shell_elements = _create_shell_diaphragms(struc, nodes;
                                                   mode=:shell, props=effective_props)
        @debug "Created shell diaphragm" n_shells=length(shell_elements)
    end

    # A stem that lands on another wall's interior is split first, so the
    # mesh shares the corner nodes. A second to_asap! does not split again.
    split_tee_junctions!(struc.walls; strip_walls=struc._tributary_caches.strip_walls)
    wall_shells, wall_nodes, shells_by_wall, cells_by_wall = _mesh_wall_shells(
        struc, params, nodes, shell_elements;
        mesh_div=mesh_div, mesh_rows=mesh_rows)
    struc.wall_mesh = WallMesh(shells_by_wall, wall_assemblies(struc.walls), cells_by_wall)
    _free_restrained_node_rotations!(nodes, frame_elements, vcat(shell_elements, wall_shells))

    # Membrane floor after the walls, so every wall node on a slab edge is a
    # floor node. Its triangles join the model after load routing, like the
    # wall shells, so they never carry slab gravity pressure.
    semirigid = nothing
    if diaphragm_mode == :semirigid
        pool = vcat(nodes, Asap.Node[nd for sh in wall_shells for nd in sh.nodes])
        semirigid = _create_semirigid_floors(struc, nodes, pool;
            factor=first(params.semirigid_stiffness_factors),
            props=_build_shell_props(params, :shell, shell_props))
        @debug "Created semirigid floors" n_floors=length(semirigid.floors)
    end

    if diaphragm_mode == :rigid && !isempty(struc.slabs)
        # A node whose θz no element restrains keeps it fixed, and the
        # rigid-link release would then drop the θz tie. Free plan rotation
        # on nodes that can already translate in plan so the (u_x, u_y, θ_z)
        # tie this path documents is enforced; the link supplies the
        # stiffness. Supports stay fixed.
        _free_plan_rotation_for_rigid_diaphragm!(nodes)
        _free_plan_rotation_for_rigid_diaphragm!(wall_nodes)
    end
    # After every pass that frees a rotation. A grade wall's base, including
    # the nodes between support vertices, is fixed in all six degrees of
    # freedom. The rigid link then skips those nodes.
    _fix_grade_wall_bases!(skel, wall_shells)
    if diaphragm_mode == :rigid && !isempty(struc.slabs)
        rigid_links = _build_rigid_diaphragm_links(struc, nodes)
        _join_wall_nodes_to_rigid_diaphragm!(rigid_links, skel, wall_nodes)
        @debug "Created rigid diaphragm links" n_links=length(rigid_links)
    end

    struc.asap_rigid_links = rigid_links
    struc.diaphragm_layout = semirigid
    
    # 4. Compute tributaries if not done
    isempty(struc.cell_groups) && build_cell_groups!(struc)
    compute_cell_tributaries!(struc)  # Cache handles deduplication
    
    # 5. Create loads using TributaryLoad
    loads = Asap.AbstractLoad[]
    empty!(struc.cell_tributary_loads)
    empty!(struc.cell_dead_loads)
    empty!(struc.cell_live_loads)
    
    use_patterns = params.pattern_loading != :none
    combo = governing_combo(params)

    # Phase 7 — pick the slab-pressure routing (shell AreaLoad vs per-cell
    # tributary). `:auto` uses shells when a diaphragm built them, else the
    # historical per-cell path (so the default frame-only flow is unchanged).
    routing = _resolve_load_routing(load_routing, shell_elements)
    # Diaphragm shells only were visible to routing. Wall shells join the
    # model here; they are not a second diaphragm and they are not a line load.
    # Their weight is a separate area load on the triangles, added below.
    append!(shell_elements, wall_shells)
    semirigid === nothing || append!(shell_elements, semirigid_shells(semirigid))
    # A vertex no element uses still has free translations. Fix it so it is
    # not a mechanism. Coincident rib landings that were not drawn as an
    # element land here.
    _fix_unconnected_nodes!(nodes, frame_elements, shell_elements, rigid_links)

    # Slab past the centerlines, loaded on the edge members whichever routing
    # carries the rest of the slab.
    edge_strips = slab_edge_strips_by_cell(struc)
    per_cell = Set{Int}()
    if routing === :shell_area
        if any(s -> _grillage_level(s) !== nothing, struc.slabs)
            throw(ArgumentError(
                "a grillage floor owns its panel load. Shell area routing would apply it again."))
        end
        _create_shell_area_loads!(loads, frame_elements, struc, nodes, params)
    else
        # Joist-framed slabs route their pressure onto the interior joists +
        # boundary girders (defect #1/#2) so the elastic solve produces the
        # continuous-beam girder envelope from concentrated joist reactions.
        # `handled_cells` are then skipped by the per-cell tributary loop below so
        # each framed slab's pressure is applied exactly once (no double counting).
        # Slabs WITHOUT materialized joists are untouched (byte-identical loads).
        handled_cells = _create_framed_slab_loads!(loads, frame_elements, struc,
                                                   params; use_patterns=use_patterns,
                                                   combo=combo)
        for (cell_idx, cell) in enumerate(struc.cells)
            if cell.floor_type == :grade
                struc.cell_tributary_loads[cell_idx] = Asap.TributaryLoad[]
                struc.cell_dead_loads[cell_idx] = Asap.TributaryLoad[]
                struc.cell_live_loads[cell_idx] = Asap.TributaryLoad[]
                continue
            end

            # Already routed onto joists + girders above.
            cell_idx in handled_cells && continue
            push!(per_cell, cell_idx)

            if use_patterns
                dead, live = _create_cell_tributary_loads!(
                    loads, frame_elements, skel, struc, cell, cell_idx, params;
                    split_dead_live=true, combo=combo, edge_strips=edge_strips)
                struc.cell_dead_loads[cell_idx] = dead
                struc.cell_live_loads[cell_idx] = live
                struc.cell_tributary_loads[cell_idx] = vcat(dead, live)
            else
                combined = _create_cell_tributary_loads!(
                    loads, frame_elements, skel, struc, cell, cell_idx, params;
                    split_dead_live=false, combo=combo, edge_strips=edge_strips)
                struc.cell_dead_loads[cell_idx] = Asap.TributaryLoad[]
                struc.cell_live_loads[cell_idx] = Asap.TributaryLoad[]
                struc.cell_tributary_loads[cell_idx] = combined
            end
        end
    end
    _append_unrouted_edge_strip_loads!(loads, frame_elements, struc, edge_strips, per_cell, params;
                                       use_patterns=use_patterns && routing !== :shell_area,
                                       combo=combo)
    
    # 6. Add structural effects (e.g., vault thrust)
    for slab in struc.slabs
        for spec in slab_edge_line_loads(struc, slab, params)
            el = frame_elements[spec.edge_idx]
            push_asap_loads!(loads, el, spec)
        end
    end

    # Wall self-weight is dead load on the wall triangles only. The pressure
    # is ρ t g per triangle, then multiplied by the same dead factor the slab
    # dead load in this solve already carries. Slab shells are not in this load.
    if !isempty(wall_shells)
        _append_factored_wall_self_weight!(loads, wall_shells, params; patterned=use_patterns)
    end
    if _has_drop_panels(struc)
        append!(loads, drop_panel_weight_loads(struc, nodes;
            factor=_self_weight_dead_factor(params; patterned=use_patterns)))
    end

    # 7. Build unified Asap.Model (Phase 9a — diaphragm shells now contribute
    # to the assembled stiffness). The 4-argument constructor merges shell
    # mesh nodes into the node list via _merge_shell_nodes (which reuses the
    # Phase 8 interior_nodes by objectid, so joist landings and shell mesh
    # DOFs are already shared). Empty shell_elements ⇒ Model dispatches to the
    # frame-only path (see external/Asap/src/Model/model.jl:296-303,
    # Model(nodes, frame_elements, loads) = Model(nodes, frame_elements,
    # ShellTri3[], loads)), so the diaphragms=:none default stays byte-
    # identical. This mirrors `build_analysis_model!` in this same file.
    # Cracked-wall E before the first process, so later load-only syncs keep it.
    _apply_stated_cracked_wall_stiffness!(wall_shells, params)
    struc.asap_model = Asap.Model(nodes, frame_elements, shell_elements, loads)

    @debug "Converted to Asap.Model" nodes=length(nodes) frame_elements=length(frame_elements) shell_elements=length(shell_elements) loads=length(loads) rigid_links=length(rigid_links)

    Asap.process!(struc.asap_model)
    # Phase 9b — rigid diaphragms are applied via master/slave DOF reduction
    # (Bathe §4.4; see external/Asap/src/Elements/rigidlink.jl §solve!). Empty
    # links dispatch through the standard solve path, so the frame-only /
    # shell-only defaults are byte-identical.
    if isempty(struc.asap_rigid_links)
        Asap.solve!(struc.asap_model)
    else
        require_diaphragm_node_stiffness(struc.asap_rigid_links,
            struc.asap_model.frame_elements, struc.asap_model.shell_elements)
        Asap.solve!(struc.asap_model, struc.asap_rigid_links; reprocess=false)
    end

    return struc.asap_model
end

