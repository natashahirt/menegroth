# Phase 5 smoke test — framing auto-generation (populate_levels! /
# derive_framing_level / materialize_level!).
#
# Exercises the Phase-5 machinery of the joists-roles-materials plan against a
# synthetic BuildingStructure with four disjoint single-bay slabs of different
# floor types:
#   - :mass_timber_joist  → LinearAxisPattern auto-derived from the joist result
#   - :joist_roof_deck    → a MANUALLY attached FramingLevel (tests manual
#                            respect + catalog_override propagation)
#   - :two_way            → opts-schema LinearAxisPattern (perp to span axis)
#   - :flat_plate         → no framing (derive returns nothing)
#
# Verifies: level counts per slab, joist Beam role/level/lateral_role/material,
# the per-level MemberGroup + catalog_override propagation, host-member
# subdivision (multi-segment chains), and idempotence.
#
# Run:
#   SS_ENABLE_VISUALIZATION=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_phase5_populate_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap  # units

# A minimal Timber material (values irrelevant — only the type/identity matter
# for these assertions; mirrors StructuralSizer/test/members/test_defaults.jl).
const SMOKE_TIMBER = Timber(:douglas_fir, :no1,
                            12.4e3u"MPa", 6.6e3u"MPa", 6.9u"MPa", 4.6u"MPa",
                            1.2u"MPa", 11.7u"MPa", 4.3u"MPa", 470.0u"kg/m^3", 0.31)

"""Build one rectangular single-story bay at x-origin `x0`; return its four
CCW floor-vertex indices `(a, b, c, d)`. All four beams are added to `:beams`."""
function build_bay!(skel; x0::Float64, Lx::Float64 = 8.0, Ly::Float64 = 6.0, z::Float64 = 3.0)
    a = add_vertex!(skel, [x0,       0.0, z])
    b = add_vertex!(skel, [x0 + Lx,  0.0, z])
    c = add_vertex!(skel, [x0 + Lx,  Ly,  z])
    d = add_vertex!(skel, [x0,       Ly,  z])
    add_element!(skel, a, b; group = :beams)
    add_element!(skel, b, c; group = :beams)
    add_element!(skel, c, d; group = :beams)
    add_element!(skel, d, a; group = :beams)
    return (a, b, c, d)
end

"""Build one rectangular bay whose bottom and top edges are each SPLIT at their
midpoint (x = x0 + Lx/2), so a joist laid out through the mid column lands on the
existing mid vertex (u = 0/1) instead of an edge interior. Returns the six
boundary vertices (CCW) plus the bottom-mid vertex + its (x, y).

Used for the endpoint-landing regression: a joist through the mid column must
REUSE the mid vertex, not create a coincident duplicate."""
function build_split_bay!(skel; x0::Float64, Lx::Float64 = 8.0, Ly::Float64 = 6.0, z::Float64 = 3.0)
    a  = add_vertex!(skel, [x0,          0.0, z])
    m0 = add_vertex!(skel, [x0 + Lx / 2, 0.0, z])   # bottom-edge midpoint
    b  = add_vertex!(skel, [x0 + Lx,     0.0, z])
    c  = add_vertex!(skel, [x0 + Lx,     Ly,  z])
    m1 = add_vertex!(skel, [x0 + Lx / 2, Ly,  z])   # top-edge midpoint
    d  = add_vertex!(skel, [x0,          Ly,  z])
    add_element!(skel, a,  m0; group = :beams)
    add_element!(skel, m0, b;  group = :beams)
    add_element!(skel, b,  c;  group = :beams)
    add_element!(skel, c,  m1; group = :beams)
    add_element!(skel, m1, d;  group = :beams)
    add_element!(skel, d,  a;  group = :beams)
    return (verts = (a, m0, b, c, m1, d), mid = m0, mid_xy = (x0 + Lx / 2, 0.0))
end

"""Skeleton face index whose vertex set equals `corners`."""
function face_for_corners(skel, corners)
    want = Set(corners)
    idx = findfirst(vs -> Set(vs) == want, skel.face_vertex_indices)
    idx === nothing && error("no face found for corners $corners")
    return idx
end

"""Count skeleton vertices within `r` (planar) of `(x, y)`."""
function count_vertices_near(skel, x::Float64, y::Float64; r::Float64 = 1e-5)
    vc = skel.geometry.vertex_coords
    return count(v -> hypot(vc[v, 1] - x, vc[v, 2] - y) < r, 1:size(vc, 1))
end

"""Sum of a beam's tributary-profile widths (0 when it has no profile)."""
function trib_width_sum(beam)
    prof = beam.tributary_profile
    prof === nothing && return 0.0
    return sum(w -> w isa Unitful.Quantity ? ustrip(u"m", w) : Float64(w), prof.widths)
end

"""A beam's tributary profile as `(widths_m::Vector{Float64}, integral_m::Float64)`
for idempotence snapshots. `integral_m = ∫₀¹ w(s) ds` in meters; a beam with no
profile snapshots to `(Float64[], 0.0)`."""
function trib_snapshot(beam)
    prof = beam.tributary_profile
    prof === nothing && return (Float64[], 0.0)
    widths_m = Float64[w isa Unitful.Quantity ? ustrip(u"m", w) : Float64(w)
                       for w in prof.widths]
    avg = StructuralSynthesizer.tributary_average(prof)   # ∫₀¹ w(s) ds, width unit
    integral_m = avg isa Unitful.Quantity ? ustrip(u"m", avg) : Float64(avg)
    return (widths_m, integral_m)
end

"""Snapshot every beam's tributary profile: index → (widths_m, integral_m)."""
trib_snapshot_all(struc) =
    Dict(i => trib_snapshot(struc.beams[i]) for i in eachindex(struc.beams))

"""Assert two tributary snapshots are pointwise equal: identical beam set,
matching width lists (exact), and integrals equal to `rtol` relative."""
function assert_snapshots_equal(a, b; rtol::Float64 = 1e-9)
    @test Set(keys(a)) == Set(keys(b))
    for i in keys(a)
        wa, ia = a[i]
        wb, ib = b[i]
        @test length(wa) == length(wb)
        @test wa == wb                                    # widths list matches exactly
        @test isapprox(ia, ib; rtol = rtol, atol = 1e-12) # integral matches to rtol
    end
end

@testset "Phase 5 — framing auto-generation" begin
    # ── Geometry: four disjoint bays on one story ──────────────────────────
    skel = BuildingSkeleton{Float64}()
    corners_mtj = build_bay!(skel; x0 = 0.0)
    corners_jrd = build_bay!(skel; x0 = 12.0)
    corners_2w  = build_bay!(skel; x0 = 24.0)
    corners_fp  = build_bay!(skel; x0 = 36.0)
    # Split bay for the endpoint-landing regression: :two_way with span axis
    # (1,0) and opts.spacing = 4 lays exactly one joist through x = x0 + 4, which
    # is the bottom/top mid column — it must reuse that vertex, not duplicate it.
    split_bay   = build_split_bay!(skel; x0 = 48.0)

    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)

    # ── Cells + Slabs (one cell/slab per bay) ─────────────────────────────
    A  = 48.0u"m^2"
    dl = 2.0u"kN/m^2"
    ll = 3.0u"kN/m^2"

    # Span axes: (1,0) for the timber & two-way bays; (0,1) for the roof deck.
    spans_mtj = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)
    spans_jrd = SpanInfo{Float64}(6.0, 8.0, (0.0, 1.0), 7.0)
    spans_2w  = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)
    spans_fp  = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)

    mtj_result = TimberJoistResult("GLT 175x400", 0.4, ustrip(u"m", 600.0u"mm"),
                                   "CLT panel", 0.44, 0.05, 1.2)
    jrd_result = JoistDeckResult("22K6", 0.55, ustrip(u"m", 4.0u"ft"),
                                 "1.5B deck", 0.04, 0.59, 0.02, 0.8)
    cip_2w     = CIPSlabResult(0.2, 0.2, 5.0)
    cip_fp     = CIPSlabResult(0.2, 0.2, 5.0)

    function push_bay_slab!(corners, result, floor_type, spans)
        fidx = face_for_corners(skel, corners)
        cell = Cell(fidx, A, spans, dl, ll)
        cell.floor_type = floor_type   # real pipeline sets this during initialize!
        push!(struc.cells, cell)
        cidx = length(struc.cells)
        slab = Slab{Float64}([cidx], result, floor_type, spans, :interior,
                             nothing, MaterialVolumes(), nothing, nothing,
                             FramingLevel{Float64}[])
        push!(struc.slabs, slab)
        return slab
    end

    slab_mtj = push_bay_slab!(corners_mtj, mtj_result, :mass_timber_joist, spans_mtj)
    slab_jrd = push_bay_slab!(corners_jrd, jrd_result, :joist_roof_deck, spans_jrd)
    slab_2w  = push_bay_slab!(corners_2w,  cip_2w,     :two_way,          spans_2w)
    slab_fp  = push_bay_slab!(corners_fp,  cip_fp,     :flat_plate,       spans_fp)
    # Split bay: :two_way, span axis (1,0) ⇒ joists run perpendicular (along y)
    # at x = x0 + Lx/2, landing on the bottom/top mid vertices.
    cip_split  = CIPSlabResult(0.2, 0.2, 5.0)
    spans_split = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)
    slab_split = push_bay_slab!(split_bay.verts, cip_split, :two_way, spans_split)

    # ── Host members (level-0 girders): one Segment + Beam per boundary edge.
    # In the real pipeline `initialize_members!` builds these; here we build
    # them directly so materialize_level! has hosts to land joists on.
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        seg_idx = length(struc.segments)
        push!(struc.beams, Beam([seg_idx], L; role = :girder, level = 0))
    end
    n_host_beams = length(struc.beams)

    # ── Manually attach a roof-deck level to test catalog_override + manual
    # respect. A distinct sentinel object stands in for a section catalog.
    owsj_catalog = (:owsj_only, ["22K6", "24K7"])
    manual_jrd = FramingLevel{Float64}(
        slab_idx = 0, level = 1,
        pattern = LinearAxisPattern{Float64}((0.0, 1.0), ustrip(u"m", 4.0u"ft"), nothing),
        role = :joist, material = A992_Steel, catalog_override = owsj_catalog)
    attach_framing_level!(struc, slab_jrd, manual_jrd)

    opts = (materials = (steel = A992_Steel, timber = SMOKE_TIMBER, concrete = NWC_4000),
            spacing = 4.0)

    # Snapshot host-beam tributary widths BEFORE auto-generation (all `nothing`
    # ⇒ sum 0) so the level-0 accumulation assertion has a baseline.
    host_trib_before = Dict(i => trib_width_sum(struc.beams[i]) for i in 1:n_host_beams)
    # Vertex count near the split-bay mid column before joists land there.
    n_mid_before = count_vertices_near(skel, split_bay.mid_xy[1], split_bay.mid_xy[2])

    # ── Run auto-generation ───────────────────────────────────────────────
    populate_levels!(struc; opts = opts)

    @testset "(c) framing level counts per slab type" begin
        @test length(slab_mtj.framing_levels) == 1
        @test length(slab_jrd.framing_levels) == 1
        @test length(slab_2w.framing_levels)  == 1
        @test length(slab_fp.framing_levels)  == 0        # flat_plate → nothing
    end

    @testset "(d) generated joist Beams: role / level / lateral_role / material" begin
        joists = [b for b in struc.beams if StructuralSynthesizer.level_of(b) == 1]
        @test !isempty(joists)
        @test all(b -> b.role === :joist, joists)
        @test all(b -> b.level == 1, joists)
        @test all(b -> StructuralSynthesizer.lateral_role_of(b) === :gravity, joists)

        # Material is recorded on the beam's volumes (zero volume until sizing).
        mtj_gid = slab_mtj.framing_levels[1].group_id
        jrd_gid = slab_jrd.framing_levels[1].group_id
        w2_gid  = slab_2w.framing_levels[1].group_id
        for b in joists
            vols = StructuralSynthesizer.volumes(b)
            gid = StructuralSynthesizer.group_id(b)
            if gid == mtj_gid
                @test haskey(vols, SMOKE_TIMBER)
            elseif gid == jrd_gid || gid == w2_gid
                @test haskey(vols, A992_Steel)
            end
        end
    end

    @testset "(e) MemberGroup created + catalog_override propagated" begin
        # Every materialized level stamped a group_id and registered a group.
        for slab in (slab_mtj, slab_jrd, slab_2w)
            gid = slab.framing_levels[1].group_id
            @test gid !== nothing
            @test haskey(struc.member_groups, gid)
            grp = struc.member_groups[gid]
            @test !isempty(grp.member_indices)
        end
        # The manually attached roof-deck level's catalog_override reaches the group.
        jrd_grp = struc.member_groups[slab_jrd.framing_levels[1].group_id]
        @test jrd_grp.catalog_override == owsj_catalog
        # Auto-derived levels carry no catalog override.
        @test struc.member_groups[slab_mtj.framing_levels[1].group_id].catalog_override === nothing
        @test struc.member_groups[slab_2w.framing_levels[1].group_id].catalog_override === nothing
    end

    @testset "(f) host members subdivided into multi-segment chains" begin
        host_beams = [b for b in struc.beams if StructuralSynthesizer.level_of(b) == 0]
        @test any(b -> length(StructuralSynthesizer.segment_indices(b)) > 1, host_beams)
        # At least one level recorded the hosts it landed on.
        @test !isempty(slab_mtj.framing_levels[1].supports)
    end

    @testset "(h) endpoint landing reuses the host vertex (no duplicate) [P1(a)]" begin
        # The split bay's single joist lands exactly on the bottom/top mid
        # columns (u = 0/1). The pre-fix `_landing_vertex!` always created a new
        # vertex first ⇒ a coincident duplicate. Assert the mid vertex is reused.
        @test n_mid_before == 1
        n_mid_after = count_vertices_near(skel, split_bay.mid_xy[1], split_bay.mid_xy[2])
        @test n_mid_after == 1
        # And a joist beam actually connects to that mid vertex (level-1, role joist).
        mid_seg_edges = [struc.segments[si].edge_idx
                         for b in struc.beams if StructuralSynthesizer.level_of(b) == 1
                         for si in StructuralSynthesizer.segment_indices(b)]
        touches_mid = any(mid_seg_edges) do e
            v1, v2 = skel.edge_indices[e]
            v1 == split_bay.mid || v2 == split_bay.mid
        end
        @test touches_mid
    end

    @testset "(i) generated joists receive a positive tributary strip [P1(b)]" begin
        joists = [b for b in struc.beams if StructuralSynthesizer.level_of(b) == 1]
        @test !isempty(joists)
        for b in joists
            prof = b.tributary_profile
            @test prof !== nothing
            if prof !== nothing
                L = StructuralSynthesizer.member_length(b)
                Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
                # Integral of the strip: (∫₀¹ w ds) · L must be strictly positive.
                @test StructuralSynthesizer.tributary_average(prof) * Lm > 0
            end
        end
    end

    @testset "(j) level-0 hosts accumulate level-1 joist load [P1(b)]" begin
        # A host that level-1 mass-timber joists land on must gain tributary width.
        supports = slab_mtj.framing_levels[1].supports
        @test !isempty(supports)
        h = supports[1]
        prof_h = struc.beams[h].tributary_profile
        @test prof_h !== nothing
        @test trib_width_sum(struc.beams[h]) > get(host_trib_before, h, 0.0)
    end

    @testset "(k) tributary cascade is idempotent [P2(e)]" begin
        # Baseline snapshot: every beam's profile after the first populate_levels!.
        snap1 = trib_snapshot_all(struc)

        # (k1) A second populate_levels! on the SAME struc must reproduce the
        #      profiles exactly. This is the standard (non-bypass) idempotence
        #      contract: derive returns nothing for materialized levels, so no new
        #      members are added, and the cascade rebuilds the identical baseline.
        populate_levels!(struc; opts = opts)
        snap2 = trib_snapshot_all(struc)
        assert_snapshots_equal(snap1, snap2)

        # (k2) Calling cascade_framing_tributaries! DIRECTLY (bypassing
        #      populate_levels!, so compute_member_tributaries! is NOT re-run
        #      first) must ALSO leave the profiles unchanged. Pre-fix this
        #      double-counted, because Level-0 hosts still carried the prior
        #      cascade's deposits. Approach A resets the baseline inside the pass.
        StructuralSynthesizer.cascade_framing_tributaries!(struc)
        snap3 = trib_snapshot_all(struc)
        assert_snapshots_equal(snap1, snap3)

        # (k3) A THIRD direct cascade must still match — confirms the reset is a
        #      true fixed point, not merely stable for a single re-run.
        StructuralSynthesizer.cascade_framing_tributaries!(struc)
        snap4 = trib_snapshot_all(struc)
        assert_snapshots_equal(snap1, snap4)
    end

    @info "Phase 5 smoke summary" n_host_beams=n_host_beams n_beams=length(struc.beams) n_groups=length(struc.member_groups)
end
