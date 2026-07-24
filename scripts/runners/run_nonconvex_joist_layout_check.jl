# Non-convex joist-layout robustness check (#5) — concave-safe clipping in
# `materialize_level!` / `_interior_subchains` (StructuralSynthesizer framing).
#
# Two independent BuildingStructures, one auto-generated framing level each:
#
#   1. U-shaped multi-cell slab (re-entrant / non-convex boundary). Joists laid
#      out across the full perpendicular extent would — with the old infinite-line
#      logic — place a segment straight across the open mouth of the U (through
#      the exterior notch). The fix clips each joist line to the slab interior, so
#      EVERY joist segment must lie inside the plate and NO joist may bridge the
#      gap. We also assert the clip actually fired (a line above the notch splits
#      into two joists — one per arm).
#
#   2. Rectangular single-cell slab (convex). The convexity guard makes the clip
#      a strict no-op, so the layout is the analytic expected one (full-span
#      joists, unchanged from pre-fix behavior).
#
# Run:
#   SS_ENABLE_VISUALIZATION=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_nonconvex_joist_layout_check.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap  # units + is_convex_polygon

const SS = StructuralSynthesizer

# ── small geometry helpers ────────────────────────────────────────────────────

"""Add edge `(v1, v2)` to `:beams` only once (dedup shared inter-cell edges by
their sorted vertex-index pair)."""
function add_edge_once!(skel, seen::Set{Tuple{Int, Int}}, v1::Int, v2::Int)
    key = minmax(v1, v2)
    if !(key in seen)
        add_element!(skel, v1, v2; group = :beams)
        push!(seen, key)
    end
    return
end

"""Add a rectangular cell given as CCW corner coords; return its vertex indices."""
function add_cell_edges!(skel, seen, corners::Vector{NTuple{2, Float64}}; z::Float64)
    vis = [add_vertex!(skel, [x, y, z]) for (x, y) in corners]
    n = length(vis)
    for i in 1:n
        add_edge_once!(skel, seen, vis[i], vis[mod1(i + 1, n)])
    end
    return vis
end

"""Skeleton face index whose vertex set equals `vis`."""
function face_for_vis(skel, vis)
    want = Set(vis)
    idx = findfirst(f -> Set(f) == want, skel.face_vertex_indices)
    idx === nothing && error("no face found for vertices $vis")
    return idx
end

"""(x, y) of the midpoint of a beam segment `si` (meters, Float64)."""
function seg_midpoint_xy(struc, si::Int)
    skel = struc.skeleton
    e = struc.segments[si].edge_idx
    v1, v2 = skel.edge_indices[e]
    vc = skel.geometry.vertex_coords
    return (0.5 * (vc[v1, 1] + vc[v2, 1]), 0.5 * (vc[v1, 2] + vc[v2, 2]))
end

"""All (x, y) vertices touched by a beam's segment chain."""
function beam_vertex_xys(struc, beam)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    xys = NTuple{2, Float64}[]
    for si in SS.segment_indices(beam)
        e = struc.segments[si].edge_idx
        for v in skel.edge_indices[e]
            push!(xys, (vc[v, 1], vc[v, 2]))
        end
    end
    return xys
end

const A992 = A992_Steel
CIP() = CIPSlabResult(0.2, 0.2, 5.0)

"""Attach level-0 girders (one Segment+Beam per `:beams` edge) to `struc`."""
function add_host_girders!(struc)
    skel = struc.skeleton
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    return
end

"""Push a Cell + return its index for the slab bookkeeping."""
function push_cell!(struc, face_idx, spans)
    cell = Cell(face_idx, 16.0u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    return length(struc.cells)
end

# ── (1) U-shaped (non-convex) slab ────────────────────────────────────────────

"""Build a U-shaped 7-cell slab (arms width 4, height 12; mouth open at the top
between x∈(4,8), y∈(4,12)). Returns (struc, slab, poly) where `poly` is the true
CCW outer boundary in meters."""
function build_u_structure()
    skel = BuildingSkeleton{Float64}()
    seen = Set{Tuple{Int, Int}}()
    z = 3.0
    cells = [
        [(0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)],     # L1
        [(0.0, 4.0), (4.0, 4.0), (4.0, 8.0), (0.0, 8.0)],     # L2
        [(0.0, 8.0), (4.0, 8.0), (4.0, 12.0), (0.0, 12.0)],   # L3
        [(4.0, 0.0), (8.0, 0.0), (8.0, 4.0), (4.0, 4.0)],     # B1
        [(8.0, 0.0), (12.0, 0.0), (12.0, 4.0), (8.0, 4.0)],   # R1
        [(8.0, 4.0), (12.0, 4.0), (12.0, 8.0), (8.0, 8.0)],   # R2
        [(8.0, 8.0), (12.0, 8.0), (12.0, 12.0), (8.0, 12.0)], # R3
    ]
    cell_vis = [add_cell_edges!(skel, seen, c; z = z) for c in cells]

    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    # Joists run ⟂ span axis; span axis (0,1) ⇒ joists horizontal, laid out along
    # y — so a joist above the notch (y > 4) must span both arms with a gap.
    spans = SpanInfo{Float64}(4.0, 12.0, (0.0, 1.0), 12.0)
    cidxs = [push_cell!(struc, face_for_vis(skel, vis), spans) for vis in cell_vis]

    slab = Slab{Float64}(cidxs, CIP(), :two_way, spans, :interior,
                         nothing, MaterialVolumes(), nothing, nothing,
                         FramingLevel{Float64}[])
    push!(struc.slabs, slab)

    add_host_girders!(struc)

    poly = NTuple{2, Float64}[(0.0, 0.0), (12.0, 0.0), (12.0, 12.0), (8.0, 12.0),
                              (8.0, 4.0), (4.0, 4.0), (4.0, 12.0), (0.0, 12.0)]
    return (struc, slab, poly)
end

# ── (2) Rectangular (convex) slab ─────────────────────────────────────────────

"""Build an 8×6 single-cell rectangular slab. Span axis (1,0) ⇒ joists vertical,
laid out along x."""
function build_rect_structure()
    skel = BuildingSkeleton{Float64}()
    seen = Set{Tuple{Int, Int}}()
    z = 3.0
    vis = add_cell_edges!(skel, seen,
                          [(0.0, 0.0), (8.0, 0.0), (8.0, 6.0), (0.0, 6.0)]; z = z)

    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 6.0)
    cidx = push_cell!(struc, face_for_vis(skel, vis), spans)
    slab = Slab{Float64}([cidx], CIP(), :two_way, spans, :interior,
                         nothing, MaterialVolumes(), nothing, nothing,
                         FramingLevel{Float64}[])
    push!(struc.slabs, slab)
    add_host_girders!(struc)
    return (struc, slab)
end

# ── assertions ────────────────────────────────────────────────────────────────

@testset "Non-convex joist layout robustness (#5)" begin

    @testset "U-shape: no joist crosses the re-entrant notch" begin
        struc, slab, poly = build_u_structure()

        # Sanity: the fix's own boundary polygon is genuinely non-convex.
        fix_poly = SS._slab_interior_polygon_m(struc, slab)
        @test fix_poly !== nothing
        @test Asap.is_convex_polygon(poly) == false
        @test Asap.is_convex_polygon(fix_poly) == false

        # spacing 2.5 ⇒ joist lines at y ≈ 2, 4.5, 7, 9.5; the last three sit
        # above the notch (y > 4) and must be clipped into two arm-joists each.
        opts = (materials = (steel = A992,), spacing = 2.5)
        populate_levels!(struc; opts = opts)

        joists = [b for b in struc.beams if SS.level_of(b) == 1]
        @test !isempty(joists)

        tol = 1e-6
        # (a) Every joist SEGMENT midpoint lies strictly inside the U plate — so
        #     no segment runs through the open mouth (the gap) or outside the
        #     boundary. This is the core defect: the pre-fix single chain produced
        #     a [left-arm → right-arm] segment whose midpoint sits in the notch.
        for b in joists
            for si in SS.segment_indices(b)
                mx, my = seg_midpoint_xy(struc, si)
                @test SS._point_in_polygon_xy(mx, my, poly)
            end
        end

        # (b) The clip actually fired: above the notch there must be a joist
        #     living entirely in the left arm AND one entirely in the right arm.
        function joist_confined(b, xlo, xhi, ymin)
            xys = beam_vertex_xys(struc, b)
            all(xy -> xlo - tol <= xy[1] <= xhi + tol, xys) &&
                any(xy -> xy[2] > ymin + tol, xys)
        end
        @test any(b -> joist_confined(b, 0.0, 4.0, 4.0), joists)   # left arm above notch
        @test any(b -> joist_confined(b, 8.0, 12.0, 4.0), joists)  # right arm above notch
    end

    @testset "Rectangle: convex layout unchanged (clip is a no-op)" begin
        struc, slab = build_rect_structure()

        poly = SS._slab_interior_polygon_m(struc, slab)
        @test poly !== nothing
        @test Asap.is_convex_polygon(poly) == true   # guard ⇒ clip path skipped

        opts = (materials = (steel = A992,), spacing = 2.0)
        populate_levels!(struc; opts = opts)

        joists = [b for b in struc.beams if SS.level_of(b) == 1]
        # 8 m width, spacing 2 ⇒ interior joists at x = 2, 4, 6 (3 joists), each a
        # single full-height (y: 0→6) span. This is the pre-fix analytic layout.
        @test length(joists) == 3

        tol = 1e-6
        for b in joists
            @test length(SS.segment_indices(b)) == 1     # single span (no spurious splits)
            ys = [xy[2] for xy in beam_vertex_xys(struc, b)]
            @test isapprox(minimum(ys), 0.0; atol = tol)  # spans full bay height
            @test isapprox(maximum(ys), 6.0; atol = tol)
        end
        xs_mid = sort([seg_midpoint_xy(struc, first(SS.segment_indices(b)))[1] for b in joists])
        @test all(isapprox.(xs_mid, [2.0, 4.0, 6.0]; atol = tol))
    end
end
