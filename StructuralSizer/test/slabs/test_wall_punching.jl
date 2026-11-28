# Wall-end, re-entrant corner, and shaft-loop critical sections.
#
# Perimeters are the straight d/2 offsets of ACI 318-11 §11.11.1.2
# (corpus: aci-318-11, page 200). A rectangular wall reduces to the
# edge-column section. An L and a closed loop are summed with
# ACI 421.1R-99 Appendix B (corpus: aci-421-1r-99).

using Test
using Unitful
using StructuralSizer

const SS = StructuralSizer

@testset "Wall reaction critical sections" begin
    t = 12.0u"inch"
    L = 20.0u"ft"
    d = 8.0u"inch"

    # Free end, slab on the tip and both faces: the edge-column perimeter
    # with the wall length perpendicular to the continuing face.
    pts, closed = SS.wall_end_critical_section(t, L, d)
    b0 = SS.critical_section_properties(pts, d; closed = closed).b0
    @test b0 ≈ SS.punching_geometry_edge(L, t, d).b0 rtol = 1e-9
    @test closed == false

    # Slab on one face and both free ends.
    pts, closed = SS.wall_face_critical_section(t, L, d)
    b0 = SS.critical_section_properties(pts, d; closed = closed).b0
    @test b0 ≈ SS.punching_geometry_edge(t, L, d).b0 rtol = 1e-9

    tx, Lx = 10.0u"inch", 10.0u"ft"
    ty, Ly = 12.0u"inch", 12.0u"ft"
    dL = 6.0u"inch"
    ox = ty / 2 + dL / 2
    oy = tx / 2 + dL / 2

    pts, closed = SS.reentrant_wall_corner_section(tx, Lx, ty, Ly, dL)
    b0 = SS.critical_section_properties(pts, dL; closed = closed).b0
    @test closed == false
    @test b0 ≈ (Lx - ox) + (Ly - oy) rtol = 1e-9

    pts, closed = SS.convex_wall_corner_section(tx, Lx, ty, Ly, dL)
    b0 = SS.critical_section_properties(pts, dL; closed = closed).b0
    @test b0 ≈ (Lx + ox) + (Ly + oy) rtol = 1e-9

    # Closed shaft: centerline 8 m × 8 m, wall 0.3 m, d = 0.2 m.
    # Section is t/2 + d/2 outside each centerline.
    Wx, Wy, tw, dw = 8.0u"m", 8.0u"m", 0.3u"m", 0.2u"m"
    pts, closed = SS.closed_wall_loop_section(Wx, Wy, tw, dw)
    b0 = SS.critical_section_properties(pts, dw; closed = closed).b0
    @test closed == true
    @test b0 ≈ 2 * ((Wx + tw + dw) + (Wy + tw + dw)) rtol = 1e-9

    # Table 9.5(c) at fy = 60 ksi stays on the without-edge-beams column
    # when the edge is discontinuous. A wall is not taken as footnote §'s beam.
    ln = 20.0u"ft"
    @test SS.min_thickness(SS.FlatPlate(), ln; discontinuous_edge = true) ≈ ln / 30
    @test SS.min_thickness(SS.FlatPlate(), ln; discontinuous_edge = false) ≈ ln / 33
end

@testset "Table 9.5(c) sees a wall on the slab edge" begin
    coords = [0.0 0.0 0.0; 6.0 0.0 0.0; 6.0 6.0 0.0; 0.0 6.0 0.0]
    skel = (geometry = (vertex_coords = coords,),
            face_vertex_indices = [[1, 2, 3, 4]])
    struc = (skeleton = skel, cells = [(face_idx = 1,)])
    function floor(segs)
        return (cell_indices = [1], wall_segments = segs)
    end
    interior = [(position = :interior,)]
    edge = ((0.0, 0.0), (6.0, 0.0))
    inside = ((1.0, 3.0), (5.0, 3.0))
    @test SS.slab_discontinuous_edge(struc, floor([edge]), interior)
    @test !SS.slab_discontinuous_edge(struc, floor([inside]), interior)
    @test SS.slab_discontinuous_edge(struc, floor(typeof(edge)[]), [(position = :edge,)])
    @test !SS.slab_discontinuous_edge(struc, floor(typeof(edge)[]), interior)
end
