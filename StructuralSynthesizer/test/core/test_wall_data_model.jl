# =============================================================================
# Wall data model: skeleton :walls edges → BuildingStructure.walls
# =============================================================================
#
# SAFETY-CRITICAL: a shear-wall pier whose length is the plan edge, or whose
# story index is off by one, feeds the wrong height and the wrong diaphragm
# into the lateral evaluator. These tests are known-answer checks on a small
# rectangular office (gen_medium_office), the same initialize! path the member
# hierarchy tests use.
#
# Contract under test:
#   - A horizontal :walls edge becomes one Wall. Plan endpoints are that
#     edge's vertex_coords. base.L is the story height (this floor to the
#     next story whose faces are non-empty), not the plan length.
#     Wall.story is 0-based.
#   - A vertex that belongs to no face still inserts a story. Pier height
#     skips it: the story-0 wall's base.L is 4 m (the next story with
#     faces), not that vertex's elevation (0.05 m).
#   - A faced floor 5 cm below the wall does not own it. The wall edge at
#     z = 0 keeps story elevation 0 m and base.L = 4 m. The 0.1 m
#     edge_story window is not used.
#   - That edge is not also a Beam. An edge index listed in both :walls
#     and :beams throws ArgumentError. The beam is not dropped.
#   - wall_thickness is required when :walls edges exist. It is not invented.
#   - wall_above links only to the same plan line on the next story. The
#     top (roof) wall's wall_above is nothing.
#   - initialize! runs the plate enclosure check: a wall center outside the
#     story faces throws.
#   - With no :walls edges, initialize! succeeds, walls is empty, and
#     thickness is not required.
#   - to_wall_line(...).story == wall.story + 1.
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Meshes
using Unitful
using Test

# Vault is the floor path test_member_hierarchy.jl already drives through
# initialize!. Rise and slab thickness are fixture geometry, not a wall property.
const _VAULT_OPTS = VaultOptions(rise=1.0u"m", thickness=0.05u"m")

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

"""Plan length of an edge [m], from the skeleton vertices (not Wall.base.L)."""
function _plan_length(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _xy(skel, v1)
    x2, y2 = _xy(skel, v2)
    return hypot(x2 - x1, y2 - y1)
end

"""Order-independent plan key so stacked edges can be matched across stories."""
function _plan_key(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    a = _xy(skel, v1)
    b = _xy(skel, v2)
    pa = (round(a[1]; digits=4), round(a[2]; digits=4))
    pb = (round(b[1]; digits=4), round(b[2]; digits=4))
    return pa <= pb ? (pa, pb) : (pb, pa)
end

"""Horizontal :beams edges already assigned to a 0-based story."""
function _horizontal_beams(skel, story)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    return [e for e in skel.stories[story].edges if e in beams && _is_horizontal(skel, e)]
end

"""
Move one skeleton edge from `:beams` into `:walls`.

The edge stays a plan line on its story. initialize! must turn it into a
Wall and must not also turn it into a Beam.
"""
function _claim_as_wall!(skel, eidx)
    filter!(!=(eidx), skel.groups_edges[:beams])
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end

"""Pier thickness in the skeleton's length type. Chosen so a silent default cannot match."""
function _wall_thickness(skel)
    return 0.3 * oneunit(first(skel.stories_z))
end

"""Story-to-story floor height. This is what Wall.base.L must equal."""
function _story_height(skel, story::Int)
    return skel.stories[story + 1].elevation - skel.stories[story].elevation
end

"""
True when the wall's plan endpoints are the edge's two vertex_coords,
in either order. vertex_coords is the datum initialize! reads.
"""
function _xy_close(a::NTuple{2,Float64}, b::NTuple{2,Float64})
    return isapprox(a[1], b[1]; atol=1e-9) && isapprox(a[2], b[2]; atol=1e-9)
end

function _endpoints_match(wall, skel, eidx)
    vc = skel.geometry.vertex_coords
    v1, v2 = skel.edge_indices[eidx]
    a = (vc[v1, 1], vc[v1, 2])
    b = (vc[v2, 1], vc[v2, 2])
    p = (wall.x1, wall.y1)
    q = (wall.x2, wall.y2)
    # Compare components. Meshes.isapprox does not accept coordinate tuples.
    return (_xy_close(p, a) && _xy_close(q, b)) || (_xy_close(p, b) && _xy_close(q, a))
end

"""True when some Beam owns the segment of skeleton edge `eidx`."""
function _edge_is_beam(struc, eidx)
    for beam in struc.beams
        for si in beam.base.segment_indices
            struc.segments[si].edge_idx == eidx && return true
        end
    end
    return false
end

"""initialize! with the vault floor path. Pass thickness only when requested."""
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

"""
1×1 office. `n_stories` is the number of pier heights (a story above the
ground floor always exists). Plan spans are deliberately not the story height.
"""
function _office(; n_stories::Int)
    # 10 m × 6 m bays, 4 m stories: every plan edge is 6 m or 10 m, never 4 m.
    return gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, n_stories)
end

"""Longest horizontal beam on `story`, claimed as the single :walls edge."""
function _office_with_wall_on(story::Int; n_stories::Int)
    skel = _office(; n_stories=n_stories)
    edges = _horizontal_beams(skel, story)
    @assert !isempty(edges) "fixture: no horizontal beam on story $story"
    eidx = edges[argmax(_plan_length.(Ref(skel), edges))]
    _claim_as_wall!(skel, eidx)
    return skel, eidx
end

@testset "Wall data model" begin

    # ── (A) One horizontal :walls edge on story 0, with a story above.
    # Why interesting: base.L must be the 4 m story height. Using the plan
    # length (10 m on the long edge) would be a silent factor-of-2.5 error
    # in pier stiffness. Endpoints must be the skeleton vertex_coords, and
    # Wall.story stays 0-based.
    @testset "A: story-0 wall uses story height and vertex_coords" begin
        skel, eidx = _office_with_wall_on(0; n_stories=1)
        h = _story_height(skel, 0)
        plan_m = _plan_length(skel, eidx)
        thk = _wall_thickness(skel)
        # The fixture is only interesting if the two lengths differ.
        @test plan_m > ustrip(u"m", h) + 1.0

        struc = _init!(BuildingStructure(skel); wall_thickness=thk)
        @test length(struc.walls) == 1
        w = only(struc.walls)

        @test w.story == 0
        @test _endpoints_match(w, struc.skeleton, eidx)
        @test w.base.L ≈ h
        @test !isapprox(ustrip(u"m", w.base.L), plan_m; atol=1e-6)
        @test isapprox(hypot(w.x2 - w.x1, w.y2 - w.y1), plan_m; atol=1e-6)
        # Thickness is the value we passed, not a stand-in default.
        @test w.thickness ≈ thk
        @test any(struc.segments[si].edge_idx == eidx for si in w.base.segment_indices)
    end

    # ── (B) That same edge is not also a Beam.
    # Why interesting: :walls is checked before the beam fall-through. A
    # double classification would put the pier in both lateral and gravity
    # member lists.
    @testset "B: a :walls edge is not also a Beam" begin
        skel, eidx = _office_with_wall_on(0; n_stories=1)
        struc = _init!(BuildingStructure(skel); wall_thickness=_wall_thickness(skel))
        @test length(struc.walls) == 1
        @test !_edge_is_beam(struc, eidx)
        w = only(struc.walls)
        wall_segs = Set(w.base.segment_indices)
        for beam in struc.beams
            @test isempty(intersect(wall_segs, Set(beam.base.segment_indices)))
        end
    end

    # ── (C) :walls present, wall_thickness omitted → throw.
    # Why interesting: there is no default thickness. Inventing one would
    # size a pier the caller never specified.
    @testset "C: omitted wall_thickness throws" begin
        skel, _ = _office_with_wall_on(0; n_stories=1)
        @test !isempty(get(skel.groups_edges, :walls, Int[]))
        struc = BuildingStructure(skel)
        # begin/end: @test_throws does not accept a trailing keyword call.
        # Match the message so a slab-sizing error cannot satisfy this case.
        @test_throws msg -> occursin("ArgumentError", msg) && occursin("wall_thickness", msg) begin
            _init!(struc; pass_thickness=false)
        end
    end

    # ── (D) Two stacked walls, same plan line, stories 0 and 1.
    # Why interesting: wall_above must point only upward. Linking the roof
    # wall back down (or to itself) would cycle the stack. n_stories = 2
    # so story 1 still has a floor above it (the roof); that upper pier is
    # the roof wall and its wall_above stays nothing.
    @testset "D: wall_above links only upward" begin
        skel = _office(; n_stories=2)
        e0s = _horizontal_beams(skel, 0)
        e1s = _horizontal_beams(skel, 1)
        keys1 = Dict(_plan_key(skel, e) => e for e in e1s)
        pair = nothing
        for e0 in e0s
            e1 = get(keys1, _plan_key(skel, e0), nothing)
            isnothing(e1) && continue
            # Prefer the long edge so the shared line is unambiguous.
            if isnothing(pair) || _plan_length(skel, e0) > _plan_length(skel, pair[1])
                pair = (e0, e1)
            end
        end
        @test pair !== nothing
        e0, e1 = pair
        _claim_as_wall!(skel, e0)
        _claim_as_wall!(skel, e1)

        struc = _init!(BuildingStructure(skel); wall_thickness=_wall_thickness(skel))
        @test length(struc.walls) == 2
        w0 = only(w for w in struc.walls if w.story == 0)
        w1 = only(w for w in struc.walls if w.story == 1)
        @test w0.story == 0
        @test w1.story == 1
        @test isapprox(wall_center(w0)[1], wall_center(w1)[1]; atol=1e-9)
        @test isapprox(wall_center(w0)[2], wall_center(w1)[2]; atol=1e-9)
        @test _endpoints_match(w0, struc.skeleton, e0)
        @test _endpoints_match(w1, struc.skeleton, e1)
        # Upward only: story 0 → story 1. The roof wall has nothing above.
        @test w0.wall_above === w1
        @test w0.wall_above.story == w0.story + 1
        @test w1.wall_above === nothing
        @test all(isnothing(w.wall_above) || w.wall_above.story > w.story
                  for w in struc.walls)
    end

    # ── (E) A wall whose center is outside the story faces.
    # Why interesting: initialize! must run the plate enclosure check and
    # fail closed. The extra pier sits at y = -25 m, fully outside the
    # [0, 10] × [0, 6] floor, and shares no edge with the slab faces.
    @testset "E: wall center outside story faces throws" begin
        skel = _office(; n_stories=1)
        z0 = skel.stories[0].elevation
        p1 = Meshes.Point(0.0u"m", -25.0u"m", z0)
        p2 = Meshes.Point(6.0u"m", -25.0u"m", z0)
        add_element!(skel, Meshes.Segment(p1, p2); group=:walls, level_idx=0)
        struc = BuildingStructure(skel)
        # begin/end: @test_throws does not accept a trailing keyword call.
        # OUTSIDE is the enclosure-check wording; any earlier ArgumentError fails this.
        @test_throws msg -> occursin("ArgumentError", msg) && occursin("OUTSIDE", msg) begin
            _init!(struc; wall_thickness=_wall_thickness(skel))
        end
    end

    # ── (F) No :walls edges. Thickness is not required, walls stays empty.
    # Why interesting: the thickness requirement is conditional. A gravity
    # frame with no wall group must still initialize.
    @testset "F: no :walls edges — thickness not required" begin
        skel = _office(; n_stories=1)
        @test isempty(get(skel.groups_edges, :walls, Int[]))
        struc = _init!(BuildingStructure(skel); pass_thickness=false)
        @test isempty(struc.walls)
        @test length(struc.beams) > 0
        @test length(struc.columns) > 0
    end

    # ── (G) to_wall_line story is Wall.story + 1.
    # Why interesting: Wall.story is 0-based and WallLine.story is 1-based.
    # Checking both a ground pier and the pier above it catches a hardcoded
    # story of 1.
    @testset "G: to_wall_line story is wall.story + 1" begin
        skel = _office(; n_stories=2)
        e0s = _horizontal_beams(skel, 0)
        e1s = _horizontal_beams(skel, 1)
        keys1 = Dict(_plan_key(skel, e) => e for e in e1s)
        e0 = e0s[findfirst(e -> haskey(keys1, _plan_key(skel, e)), e0s)]
        e1 = keys1[_plan_key(skel, e0)]
        _claim_as_wall!(skel, e0)
        _claim_as_wall!(skel, e1)
        struc = _init!(BuildingStructure(skel); wall_thickness=_wall_thickness(skel))
        for w in struc.walls
            wl = to_wall_line(w, w.story + 1, NWC_4000)
            @test wl.story == w.story + 1
        end
        @test Set(w.story for w in struc.walls) == Set((0, 1))
        @test any(to_wall_line(w, 1, NWC_4000).story == 1 for w in struc.walls if w.story == 0)
        @test any(to_wall_line(w, 2, NWC_4000).story == 2 for w in struc.walls if w.story == 1)
    end

    # ── (H) Stories at 0 m and 4 m, plus one vertex at 0.05 m on no face.
    # Why interesting: rebuild_stories! inserts a story for every unique
    # vertex Z, including a vertex that belongs to no face. Pier stiffness
    # scales as 1/H^3. Using 0.05 m (that vertex) instead of 4 m (the next
    # story whose faces are non-empty) overstates stiffness by (4/0.05)^3.
    # The case is only interesting if that faceless story actually sits
    # between the two floors.
    @testset "H: faceless vertex does not set story-0 pier height" begin
        skel, eidx = _office_with_wall_on(0; n_stories=1)
        z_before = sort!(ustrip.(u"m", skel.stories_z))
        @test z_before ≈ [0.0, 4.0]

        # Inside the 10 m × 6 m plan, on no edge and no face.
        vidx = add_vertex!(skel, Meshes.Point(1.0u"m", 1.0u"m", 0.05u"m"))
        @test all(a != vidx && b != vidx for (a, b) in skel.edge_indices)
        @test all(vidx ∉ idxs for idxs in skel.face_vertex_indices)
        # initialize! does not rebuild stories. This is the path that
        # inserts a story for a vertex that belongs to no face.
        rebuild_stories!(skel)

        z_after = sort!(ustrip.(u"m", skel.stories_z))
        @test z_after ≈ [0.0, 0.05, 4.0]
        @test eidx in skel.stories[0].edges
        @test isapprox(ustrip(u"m", skel.stories[0].elevation), 0.0; atol=1e-9)
        @test !isempty(skel.stories[0].faces)
        stray_key = only(k for (k, s) in skel.stories
                         if isapprox(ustrip(u"m", s.elevation), 0.05; atol=1e-9))
        roof_key = only(k for (k, s) in skel.stories
                        if isapprox(ustrip(u"m", s.elevation), 4.0; atol=1e-9))
        @test stray_key == 0 + 1
        @test vidx in skel.stories[stray_key].vertices
        @test isempty(skel.stories[stray_key].edges)
        @test isempty(skel.stories[stray_key].faces)
        @test all(vidx ∉ idxs for idxs in skel.face_vertex_indices)
        @test !isempty(skel.stories[roof_key].faces)
        # Next story key is the faceless vertex. The faced story is 4 m.
        naive = skel.stories[stray_key].elevation - skel.stories[0].elevation
        @test isapprox(ustrip(u"m", naive), 0.05; atol=1e-9)

        struc = _init!(BuildingStructure(skel); wall_thickness=_wall_thickness(skel))
        @test length(struc.walls) == 1
        w = only(struc.walls)
        @test w.story == 0
        @test w.base.L ≈ 4.0u"m"
        @test !isapprox(ustrip(u"m", w.base.L), 0.05; atol=1e-6)
    end

    # ── (I) One edge index in both :walls and :beams.
    # Why interesting: the wall classification must not win by dropping the
    # beam. A pier that is also a gravity beam would vanish from the beam
    # list with no error. The throw names the edge index and both groups.
    @testset "I: edge in both :walls and :beams throws" begin
        skel = _office(; n_stories=1)
        edges = _horizontal_beams(skel, 0)
        @test !isempty(edges)
        eidx = edges[argmax(_plan_length.(Ref(skel), edges))]
        walls = get!(skel.groups_edges, :walls, Int[])
        eidx in walls || push!(walls, eidx)
        @test eidx in skel.groups_edges[:walls]
        @test eidx in skel.groups_edges[:beams]
        struc = BuildingStructure(skel)
        # begin/end: @test_throws does not accept a trailing keyword call.
        # Name the edge so a thickness or enclosure error cannot satisfy this.
        @test_throws msg -> occursin("ArgumentError", msg) &&
                            occursin("edge index $eidx is in :walls", msg) &&
                            occursin(":beams", msg) begin
            _init!(struc; wall_thickness=_wall_thickness(skel))
        end
    end

    # ── (J) Faced floor at -0.05 m, floors at 0 m and 4 m, wall edge at z = 0.
    # Why interesting: edge_story's first hit inside a 0.1 m window can assign
    # the pier to a real floor 5 cm below. That floor has faces, so it is not
    # the faceless vertex in (H). Pier stiffness scales as 1/H^3. Owning the
    # wall at -0.05 m makes the next faced story the floor at 0 m and the
    # pier height 0.05 m (or 4.05 m if the height is taken up to the roof).
    # initialize_members! must keep the wall on the z = 0 floor: story
    # elevation 0 m and base.L = 4 m. The 5 cm gap is inside the 0.1 m
    # window and outside the 1e-4 m wall tolerance, so the two rules disagree.
    @testset "J: faced floor 5 cm below does not own the z=0 wall" begin
        skel, eidx = _office_with_wall_on(0; n_stories=1)
        z_before = sort!(ustrip.(u"m", skel.stories_z))
        @test z_before ≈ [0.0, 4.0]
        @test !isempty(skel.stories[0].faces)
        @test eidx in skel.stories[0].edges

        # Same 10 m × 6 m plan as the office, one story below the wall.
        # Faces are required: a vertex-only story is the case in (H).
        z_low = -0.05u"m"
        corners = [
            Meshes.Point(0.0u"m", 0.0u"m", z_low),
            Meshes.Point(10.0u"m", 0.0u"m", z_low),
            Meshes.Point(10.0u"m", 6.0u"m", z_low),
            Meshes.Point(0.0u"m", 6.0u"m", z_low),
        ]
        vids = [add_vertex!(skel, p) for p in corners]
        for i in 1:4
            add_element!(skel, vids[i], vids[mod1(i + 1, 4)]; group=:beams)
        end
        StructuralSynthesizer.add_face!(skel, Meshes.Ngon(corners...);
                                        group=:slabs, v_indices=vids)
        # initialize_members! does not rebuild stories. This inserts the
        # faced floor and shifts the z = 0 floor off story index 0.
        rebuild_stories!(skel)

        z_after = sort!(ustrip.(u"m", skel.stories_z))
        @test z_after ≈ [-0.05, 0.0, 4.0]
        low_key = only(k for (k, s) in skel.stories
                       if isapprox(ustrip(u"m", s.elevation), -0.05; atol=1e-9))
        zero_key = only(k for (k, s) in skel.stories
                        if isapprox(ustrip(u"m", s.elevation), 0.0; atol=1e-9))
        roof_key = only(k for (k, s) in skel.stories
                        if isapprox(ustrip(u"m", s.elevation), 4.0; atol=1e-9))
        @test !isempty(skel.stories[low_key].faces)
        @test !isempty(skel.stories[zero_key].faces)
        @test !isempty(skel.stories[roof_key].faces)
        @test eidx in skel.stories[zero_key].edges
        @test eidx ∉ skel.stories[low_key].edges
        v1, v2 = skel.edge_indices[eidx]
        z1 = ustrip(u"m", Meshes.coords(skel.vertices[v1]).z)
        z2 = ustrip(u"m", Meshes.coords(skel.vertices[v2]).z)
        @test isapprox(z1, 0.0; atol=1e-9)
        @test isapprox(z2, 0.0; atol=1e-9)
        # Inside edge_story's 0.1 m window; outside the wall's 1e-4 m match.
        @test abs(0.0 - (-0.05)) < 0.1
        @test abs(0.0 - (-0.05)) > 1e-4

        # Segments first: initialize_members! reads struc.segments and does
        # not build them. Thickness is the value we pass.
        struc = BuildingStructure(skel)
        initialize_segments!(struc)
        initialize_members!(struc; wall_thickness=_wall_thickness(skel))
        @test length(struc.walls) == 1
        w = only(struc.walls)
        @test w.base.L ≈ 4.0u"m"
        @test !isapprox(ustrip(u"m", w.base.L), 0.05; atol=1e-6)
        @test !isapprox(ustrip(u"m", w.base.L), 4.05; atol=1e-6)
        @test w.story == zero_key
        elev = struc.skeleton.stories[w.story].elevation
        @test isapprox(ustrip(u"m", elev), 0.0; atol=1e-9)
        @test !isapprox(ustrip(u"m", elev), -0.05; atol=1e-6)
    end
end
