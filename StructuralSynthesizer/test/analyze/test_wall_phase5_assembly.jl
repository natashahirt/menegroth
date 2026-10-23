# =============================================================================
# Phase 5 — wall shells in the building Asap model
# =============================================================================
#
# A :walls edge stays in the frame so element i is still skeleton edge i, but
# its section is zero (no second stiffness, no second mass). The pier itself
# is ShellTri3 elements in that same model. The mesher may reuse a node within
# 1 mm and must not invent a support: a node it creates is free, and a node it
# reuses keeps the dof vector the frame already gave it.
#
# Fixture is the 1×1 office from test/core/test_wall_data_model.jl. These
# checks stop at assembly. An isolated wall may be singular; nothing here
# calls solve!.

using Test
using Unitful
using Meshes
using Asap
using StructuralSynthesizer

# NWC_5000 is not the slab default (NWC_4000). A shell that invented a modulus
# would not match this grade. ρ is 2385 kg/m³, not 2380.
const _WALL_CONCRETE = NWC_5000

# Vault is the floor path the wall data-model fixture already drives.
const _VAULT_OPTS = VaultOptions(rise=1.0u"m", thickness=0.05u"m")

# Placeholder frame section written by to_asap! (W10×22-ish geometry, A992 density).
const _PLACEHOLDER_A = 4.18e-3          # m²
const _PLACEHOLDER_Ix = 89.8e-6         # m⁴
const _PLACEHOLDER_Iy = 11.4e-6         # m⁴
const _PLACEHOLDER_J = 0.5e-6           # m⁴
const _PLACEHOLDER_ρ = 7849.0           # kg/m³, 490 pcf

const _FRAME_FREE = [true, true, true, false, false, false]
const _ALL_FIXED = [false, false, false, false, false, false]
const _ALL_FREE = [true, true, true, true, true, true]

"""Plan (x, y) of a skeleton vertex, in metres."""
function _xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

"""True when both endpoints share an elevation (a plan edge, not a column)."""
function _is_horizontal(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

"""Plan length of an edge [m]."""
function _plan_length(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _xy(skel, v1)
    x2, y2 = _xy(skel, v2)
    return hypot(x2 - x1, y2 - y1)
end

"""Horizontal :beams edges on a 0-based story."""
function _horizontal_beams(skel, story)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    return [e for e in skel.stories[story].edges if e in beams && _is_horizontal(skel, e)]
end

"""Move one skeleton edge from `:beams` into `:walls`."""
function _claim_as_wall!(skel, eidx)
    filter!(!=(eidx), skel.groups_edges[:beams])
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end

"""Pier thickness. 0.3 m cannot be mistaken for a 0.2 m default."""
function _wall_thickness(skel)
    return 0.3 * oneunit(first(skel.stories_z))
end

"""1×1 office, 10 m × 6 m bays, 4 m stories."""
_office(; n_stories::Int) = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, n_stories)

"""Longest horizontal beam on `story`, claimed as the single :walls edge."""
function _office_with_wall_on(story::Int; n_stories::Int)
    skel = _office(; n_stories=n_stories)
    edges = _horizontal_beams(skel, story)
    @assert !isempty(edges) "fixture: no horizontal beam on story $story"
    eidx = edges[argmax(_plan_length.(Ref(skel), edges))]
    _claim_as_wall!(skel, eidx)
    return skel, eidx
end

function _init!(struc; wall_thickness=nothing, pass_thickness::Bool=true)
    if pass_thickness
        return initialize!(struc;
            floor_type=:vault,
            material=NWC_4000,
            floor_opts=_VAULT_OPTS,
            wall_thickness=wall_thickness)
    end
    return initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=_VAULT_OPTS)
end

"""Concrete is explicit. Diaphragm stays :none so the only shells are walls."""
_wall_params() = DesignParameters(
    materials=MaterialOptions(concrete=_WALL_CONCRETE),
    diaphragm_mode=:none,
)

"""Story-0 wall on the 1-story office. Concrete is still unset on the Wall."""
function _walled()
    skel, eidx = _office_with_wall_on(0; n_stories=1)
    struc = _init!(BuildingStructure(skel); wall_thickness=_wall_thickness(skel))
    return struc, eidx
end

function _assemble!(struc, params)
    to_asap!(struc; params=params, diaphragms=:none)
    return struc.asap_model
end

_xyz(nd) = (ustrip(u"m", nd.position[1]), ustrip(u"m", nd.position[2]), ustrip(u"m", nd.position[3]))

function _dist(nd, x, y, z)
    a, b, c = _xyz(nd)
    return hypot(a - x, b - y, c - z)
end

"""Frame-element endpoints, one object each."""
function _frame_nodes(model)
    out = Asap.Node[]
    seen = Set{UInt64}()
    for el in model.frame_elements
        for n in (el.nodeStart, el.nodeEnd)
            id = objectid(n)
            id in seen && continue
            push!(seen, id)
            push!(out, n)
        end
    end
    return out
end

"""Shell nodes, one object each."""
function _shell_nodes(shells)
    out = Asap.Node[]
    seen = Set{UInt64}()
    for sh in shells
        for n in sh.nodes
            id = objectid(n)
            id in seen && continue
            push!(seen, id)
            push!(out, n)
        end
    end
    return out
end

function _near(nodes, x, y, z; atol=1e-8)
    return [n for n in nodes if _dist(n, x, y, z) <= atol]
end

function _closest(nodes, x, y, z)
    best = first(nodes)
    best_d = Inf
    for n in nodes
        d = _dist(n, x, y, z)
        if d < best_d
            best = n
            best_d = d
        end
    end
    return best, best_d
end

"""Skeleton vertex whose coordinates are (x, y, z) metres."""
function _vertex_at(skel, x, y, z; atol=1e-8)
    vc = skel.geometry.vertex_coords
    hits = Int[]
    for i in 1:size(vc, 1)
        if hypot(vc[i, 1] - x, vc[i, 2] - y, vc[i, 3] - z) <= atol
            push!(hits, i)
        end
    end
    return only(hits)
end

"""Beam edge that shares a vertex with `eidx` and is not itself a wall."""
function _neighbor_beam(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    walls = Set(get(skel.groups_edges, :walls, Int[]))
    for e in get(skel.groups_edges, :beams, Int[])
        e in walls && continue
        a, b = skel.edge_indices[e]
        (a == v1 || b == v1 || a == v2 || b == v2) && return e
    end
    return nothing
end

@testset "Phase 5 wall assembly" begin

    # ── (1) No :walls edges. The frame is the whole skeleton, on the
    # placeholder section. An empty walls vector adds no shells.
    @testset "no walls: placeholder frame, zero wall shells" begin
        skel = _office(; n_stories=1)
        @test isempty(get(skel.groups_edges, :walls, Int[]))
        struc = _init!(BuildingStructure(skel); pass_thickness=false)
        @test isempty(struc.walls)
        model = _assemble!(struc, DesignParameters(diaphragm_mode=:none))

        @test length(model.frame_elements) == length(skel.edge_indices)
        wall_shells = [s for s in model.shell_elements if s.id == :wall]
        @test isempty(wall_shells)

        beam_edge = first(skel.groups_edges[:beams])
        sec = model.frame_elements[beam_edge].section
        @test ustrip(u"m^2", sec.A) ≈ _PLACEHOLDER_A atol=1e-12
        @test ustrip(u"kg/m^3", sec.ρ) ≈ _PLACEHOLDER_ρ atol=1.0
        @test sec.ρ ≈ DesignParameters().default_frame_ρ
        @test !iszero(sec.A)
        @test !iszero(sec.ρ)
    end

    # ── (2–3) One story-0 wall. Its frame slot is a zero section. The
    # neighboring beam stays on the placeholder. Shells are ShellTri3 :wall.
    # Bottom corners reuse supports (all false). Top corners reuse the roof
    # frame (translations free, rotations fixed). Mid-height and mid-length
    # nodes are created free — including the node on the base elevation.
    @testset "wall edge is a zero frame; shells are free or reused" begin
        struc, eidx = _walled()
        skel = struc.skeleton
        w = only(struc.walls)
        @test w.concrete === nothing
        @test all(c -> c.structural_offset == (0.0, 0.0), struc.columns)
        params = _wall_params()
        model = _assemble!(struc, params)

        @test length(model.frame_elements) == length(skel.edge_indices)
        wsec = model.frame_elements[eidx].section
        @test iszero(wsec.A) && iszero(wsec.Ix) && iszero(wsec.Iy) && iszero(wsec.J) && iszero(wsec.ρ)

        neighbor = _neighbor_beam(skel, eidx)
        @test neighbor !== nothing
        nsec = model.frame_elements[neighbor].section
        @test ustrip(u"m^2", nsec.A) ≈ _PLACEHOLDER_A atol=1e-12
        @test ustrip(u"m^4", nsec.Ix) ≈ _PLACEHOLDER_Ix atol=1e-15
        @test ustrip(u"m^4", nsec.Iy) ≈ _PLACEHOLDER_Iy atol=1e-15
        @test ustrip(u"m^4", nsec.J) ≈ _PLACEHOLDER_J atol=1e-15
        @test ustrip(u"kg/m^3", nsec.ρ) ≈ _PLACEHOLDER_ρ atol=1.0
        @test !iszero(nsec.A)

        shells = model.shell_elements
        # mesh_div = 2 → two quads, two triangles each.
        @test length(shells) == 4
        @test all(s -> s isa Asap.ShellTri3 && s.id == :wall, shells)

        t_m = ustrip(u"m", w.thickness)
        E_Pa = ustrip(u"Pa", _WALL_CONCRETE.E)
        ρ_c = ustrip(u"kg/m^3", _WALL_CONCRETE.ρ)
        @test all(s -> s.thickness ≈ t_m && s.E ≈ E_Pa && s.ν ≈ _WALL_CONCRETE.ν && s.ρ ≈ ρ_c, shells)

        z_bot = ustrip(u"m", skel.stories[w.story].elevation)
        z_top = z_bot + ustrip(u"m", w.base.L)
        zs = [ustrip(u"m", n.position[3]) for s in shells for n in s.nodes]
        @test minimum(zs) ≈ z_bot atol=1e-9
        @test maximum(zs) - minimum(zs) ≈ ustrip(u"m", w.base.L) atol=1e-9

        frames = _frame_nodes(model)
        shell_nodes = _shell_nodes(shells)
        # Bottom corner is a ground support. Top corner is the roof frame node.
        sup = only(_near(frames, w.x1, w.y1, z_bot))
        upper = only(_near(frames, w.x1, w.y1, z_top))
        @test sup.dof == _ALL_FIXED
        @test upper.dof == _FRAME_FREE
        @test only(_near(shell_nodes, w.x1, w.y1, z_bot)) === sup
        @test only(_near(shell_nodes, w.x1, w.y1, z_top)) === upper

        # Midpoint of the pier base: no skeleton vertex, so the mesh creates it.
        # It sits on the base elevation and is still free.
        mx = (w.x1 + w.x2) / 2
        my = (w.y1 + w.y2) / 2
        mid = only(_near(shell_nodes, mx, my, z_bot; atol=1e-6))
        @test mid.id == :wall
        @test mid.dof == _ALL_FREE
        @test all(n -> n !== mid, frames)

        created = [n for n in shell_nodes if n.id == :wall]
        @test length(created) == 2
        @test all(n -> n.dof == _ALL_FREE, created)

        n_support = length(get(skel.groups_vertices, :support, Int[]))
        fixed_nodes = [n for n in model.nodes if n.dof == _ALL_FIXED]
        @test length(fixed_nodes) == n_support
        @test all(n -> n.id != :wall, fixed_nodes)
    end

    # ── (4) 1 mm node share, in 3D. 0.9 mm reuses the frame node.
    # 1.1 mm does not. Two existing nodes at the same distance throw.
    @testset "0.9 mm reuses the frame node" begin
        struc, _ = _walled()
        w = only(struc.walls)
        z_bot = ustrip(u"m", struc.skeleton.stories[w.story].elevation)
        x0, y0 = w.x1, w.y1
        w.x1 = x0 + 0.9e-3
        model = _assemble!(struc, _wall_params())
        frames = _frame_nodes(model)
        shells = [s for s in model.shell_elements if s.id == :wall]
        fn, fd = _closest(frames, w.x1, w.y1, z_bot)
        sn, sd = _closest(_shell_nodes(shells), w.x1, w.y1, z_bot)
        @test fd ≈ 0.9e-3 atol=1e-8
        @test sn === fn
        @test sd ≈ 0.9e-3 atol=1e-8
        # The shared node is the unshifted frame corner, not a new node at the wall.
        @test _dist(fn, x0, y0, z_bot) <= 1e-8
    end

    @testset "1.1 mm is a different node" begin
        struc, _ = _walled()
        w = only(struc.walls)
        z_bot = ustrip(u"m", struc.skeleton.stories[w.story].elevation)
        x0, y0 = w.x1, w.y1
        w.x1 = x0 + 1.1e-3
        model = _assemble!(struc, _wall_params())
        frames = _frame_nodes(model)
        shells = [s for s in model.shell_elements if s.id == :wall]
        fn, fd = _closest(frames, w.x1, w.y1, z_bot)
        sn, sd = _closest(_shell_nodes(shells), w.x1, w.y1, z_bot)
        @test fd ≈ 1.1e-3 atol=1e-8
        @test sd <= 1e-8
        @test sn !== fn
        @test all(n -> n !== sn, frames)
        @test sn.id == :wall
        @test sn.dof == _ALL_FREE
        @test _dist(fn, x0, y0, z_bot) <= 1e-8
    end

    @testset "two nodes equally near within 1 mm throw" begin
        struc, _ = _walled()
        skel = struc.skeleton
        w = only(struc.walls)
        z_bot = ustrip(u"m", skel.stories[w.story].elevation)
        v_start = _vertex_at(skel, w.x1, w.y1, z_bot)
        v_end = _vertex_at(skel, w.x2, w.y2, z_bot)
        vc = skel.geometry.vertex_coords
        others = [i for i in 1:size(vc, 1) if i != v_start && i != v_end]
        @test !isempty(others)
        other = last(others)
        # 0.5 mm each side. Both are inside the 1 mm tolerance, and the
        # squared distances are the same, so neither is "nearer".
        δ = 5e-4
        vc[v_start, 1] = w.x1 + δ
        vc[v_start, 2] = w.y1
        vc[v_start, 3] = z_bot
        vc[other, 1] = w.x1 - δ
        vc[other, 2] = w.y1
        vc[other, 3] = z_bot
        d1 = hypot(vc[v_start, 1] - w.x1, vc[v_start, 2] - w.y1, vc[v_start, 3] - z_bot)
        d2 = hypot(vc[other, 1] - w.x1, vc[other, 2] - w.y1, vc[other, 3] - z_bot)
        @test d1 == d2
        @test 0 < d1 < 1e-3
        # @test_throws passes the showerror string, not the exception object.
        @test_throws msg -> occursin("ArgumentError", msg) && occursin("equally near", msg) begin
            _assemble!(struc, _wall_params())
        end
    end

    # ── (5) No invented material or pier height.
    @testset "missing concrete throws" begin
        struc, _ = _walled()
        w = only(struc.walls)
        @test w.concrete === nothing
        params = DesignParameters(diaphragm_mode=:none)
        @test params.materials.concrete === nothing
        @test_throws msg -> occursin("ArgumentError", msg) && occursin("concrete", msg) begin
            to_asap!(struc; params=params, diaphragms=:none)
        end
    end

    @testset "non-positive pier height throws" begin
        struc, _ = _walled()
        w = only(struc.walls)
        w.concrete = _WALL_CONCRETE
        w.base.L = zero(w.base.L)
        @test_throws msg -> occursin("ArgumentError", msg) && occursin("base.L", msg) && occursin("positive", msg) begin
            _assemble!(struc, _wall_params())
        end

        struc2, _ = _walled()
        w2 = only(struc2.walls)
        w2.concrete = _WALL_CONCRETE
        w2.base.L = -oneunit(w2.base.L)
        @test_throws msg -> occursin("ArgumentError", msg) && occursin("base.L", msg) && occursin("positive", msg) begin
            _assemble!(struc2, _wall_params())
        end
    end

    # ── (6) Stiffness token. Geometry, κ, and node order enter K.
    # Density does not. Restoring κ = 5/6 restores the token.
    @testset "stiffness token watches shells, not density" begin
        struc, _ = _walled()
        params = _wall_params()
        model = _assemble!(struc, params)
        token = () -> StructuralSynthesizer._stiffness_token(struc, params)

        t0 = token()
        @test token() == t0

        sh = first(s for s in model.shell_elements if s isa Asap.ShellTri3 && s.id == :wall)
        @test sh.κ ≈ 5/6
        sh.κ = 0.9
        @test token() != t0
        sh.κ = 5/6
        @test token() == t0

        ρ0 = sh.ρ
        sh.ρ = ρ0 + 1000.0
        @test token() == t0
        sh.ρ = ρ0
        @test token() == t0

        w = only(struc.walls)
        w.x2 += 0.25
        model2 = _assemble!(struc, params)
        t_moved = token()
        @test t_moved != t0

        sh2 = first(s for s in model2.shell_elements if s isa Asap.ShellTri3 && s.id == :wall)
        c1 = _xyz(sh2.nodes[1])
        c2 = _xyz(sh2.nodes[2])
        @test c1 != c2
        sh2.nodes = (sh2.nodes[2], sh2.nodes[1], sh2.nodes[3])
        # The node objects kept their coordinates; only the shell's order changed.
        @test _xyz(sh2.nodes[1]) == c2
        @test _xyz(sh2.nodes[2]) == c1
        @test token() != t_moved
    end
end
