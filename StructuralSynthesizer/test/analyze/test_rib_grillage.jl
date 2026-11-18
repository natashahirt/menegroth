# A ribbed floor is a quad panel plus a frame of ribs.
#
# ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101) allows the frame analysis
# when equilibrium and compatibility are satisfied. The load on each rib is
# the isotropic straight skeleton of the rectangular bays. The lines are the
# same bay counts a waffle grid uses.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SY = StructuralSynthesizer

@testset "isoparametric ribs follow the panel" begin
    rect = [(0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0)]
    lines = SY._isoparametric_rib_lines(rect, 2, 2)
    @test length(lines) == 2
    @test lines[1][1] == (3.0, 0.0)
    @test lines[1][2] == (0.0, 1.0)
    @test lines[2][1] == (0.0, 2.0)
    @test lines[2][2] == (1.0, 0.0)

    # A mid-edge vertex does not become a fifth corner.
    with_mid = [(0.0, 0.0), (3.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0)]
    @test SY._isoparametric_rib_lines(with_mid, 2, 2) == lines
    @test isempty(SY._isoparametric_rib_lines(rect, 1, 1))

    skew = [(0.0, 0.0), (6.0, 0.0), (5.0, 4.0), (1.0, 4.0)]
    skew_lines = SY._isoparametric_rib_lines(skew, 2, 2)
    @test skew_lines[2][1] == (0.5, 2.0)
    @test skew_lines[2][2] == (1.0, 0.0)

    pent = [(0.0, 0.0), (4.0, 0.0), (5.0, 2.0), (3.0, 4.0), (0.0, 3.0)]
    @test_throws ArgumentError SY._isoparametric_rib_lines(pent, 2, 2)
end

@testset "rib analysis is a named choice" begin
    mat = StructuralSizer.A992_Steel
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                    pattern = IsoparametricPattern(2, 2), material = mat)
    @test SY.rib_analysis(level) === :tributary
    level.analysis = :grillage
    @test SY.rib_analysis(level) === :grillage
    @test SY.rib_analysis("Grillage") === :grillage
    level.analysis = :waffle
    @test_throws ArgumentError SY.rib_analysis(level)
    @test_throws ArgumentError SY.rib_analysis("shell")
end

"""Iso-ξ and iso-η interior ribs of a quad, as finite segments."""
function _iso_ribs(c, nξ, nη)
    panel = StructuralSizer.IsoParametricPanel(c)
    at(ξ, η) = StructuralSizer.physical_coords(panel, ξ, η)
    ribs = Vector{NTuple{2, Float64}}[]
    for i in 1:(nξ - 1)
        push!(ribs, [at(i / nξ, 0.0), at(i / nξ, 1.0)])
    end
    for j in 1:(nη - 1)
        push!(ribs, [at(0.0, j / nη), at(1.0, j / nη)])
    end
    return ribs
end

"""Area the bay skeletons of `outline` with `ribs` give the edges."""
function _bay_area(outline, ribs)
    arr = StructuralSizer.rib_arrangement(outline, (), ribs)
    total = 0.0
    for (e, (pos, w)) in StructuralSizer.bay_edge_profiles(arr)
        a, b = arr.edges[e]
        total += StructuralSizer.tributary_profile_area(
            hypot((arr.nodes[b] .- arr.nodes[a])...), pos, w)
    end
    return total
end

@testset "bay skeletons cover the panel" begin
    rect = ((0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0))
    for (nξ, nη) in ((1, 1), (2, 2), (3, 1))
        @test _bay_area(collect(rect), _iso_ribs(rect, nξ, nη)) ≈ 24.0
    end
    # A rotated rectangle. Sides are √10 and √10, area 10.
    rotated = ((0.0, 0.0), (3.0, 1.0), (2.0, 4.0), (-1.0, 3.0))
    @test _bay_area(collect(rotated), _iso_ribs(rotated, 1, 1)) ≈ 10.0
    # A trapezoid uses the isotropic skeleton. Shoelace area is 20 m².
    skew = ((0.0, 0.0), (6.0, 0.0), (5.0, 4.0), (1.0, 4.0))
    for (nξ, nη) in ((1, 1), (2, 2))
        @test _bay_area(collect(skew), _iso_ribs(skew, nξ, nη)) ≈ 20.0 rtol = 1e-6
    end
    # A pentagon is a panel like any other. Shoelace area is 15.5 m².
    pent = [(0.0, 0.0), (4.0, 0.0), (5.0, 2.0), (3.0, 4.0), (0.0, 3.0)]
    @test _bay_area(pent, [[(2.0, 0.0), (2.0, 3.0 + 2.0 / 3.0)]]) ≈ 15.5 rtol = 1e-6
end

"""One rectangular bay: four edge beams and one one-way slab."""
function _grillage_bay(; Lx = 6.0, Ly = 4.0, z = 3.0)
    skel = BuildingSkeleton{Float64}()
    corners = [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)]
    vs = [add_vertex!(skel, [x, y, z]) for (x, y) in corners]
    for k in 1:4
        add_element!(skel, vs[k], vs[mod1(k + 1, 4)]; group = :beams)
    end
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(Lx, Ly, (0.0, 1.0), Ly)
    fidx = findfirst(f -> Set(f) == Set(vs), skel.face_vertex_indices)
    cell = Cell(fidx, Lx * Ly * u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :one_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab([1], CIPSlabResult(0.2, 0.2, 5.0), spans; floor_type = :one_way))
    return struc, vs
end

@testset "the tributary view draws the grillage pans" begin
    rect = ((0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0))
    arr = StructuralSizer.rib_arrangement(collect(rect), (), _iso_ribs(rect, 2, 2))
    loops = StructuralSizer.bay_tributary_polygons(arr)
    @test sum(StructuralSizer.polygon_area_m(poly) for (_, poly) in loops) ≈ 24.0
    counts = Dict{Int, Int}()
    for (e, _) in loops
        counts[e] = get(counts, e, 0) + 1
    end
    shared = [e for (e, n) in counts if n == 2]
    @test !isempty(shared)
    e = first(shared)
    a, b = arr.nodes[arr.edges[e][1]], arr.nodes[arr.edges[e][2]]
    sides = Float64[]
    for (ee, poly) in loops
        ee == e || continue
        c = (sum(p[1] for p in poly) / length(poly), sum(p[2] for p in poly) / length(poly))
        push!(sides, (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]))
    end
    @test prod(sides) < 0

    struc, _ = _grillage_bay()
    slab = only(struc.slabs)
    push!(slab.framing_levels, SY.FramingLevel{Float64}(
        slab_idx = 1, level = 1, pattern = IsoparametricPattern(1, 1),
        material = StructuralSizer.A992_Steel, analysis = :grillage))
    push!(slab.tributary_polygons, SY.SlabTributaryPolygon(
        1, :column, 1, [(0.0, 0.0), (6.0, 0.0), (3.0, 2.0)]))
    design = BuildingDesign(struc)
    packet = SY.ScenePacket(String[], (0.0, 0.0, 0.0),
        Dict{String, Any}("counts" => Dict{String, Any}()), SY.SceneBuffer[])
    drawn = SY._with_tributaries(packet, design)
    kinds = SY.scene_u8(drawn, "tributary_kind")
    @test kinds == UInt8[0x01, 0x01, 0x01, 0x01]
end

@testset "a grillage owns the rectangular panel" begin
    struc, vs = _grillage_bay()
    slab = only(struc.slabs)
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(1, 1),
                                     material = StructuralSizer.A992_Steel,
                                     analysis = :grillage)
    push!(slab.framing_levels, level)
    profiles = SY.grillage_edge_profiles(struc, slab, level)
    @test length(profiles) == 4
    area = 0.0
    for (e, (pos, w)) in profiles
        a, b = struc.skeleton.edge_indices[e]
        p1 = SY._vertex_xy_m(struc.skeleton, a)
        p2 = SY._vertex_xy_m(struc.skeleton, b)
        area += StructuralSizer.tributary_profile_area(hypot(p2[1] - p1[1], p2[2] - p1[2]), pos, w)
    end
    @test area ≈ 24.0
    @test SY._grillage_cells(struc) == Set(1)
    @test length(SY.exclusive_grillage_stories(struc)) == 1

    # The frame load is that same area, once.
    nodes = [Asap.Node([x * u"m", y * u"m", 3.0u"m"], fill(true, 6))
             for (x, y) in ((0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0))]
    sec = Asap.Section(0.05u"m^2", 200e9u"Pa", 77e9u"Pa",
                       1e-3u"m^4", 1e-3u"m^4", 1e-4u"m^4", 7850.0u"kg/m^3")
    els = [Asap.Element(nodes[a], nodes[b], sec) for (a, b) in struc.skeleton.edge_indices]
    dest = Asap.TributaryLoad[]
    SY._emit_grillage_loads!(Asap.AbstractLoad[], dest, els, struc, slab, level, 1000.0u"Pa")
    loaded = 0.0
    for ld in dest
        p1 = (ustrip(u"m", ld.element.nodeStart.position[1]),
              ustrip(u"m", ld.element.nodeStart.position[2]))
        p2 = (ustrip(u"m", ld.element.nodeEnd.position[1]),
              ustrip(u"m", ld.element.nodeEnd.position[2]))
        widths = [ustrip(u"m", w) for w in ld.widths]
        loaded += StructuralSizer.tributary_profile_area(hypot(p2[1] - p1[1], p2[2] - p1[2]),
                                                         ld.positions, widths)
    end
    @test loaded ≈ 24.0

    # The same emitted loads, on the corner-pinned frame, put the panel on the columns.
    pinned = [Asap.Node([x * u"m", y * u"m", 3.0u"m"], [false, false, false, true, true, true])
              for (x, y) in ((0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0))]
    pinned_els = [Asap.Element(pinned[a], pinned[b], sec) for (a, b) in struc.skeleton.edge_indices]
    frame_loads = Asap.AbstractLoad[]
    SY._emit_grillage_loads!(frame_loads, Asap.TributaryLoad[], pinned_els, struc, slab, level, 1000.0u"Pa")
    frame = Asap.Model(pinned, pinned_els, frame_loads)
    Asap.solve!(frame)
    @test sum(ustrip(u"N", n.reaction[3]) for n in pinned) ≈ 24_000.0 rtol = 1e-4

    # A second floor on the same story, without a grillage, is refused.
    spans = slab.spans
    push!(struc.cells, Cell(struc.cells[1].face_idx, 24.0u"m^2", spans,
                            2.0u"kN/m^2", 3.0u"kN/m^2"))
    push!(struc.slabs, Slab([2], CIPSlabResult(0.2, 0.2, 5.0), spans; floor_type = :one_way))
    @test_throws ArgumentError SY.exclusive_grillage_stories(struc)
end

@testset "framing leaves the building geometry hash unchanged" begin
    struc, _ = _grillage_bay()
    initialize_segments!(struc)
    initialize_members!(struc)
    before = structure_geometry_hash(struc)
    n_face = sum(length, struc.skeleton.face_vertex_indices)
    slab = only(struc.slabs)
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(2, 2),
                                     material = StructuralSizer.A992_Steel,
                                     analysis = :grillage)
    push!(slab.framing_levels, level)
    SY.materialize_level!(struc, slab, level)
    @test sum(length, struc.skeleton.face_vertex_indices) > n_face
    @test any(skel -> begin
            chain = struc.skeleton.edge_chains[skel]
            !isempty(chain) && skel == hash((:framing_host_chain, chain[1]))
        end, keys(struc.skeleton.edge_chains))
    @test structure_geometry_hash(struc) == before
end

@testset "interior ribs are part of the same panel" begin
    struc, _ = _grillage_bay()
    initialize_segments!(struc)
    initialize_members!(struc)
    slab = only(struc.slabs)
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(2, 2),
                                     material = StructuralSizer.A992_Steel,
                                     analysis = :grillage)
    push!(slab.framing_levels, level)
    joists = SY.materialize_level!(struc, slab, level)
    # Each rib is split at the crossing, so four pieces meet at the center.
    @test length(joists) == 4
    @test all(j -> length(j.base.segment_indices) == 1, joists)
    @test length(unique(level.piece_group_ids)) == 4
    @test Set(level.piece_group_ids) == Set(SY.level_sizing_group_ids(level))
    verts(j) = Set(v for si in j.base.segment_indices
                   for v in struc.skeleton.edge_indices[struc.segments[si].edge_idx])
    center = (3.0, 2.0)
    at_center = [j for j in joists if any(v -> SY._vertex_xy_m(struc.skeleton, v) == center, verts(j))]
    @test length(at_center) == 4
    for j in at_center
        si = only(j.base.segment_indices)
        a, b = struc.skeleton.edge_indices[struc.segments[si].edge_idx]
        cut = SY._vertex_xy_m(struc.skeleton, a) == center ? a : b
        rel = a == cut ? struc.segments[si].release_start : struc.segments[si].release_end
        @test rel === :fixed
    end
    profiles = SY.grillage_edge_profiles(struc, slab, level)
    area = 0.0
    for (e, (pos, w)) in profiles
        a, b = struc.skeleton.edge_indices[e]
        p1 = SY._vertex_xy_m(struc.skeleton, a)
        p2 = SY._vertex_xy_m(struc.skeleton, b)
        area += StructuralSizer.tributary_profile_area(
            hypot(p2[1] - p1[1], p2[2] - p1[2]), pos, w)
    end
    @test area ≈ 24.0
    @test length(profiles) > 4
    SY._restore_grillage_joist_profiles!(struc, level)
    for joist in joists
        @test joist.tributary_profile !== nothing
    end
end

@testset "collinear rib pieces share a bar size" begin
    struc, _ = _grillage_bay()
    initialize_segments!(struc)
    initialize_members!(struc)
    slab = only(struc.slabs)
    concrete = StructuralSizer.NWC_4000
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(2, 2),
                                     material = concrete, analysis = :grillage)
    push!(slab.framing_levels, level)
    joists = SY.materialize_level!(struc, slab, level)
    # The rib along y = 2 is two pieces. Give them different bar sizes.
    along = [b for b in joists if begin
        a, c = SY._beam_terminals(struc, b)
        pa, pc = SY._vertex_xy_m(struc.skeleton, a), SY._vertex_xy_m(struc.skeleton, c)
        pa[2] == 2.0 && pc[2] == 2.0
    end]
    @test length(along) == 2
    # ACI 318-11 §7.6.1: one layer of the shared #8 bar has to fit, and the
    # steel area cannot drop. 0.18 m holds two #8s (the four #5s). 0.25 m
    # holds the three #8s already chosen.
    light = StructuralSizer.RCTBeamSection(bw = 0.18u"m", h = 0.30u"m", bf = 0.60u"m",
                                           hf = 0.10u"m", bar_size = 5, n_bars = 4)
    heavy = StructuralSizer.RCTBeamSection(bw = 0.25u"m", h = 0.40u"m", bf = 0.80u"m",
                                           hf = 0.10u"m", bar_size = 8, n_bars = 3)
    SY.set_section!(along[1], light)
    SY.set_section!(along[2], heavy)
    As0 = [ustrip(u"inch^2", SY.section(b).As) for b in along]
    opts = StructuralSizer.ConcreteBeamOptions(material = concrete, include_flange = true)
    SY._share_collinear_rib_bars!(struc, Int[], Union{Nothing, Any}[], opts)
    # No rib groups were passed, so this call is a no-op. Drive the pieces directly.
    specs = Any[nothing for _ in struc.beams]
    gids = UInt64[]
    for b in along
        gid = SY.group_id(b)
        push!(gids, gid)
        push!(specs, SY._GroupFlange(0.10u"m", SY._MemberFlange[], nothing))
    end
    # joist_spacing must be set or the piece is skipped. A nominal spacing marks
    # them as ribs; the bar pass does not use it when geometry is not raised.
    rib_spec = SY._GroupFlange(0.10u"m", SY._MemberFlange[], 1.0u"m")
    SY._share_collinear_rib_bars!(struc, [SY.group_id(b) for b in along],
                                 [rib_spec, rib_spec], opts)
    @test all(b -> SY.section(b).bar_size == 8, along)
    for (b, a0) in zip(along, As0)
        @test ustrip(u"inch^2", SY.section(b).As) + 1e-9 >= a0
    end
    @test SY.section(along[1]).n_bars <= SY.section(along[2]).n_bars ||
        ustrip(u"m", SY.section(along[1]).bw) != ustrip(u"m", SY.section(along[2]).bw)
    # The lighter piece does not inherit the heavier piece's whole section.
    @test ustrip(u"m", SY.section(along[1]).bw) ≈ 0.18
    @test ustrip(u"m", SY.section(along[2]).h) ≈ 0.40
    # The head is one region: its soffit is the deepest rib, and the web
    # check uses the narrower rib.
    web = SY._sized_rib_web(struc, level)
    @test ustrip(u"m", web[1]) ≈ 0.18
    @test ustrip(u"m", web[3]) ≈ 0.40
    @test ustrip(u"m", SY._sized_rib_depth(struc, level)) ≈ 0.40
end

@testset "a shared-bar rib section is checked before it is installed" begin
    struc, _ = _grillage_bay()
    initialize_segments!(struc)
    initialize_members!(struc)
    slab = only(struc.slabs)
    concrete = StructuralSizer.NWC_4000
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(2, 2),
                                     material = concrete, analysis = :grillage)
    push!(slab.framing_levels, level)
    joists = SY.materialize_level!(struc, slab, level)
    along = [b for b in joists if begin
        a, c = SY._beam_terminals(struc, b)
        pa, pc = SY._vertex_xy_m(struc.skeleton, a), SY._vertex_xy_m(struc.skeleton, c)
        pa[2] == 2.0 && pc[2] == 2.0
    end]
    @test length(along) == 2
    light = StructuralSizer.RCTBeamSection(bw = 0.18u"m", h = 0.30u"m", bf = 0.60u"m",
                                           hf = 0.10u"m", bar_size = 5, n_bars = 4)
    heavy = StructuralSizer.RCTBeamSection(bw = 0.25u"m", h = 0.40u"m", bf = 0.80u"m",
                                           hf = 0.10u"m", bar_size = 8, n_bars = 3)
    opts = StructuralSizer.ConcreteBeamOptions(material = concrete, include_flange = true)
    rib_spec = SY._GroupFlange(0.10u"m", SY._MemberFlange[], 1.0u"m")
    gids = [SY.group_id(b) for b in along]
    geom = StructuralSizer.ConcreteMemberGeometry(2.0)
    demand_check(Mu) = (mi, sec) -> StructuralSizer.check_tbeam_section(
        sec, Mu, 10.0u"kN", geom, opts; Mu_neg = 0.0u"kN*m")

    # A demand the light piece's #8 section carries: it is installed and its
    # check is the one reported for it.
    SY.set_section!(along[1], light)
    SY.set_section!(along[2], heavy)
    SY._share_collinear_rib_bars!(struc, gids, [rib_spec, rib_spec], opts;
                                 recheck = demand_check(20.0u"kN*m"))
    @test SY.section(along[1]).bar_size == 8
    expl = SY.member_check(along[1])
    @test expl !== nothing
    @test expl.passed
    flex = only(c for c in expl.checks if c.name == "flexure")
    @test flex.ratio > 0

    # A demand above the swapped section's capacity: the piece keeps the
    # section the sizer gave it.
    φMn_kipft = StructuralSizer._compute_φMn(
        StructuralSizer.RCTBeamSection(bw = 0.18u"m", h = 0.30u"m", bf = 0.60u"m",
                                       hf = 0.10u"m", bar_size = 8, n_bars = 2),
        4000.0, 60000.0)
    SY.set_section!(along[1], light)
    SY.set_section!(along[2], heavy)
    over = 1.5 * φMn_kipft * StructuralSizer.kip * u"ft"
    SY._share_collinear_rib_bars!(struc, gids, [rib_spec, rib_spec], opts;
                                 recheck = demand_check(over))
    @test SY.section(along[1]) === light
end

@testset "a solid head cuts the beams that cross it" begin
    struc, _ = _grillage_bay()
    initialize_segments!(struc)
    initialize_members!(struc)
    before = structure_geometry_hash(struc)
    n_girders = length(struc.beams)
    slab = only(struc.slabs)
    # 0.2 snaps to one module, 0.25, on a 4×4 grid.
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(4, 4, 0.2),
                                     material = StructuralSizer.A992_Steel,
                                     analysis = :grillage)
    push!(slab.framing_levels, level)
    joists = SY.materialize_level!(struc, slab, level)
    @test level.pattern.solid_head ≈ 0.25
    @test structure_geometry_hash(struc) == before
    @test level.solid_group_id !== nothing
    @test !(level.solid_group_id in SY.level_sizing_group_ids(level))
    @test level.solid_group_id in SY.level_group_ids(level)

    solid_idx = struc.member_groups[level.solid_group_id].member_indices
    @test !isempty(solid_idx)
    # The four girders stay the piece between the heads: 3 m on the 6 m sides,
    # 2 m on the 4 m sides.
    for bi in 1:n_girders
        @test !(bi in solid_idx)
    end
    girder_L = sort!(Float64[let L = struc.beams[bi].base.L
                              L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
                          end for bi in 1:n_girders])
    @test girder_L ≈ [2.0, 2.0, 3.0, 3.0]
    # A rib at the head line is three beams, and the cut is continuous.
    @test length(joists) > 6
    solid_joists = [b for b in joists if SY.group_id(b) == level.solid_group_id]
    rib_joists = [b for b in joists if SY.group_id(b) != level.solid_group_id]
    @test !isempty(solid_joists)
    @test !isempty(rib_joists)
    function ends_of(beam)
        vs = Int[]
        for si in SY.segment_indices(beam)
            a, b = struc.skeleton.edge_indices[struc.segments[si].edge_idx]
            push!(vs, a, b)
        end
        return vs
    end
    shared = false
    for solid_b in solid_joists, rib_b in rib_joists
        !isempty(intersect(ends_of(solid_b), ends_of(rib_b))) || continue
        shared = true
        cut = only(intersect(ends_of(solid_b), ends_of(rib_b)))
        for si in SY.segment_indices(solid_b)
            a, b = struc.skeleton.edge_indices[struc.segments[si].edge_idx]
            (a == cut || b == cut) || continue
            rel = a == cut ? struc.segments[si].release_start : struc.segments[si].release_end
            @test rel === :fixed
        end
    end
    @test shared

    profiles = SY.grillage_edge_profiles(struc, slab, level)
    area = 0.0
    for (e, (pos, w)) in profiles
        a, b = struc.skeleton.edge_indices[e]
        p1 = SY._vertex_xy_m(struc.skeleton, a)
        p2 = SY._vertex_xy_m(struc.skeleton, b)
        area += StructuralSizer.tributary_profile_area(
            hypot(p2[1] - p1[1], p2[2] - p1[2]), pos, w)
    end
    @test area ≈ 24.0

    # Gross stiffness at the full depth. The topping is already in the panel
    # pressure, so the two families weigh only the projection below it.
    # Four heads, 1.5 m by 1 m. Depth 0.3 m, topping 0.1 m, projection 0.2 m.
    concrete = StructuralSizer.NWC_4000
    depth = 0.3u"m"
    topping = 0.1u"m"
    sections = SY.assign_solid_head_sections!(struc, level, depth, concrete; topping = topping)
    @test length(sections) == length(solid_idx)
    mass = 0.0
    ρ_head = concrete.ρ * ((depth - topping) / depth) / 2
    for (bi, sec) in sections
        @test sec.ρ ≈ ρ_head
        w = sec.A / depth
        @test sec.Iy ≈ w * depth^3 / 12
        L = struc.beams[bi].base.L
        Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
        mass += ustrip(u"kg/m^3", sec.ρ) * ustrip(u"m^2", sec.A) * Lm
    end
    @test mass ≈ ustrip(u"kg/m^3", concrete.ρ) * 4 * 1.5 * 1.0 * 0.2
    flush = SY.assign_solid_head_sections!(struc, level, depth, concrete; topping = depth)
    for (_, sec) in flush
        @test ustrip(u"kg/m^3", sec.ρ) == 0.0
        w = sec.A / depth
        @test sec.Iy ≈ w * depth^3 / 12
    end
    @test_throws ArgumentError SY.assign_solid_head_sections!(
        struc, level, depth, concrete; topping = 0.4u"m")

    # The sized rib sets the soffit. The bay's CIP slab is 0.2 m, so the
    # projection below that sheet is 0.1 m, and the frame element receives it.
    rib = StructuralSizer.RCTBeamSection(bw = 0.15u"m", h = depth, bf = 0.6u"m",
                                         hf = 0.2u"m", bar_size = 5, n_bars = 2)
    SY.set_section!(rib_joists[1], rib)
    level.material = concrete
    hung = SY.apply_solid_head_frame_sections!(struc)
    @test length(hung) == length(solid_idx)
    ρ_hung = concrete.ρ * (0.1u"m" / depth) / 2
    for sec in values(hung)
        @test sec.ρ ≈ ρ_hung
    end
    max_e = 0
    for bi in solid_idx
        for si in SY.segment_indices(struc.beams[bi])
            max_e = max(max_e, struc.segments[si].edge_idx)
        end
    end
    n0 = Asap.Node([0.0u"m", 0.0u"m", 3.0u"m"], fill(true, 6))
    n1 = Asap.Node([1.0u"m", 0.0u"m", 3.0u"m"], fill(true, 6))
    blank = Asap.Section(0.01u"m^2", 30.0e9u"Pa", 13.0e9u"Pa",
                         1.0e-4u"m^4", 1.0e-4u"m^4", 1.0e-4u"m^4", 7850.0u"kg/m^3")
    while length(struc.asap_model.frame_elements) < max_e
        push!(struc.asap_model.frame_elements, Asap.Element(n0, n1, blank, :stand_in))
    end
    hung = SY.apply_solid_head_frame_sections!(struc)
    bi0 = first(solid_idx)
    e0 = struc.segments[first(SY.segment_indices(struc.beams[bi0]))].edge_idx
    @test struc.asap_model.frame_elements[e0].section.ρ ≈ hung[bi0].ρ
    @test struc.asap_model.frame_elements[e0].section.Iy ≈ hung[bi0].Iy

    @test_throws ArgumentError IsoparametricPattern(4, 4, 0.6)
    api = SY.APIParams(framing_levels = [
        SY.APIFramingLevel(material = "concrete", analysis = "grillage",
                           n_xi = 4, n_eta = 4, solid_head = 0.2)])
    opts = SY._resolve_framing_opts(api)
    @test opts.solid_head ≈ 0.2
    @test opts.n_xi == 4
    @test_throws ErrorException SY._resolve_framing_opts(SY.APIParams(framing_levels = [
        SY.APIFramingLevel(material = "concrete", analysis = "tributary", solid_head = 0.2)]))
end

@testset "rectangle grillage equilibrium" begin
    q = 1000.0
    Lx, Ly = 6.0, 4.0
    for (nξ, nη) in ((1, 1), (2, 2))
        solved = SY.analyze_rectangle_grillage(Lx, Ly, nξ, nη, q)
        total = sum(solved.corner_reactions)
        @test length(solved.corner_reactions) == 4
        @test total ≈ q * Lx * Ly rtol = 1e-6
        for r in solved.corner_reactions
            @test r ≈ total / 4 rtol = 1e-6
        end
    end
    @test_throws ArgumentError SY.analyze_rectangle_grillage(0.0, 4.0, 1, 1, q)
    @test_throws ArgumentError SY.analyze_rectangle_grillage(6.0, 4.0, 0, 1, q)
    @test_throws ArgumentError SY.analyze_rectangle_grillage(6.0, 4.0, 2, 2, q; solid_head = 0.25)
end

@testset "a solid head is the gross rectangle" begin
    q = 1000.0
    solved = SY.analyze_rectangle_grillage(6.0, 4.0, 4, 4, q;
                                           solid_head = 0.25, depth = 0.3u"m",
                                           concrete = NWC_4000)
    @test sum(solved.corner_reactions) ≈ q * 6.0 * 4.0 rtol = 1e-6
    n_solid = 0
    for (piece, el) in zip(solved.network.pieces, solved.model.frame_elements)
        piece.solid || continue
        n_solid += 1
        h = 0.3u"m"
        b = el.section.A / h
        @test (b ≈ 0.75u"m" || b ≈ 0.5u"m")
        @test el.section.Iy ≈ b * h^3 / 12
        @test el.section.Az ≈ (5 / 6) * el.section.A
        @test isfinite(ustrip(u"m^2", el.section.Az))
    end
    @test n_solid > 0
end

@testset "a rib sags by the beam formula" begin
    # Uniform 1 m × 1000 Pa on 6 m. Two Hermitian elements recover the
    # nodal value 5 w L^4 / 384 E I. Both bending inertias are 1e-3 m^4
    # and E is 30 GPa, the stand-in section in analyze_simply_supported_rib.
    solved = SY.analyze_simply_supported_rib([0.0, 6.0], [1.0, 1.0], 1000.0)
    nodes = sort(solved.model.nodes; by = n -> ustrip(u"m", n.position[1]))
    sag = SY.downward_sag(nodes)
    Δ = 5 * 1000.0 * 6.0^4 / (384 * 30.0e9 * 1.0e-3)
    @test sag ≈ Δ * u"m" rtol = 1e-3
    # The rectangle frame, not a story shell, supplies the rib sag.
    grid = SY.analyze_rectangle_grillage(6.0, 4.0, 2, 2, 1000.0)
    sags = SY.grillage_rib_sags(grid)
    @test length(sags) == (2 + 1) + (2 + 1)
    @test all(s.sag > 0.0u"m" for s in sags)
end

@testset "a simply-supported rib matches the trapezoid" begin
    # 6 m edge, widths [0, 2, 2, 0] m, 1000 Pa. Each reaction is 4000 N.
    # M(3 m) = 7666.667 N·m.
    solved = SY.analyze_simply_supported_rib([0.0, 2.0, 4.0, 6.0], [0.0, 2.0, 2.0, 0.0], 1000.0)
    @test solved.reaction_start ≈ 4000.0 rtol = 1e-5
    @test solved.reaction_end ≈ 4000.0 rtol = 1e-5
    @test solved.end_shear ≈ 4000.0 rtol = 1e-4
    @test solved.midspan_moment ≈ 7666.6667 rtol = 1e-4
end

@testset "an isotropic bay matches the rectangle" begin
    rect = ((0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0))
    iso = StructuralSizer._isotropic_rib_tributaries(rect, 2, 2)
    closed = StructuralSizer.rectangle_rib_tributaries(6.0, 4.0, 2, 2)
    @test length(iso) == length(closed)
    for (a, b) in zip(iso, closed)
        @test StructuralSizer.tributary_profile_area(1.0, a.positions, a.widths) ≈
              StructuralSizer.tributary_profile_area(1.0, b.positions, b.widths) rtol = 1e-3
        @test maximum(a.widths) ≈ maximum(b.widths) rtol = 1e-3
    end
end

@testset "the topping spans the rib bay" begin
    skel = gen_medium_office(6.0u"m", 4.0u"m", 3.0u"m", 1, 1, 1)
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions(),
                rib_bays = (2, 2), joists_planned = true)
    floors = [s for s in struc.slabs if s.floor_type == :one_way]
    @test !isempty(floors)
    for slab in floors
        span = slab.design_details.topping_span
        @test (span ≈ 3.0u"m" || span ≈ 2.0u"m")
        @test ustrip(u"m", StructuralSizer.total_depth(slab.result)) < 0.16
        bars = slab.design_details.topping_bars
        @test bars.bars !== nothing
        @test bars.bars.pos.As_provided > 0.0u"m^2"
        @test bars.bars.int_neg.As_provided >= bars.bars.pos.As_provided
    end
end

@testset "isoparametric spacing is the larger bay" begin
    struc, _ = _grillage_bay()
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(2, 2),
                                     material = StructuralSizer.A992_Steel)
    @test SY._rib_spacing_m(struc, level) ≈ 3.0
    level.pattern = IsoparametricPattern(1, 1)
    @test SY._rib_spacing_m(struc, level) ≈ 6.0
end

@testset "a curved rib is the curve" begin
    gen = _ -> begin
        pts = NTuple{2, Float64}[]
        for k in 0:16
            x = 6.0 * k / 16
            push!(pts, (x, 2.0 + 0.4 * sin(pi * x / 6.0)))
        end
        return [pts]
    end
    @test CustomPattern(gen).sagitta == 0.0
    function _lay(pattern)
        bay, _ = _grillage_bay()
        level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1, pattern = pattern,
                                         material = StructuralSizer.A992_Steel)
        return SY.materialize_level!(bay, only(bay.slabs), level)
    end
    one = _lay(CustomPattern(gen))
    @test length(one) == 1
    @test length(segment_indices(one[1])) == 1
    many = _lay(CustomPattern(gen, 0.05))
    @test length(many) == 1
    @test length(segment_indices(many[1])) > 1
end

@testset "a solid head is stored on the slab" begin
    struc, vs = _grillage_bay()
    initialize_segments!(struc)
    initialize_members!(struc)
    slab = only(struc.slabs)
    concrete = StructuralSizer.NWC_4000
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(4, 4, 0.25),
                                     material = concrete, analysis = :grillage)
    push!(slab.framing_levels, level)
    joists = SY.materialize_level!(struc, slab, level)
    rib = StructuralSizer.RCTBeamSection(bw = 0.15u"m", h = 0.30u"m", bf = 0.6u"m",
                                         hf = 0.2u"m", bar_size = 5, n_bars = 2)
    placed = false
    for beam in joists
        SY.group_id(beam) == level.solid_group_id && continue
        SY.set_section!(beam, rib)
        placed = true
        break
    end
    @test placed
    for v in vs
        push!(struc.columns, Column{Float64}(
            base = MemberBase{Float64}(L = 3.0, Lb = 3.0),
            vertex_idx = v, c1 = 0.4, c2 = 0.4))
    end
    rects = SY.solid_head_rectangles_m(struc)
    @test !isempty(rects)
    @test all(r -> r[1] > 0 && isapprox(r[2], 0.3; atol = 1e-9), values(rects))
    result = SlabDesignResult(thickness = 0.2u"m", self_weight = 5.0u"kPa")
    SY.record_solid_head_punching!(result, struc, slab, DesignParameters())
    @test result.punching_max_ratio > 0
    @test result.punching_vu_max_psi > 0
    @test occursin("released-corner", result.analysis_status)
    @test result.qu !== nothing
    # The ratio is this panel. An open grid does not invent one.
    level.pattern = IsoparametricPattern(4, 4, 0.0)
    open = SlabDesignResult(thickness = 0.2u"m", self_weight = 5.0u"kPa")
    SY.record_solid_head_punching!(open, struc, slab, DesignParameters())
    @test open.punching_max_ratio == 0.0
    @test open.analysis_status == ""
end

@testset "the building casts solid heads from the rib bays and grows them" begin
    struc, vs = _grillage_bay()
    initialize_segments!(struc)
    initialize_members!(struc)
    slab = only(struc.slabs)
    concrete = StructuralSizer.NWC_4000
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(4, 4, 0.25),
                                     material = concrete, analysis = :grillage)
    push!(slab.framing_levels, level)
    joists = SY.materialize_level!(struc, slab, level)
    # Narrow ribs under a heavy live load. The corner fraction is one bay;
    # a failing check grows that bay.
    rib = StructuralSizer.RCTBeamSection(bw = 0.05u"m", h = 0.25u"m", bf = 0.40u"m",
                                         hf = 0.08u"m", bar_size = 5, n_bars = 2)
    for beam in joists
        SY.group_id(beam) == level.solid_group_id && continue
        SY.set_section!(beam, rib)
    end
    struc.cells[1].live_load = 15.0u"kN/m^2"
    for v in vs
        push!(struc.columns, Column{Float64}(
            base = MemberBase{Float64}(L = 3.0, Lb = 3.0),
            vertex_idx = v, c1 = 0.4, c2 = 0.4))
    end
    seeded = [length(h.bays) for h in SY._initial_solid_heads(
        struc, slab, level, SY.grillage_bays(struc, slab, level)[1])]
    changed = SY.grow_building_solid_heads!(struc, DesignParameters())
    report = level.solid_head_report
    println("building heads: changed=", changed, " steps=", report.steps,
            " bays=", [length(h.bays) for h in level.solid_heads],
            " stop=", report.stop,
            " ratio=", [round(r; digits = 2) for r in report.ratios])
    @test report !== nothing
    @test length(level.solid_heads) == 4
    @test seeded == [1, 1, 1, 1]
    @test all(length(h.bays) >= 1 for h in level.solid_heads)
    @test sum(length(h.bays) for h in level.solid_heads) >= sum(seeded)
    bays = [copy(h.bays) for h in level.solid_heads]
    @test SY.grow_building_solid_heads!(struc, DesignParameters()) == false
    @test [h.bays for h in level.solid_heads] == bays
    result = SlabDesignResult(thickness = 0.2u"m", self_weight = 5.0u"kPa")
    SY.record_solid_head_punching!(result, struc, slab, DesignParameters())
    @test occursin("rib frame", result.analysis_status)
    @test result.punching_max_ratio ≈ maximum(report.ratios)
end

"""How many frame elements of `packet` meet node `node` (1-based)."""
function _scene_node_degree(packet, node::Int)
    pairs = SY.scene_u32(packet, "element_nodes")
    n = 0
    for k in 1:2:length(pairs)
        (Int(pairs[k]) + 1 == node || Int(pairs[k + 1]) + 1 == node) && (n += 1)
    end
    return n
end

@testset "a grillage scene draws the slab on the rib nodes" begin
    struc, vs = _grillage_bay()
    struc.skeleton.groups_vertices[:support] = copy(vs)
    initialize_segments!(struc)
    initialize_members!(struc)
    slab = only(struc.slabs)
    level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1,
                                     pattern = IsoparametricPattern(2, 2),
                                     material = StructuralSizer.NWC_4000,
                                     analysis = :grillage)
    push!(slab.framing_levels, level)
    SY.materialize_level!(struc, slab, level)
    to_asap!(struc; diaphragms = :none)
    design = BuildingDesign(struc)

    build_analysis_model!(design)
    @test SY.analysis_scene_kind(design.asap_model) === :grillage
    # One cross divides the bay into four panels. Each panel is two triangles
    # of the solved nodes, and those triangles were not solved again.
    shells = design.asap_model.shell_elements
    @test length(shells) == 8
    frame_nodes = Set(objectid(n) for n in design.asap_model.nodes)
    @test all(sh.elementID == 0 for sh in shells)
    @test all(objectid(n) in frame_nodes for sh in shells for n in sh.nodes)
    @test length(design.asap_model.nodes) == length(struc.asap_model.nodes)
    packet = build_scene(design)
    @test packet.meta["analysis_model"] == "grillage"
    @test get(packet.meta["counts"], "shell_triangles", 0) == 8
    @test all(b -> b.name != "shell_surface_stress", packet.buffers)
    # The two ribs cross at the panel centre and share that node.
    pos = SY.scene_f32(packet, "node_position")
    origin = packet.origin
    best, best_d = 0, Inf
    for i in 1:(length(pos) ÷ 3)
        d = hypot(Float64(pos[3i - 2]) + origin[1] - 3.0,
                  Float64(pos[3i - 1]) + origin[2] - 2.0)
        d < best_d && ((best, best_d) = (i, d))
    end
    @test best_d < 1e-3
    @test _scene_node_degree(packet, best) >= 3
end
