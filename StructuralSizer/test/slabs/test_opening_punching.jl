# ACI 318-11 §11.11.6 (corpus: aci-318-11, page 209): an opening within 10
# slab thicknesses of the column removes the critical perimeter between the
# tangents from the column centre to the opening.

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "Opening reduces the punching perimeter" begin
    c1, c2, d = 16.0u"inch", 16.0u"inch", 6.0u"inch"
    h = 7.0u"inch"
    pts, closed = SS.rectangular_critical_section(c1, c2, d)
    full = SS.critical_section_properties(pts, d; closed = closed)
    @test ustrip(u"inch", full.b0) ≈ 88.0 atol = 1e-6

    inch(x) = x * 0.0254
    # Square from x = 20 in to 40 in, y = ±5 in. The tangents cut 5.5 in
    # out of the right face of the critical section (x = 11 in).
    opening = [(inch(20), inch(-5)), (inch(40), inch(-5)),
               (inch(40), inch(5)), (inch(20), inch(5))]
    half = inch(8)
    reaction = [(-half, -half), (half, -half), (half, half), (-half, half)]
    reduced = SS.opening_reduced_perimeter(pts, closed, [opening], reaction, h)
    @test reduced !== nothing
    cut = SS.critical_section_properties(reduced.points, d; segments = reduced.segments)
    @test ustrip(u"inch", cut.b0) ≈ 82.5 atol = 1e-3

    far = [(inch(200), inch(-5)), (inch(220), inch(-5)),
           (inch(220), inch(5)), (inch(200), inch(5))]
    @test SS.opening_reduced_perimeter(pts, closed, [far], reaction, h) === nothing
end

# A plan rotation of the column and the opening together leaves the perimeter.
_turn(p, ang) = (p[1] * cos(ang) - p[2] * sin(ang), p[1] * sin(ang) + p[2] * cos(ang))

@testset "A rotated column cuts the same perimeter" begin
    c1, c2, d = 16.0u"inch", 16.0u"inch", 6.0u"inch"
    h = 7.0u"inch"
    inch(x) = x * 0.0254
    opening = [(inch(20), inch(-5)), (inch(40), inch(-5)),
               (inch(40), inch(5)), (inch(20), inch(5))]
    fc = 4000.0u"psi"
    Vu = 40.0kip
    M0 = 0.0kip * u"ft"
    col = (c1 = c1, c2 = c2, position = :interior, shape = :rectangular)
    b0_of(ang, op) = SS.check_punching_for_column(col, Vu, M0, d, h, fc;
                         openings = [op], column_xy = (0.0, 0.0), θ = ang).b0
    plain = b0_of(0.0, opening)
    @test ustrip(u"inch", plain) ≈ 82.5 atol = 1e-3
    for ang in (π / 2, π / 6)
        turned = [_turn(p, ang) for p in opening]
        @test ustrip(u"inch", b0_of(ang, turned)) ≈ ustrip(u"inch", plain) atol = 1e-3
    end
end

@testset "A re-entrant corner loses the tangent arc" begin
    c1 = c2 = 16.0u"inch"
    d = 6.0u"inch"
    h = 7.0u"inch"
    inch(x) = x * 0.0254
    # Slab in the −x,−y side of the free edges through the +x,+y column corner.
    normals = [(-1.0, 0.0), (0.0, -1.0)]
    pts, closed = SS.corner_critical_section(c1, c2, d, :reentrant, normals)
    full = SS.critical_section_properties(pts, d; closed = closed)
    @test ustrip(u"inch", full.b0) ≈ ustrip(u"inch", 2 * (c1 + c2) + 3 * d) atol = 1e-6

    # Same opening as the rectangle: tangents hit x = 11 in at y = ±2.75 in,
    # and that segment is still on the re-entrant perimeter. Removed length 5.5 in.
    opening = [(inch(20), inch(-5)), (inch(40), inch(-5)),
               (inch(40), inch(5)), (inch(20), inch(5))]
    half = inch(8)
    reaction = [(-half, -half), (half, -half), (half, half), (-half, half)]
    reduced = SS.opening_reduced_perimeter(pts, closed, [opening], reaction, h)
    @test reduced !== nothing
    cut = SS.critical_section_properties(reduced.points, d; segments = reduced.segments)
    @test ustrip(u"inch", cut.b0) ≈ ustrip(u"inch", full.b0) - 5.5 atol = 1e-2

    # Rotating the column, the free edges, and the opening together is the same cut.
    ang = π / 6
    turned_n = [_turn(n, ang) for n in normals]
    tpts, tclosed = SS.corner_critical_section(c1, c2, d, :reentrant, turned_n; θ = ang)
    treduced = SS.opening_reduced_perimeter(tpts, tclosed, [[_turn(p, ang) for p in opening]],
                                            [_turn(p, ang) for p in reaction], h)
    tcut = SS.critical_section_properties(treduced.points, d; segments = treduced.segments)
    @test ustrip(u"inch", tcut.b0) ≈ ustrip(u"inch", cut.b0) atol = 1e-2
end

@testset "A circular column loses the tangent arc" begin
    D = 16.0u"inch"
    d = 6.0u"inch"
    h = 7.0u"inch"
    inch(x) = x * 0.0254
    pts, closed, reaction = SS.column_plan_section(D, D, d, :interior, 0.0; circular = true)
    full = SS.critical_section_properties(pts, d; closed = closed)
    opening = [(inch(20), inch(-5)), (inch(40), inch(-5)),
               (inch(40), inch(5)), (inch(20), inch(5))]
    reduced = SS.opening_reduced_perimeter(pts, closed, [opening], reaction, h)
    @test reduced !== nothing
    cut = SS.critical_section_properties(reduced.points, d; segments = reduced.segments)
    # Rays through (20, ±5) meet the circle of radius 11 in. The arc between them
    # is r · 2 · atan(5/20).
    r_in = 11.0
    arc = r_in * 2 * atan(5 / 20)
    @test ustrip(u"inch", full.b0 - cut.b0) ≈ arc atol = 0.15
end

@testset "The column centre is the structural centre" begin
    # Vertex at the origin, structural centre 0.40 m inward.
    vc = zeros(4, 3)
    vc[2, 1] = 2.0
    vc[3, 1] = 2.0
    vc[3, 2] = 2.0
    vc[4, 2] = 2.0
    skel = (
        geometry = (vertex_coords = vc,),
        face_vertex_indices = [[1, 2, 3, 4]],
        openings = [(loop = [(0.4, 0.4), (0.8, 0.4), (0.8, 0.8), (0.4, 0.8)],)],
    )
    cell = (face_idx = 1, spans = (primary = 4.0u"m", secondary = 4.0u"m"))
    slab = (
        cell_indices = [1],
        floor_type = :flat_slab,
        spans = (primary = 8.0u"m", secondary = 8.0u"m", axis = (0.0, 1.0)),
    )
    struc = (skeleton = skel, cells = [cell])
    col = (vertex_idx = 1, structural_offset = (0.40, 0.0), θ = 0.0)
    kw = SS.column_opening_punching(struc, slab, col)
    @test kw.column_xy[1] ≈ 0.40 atol = 1e-12
    @test kw.column_xy[2] ≈ 0.0 atol = 1e-12
    # The framing panel's spans, not the slab's governing spans: 0.25 * 4 m.
    @test ustrip(u"m", kw.column_strips[1][1]) ≈ 1.0 atol = 1e-12
    @test kw.span_axis[2] ≈ 1.0 atol = 1e-12

    # 10h is measured from that centre. h = 0.05 m, so 10h = 0.50 m.
    # A point column at the centre reaches an opening 0.40 m away; the same
    # opening is 0.80 m from the architectural vertex.
    h = 0.05u"m"
    opening = [(0.75, -0.05), (0.90, -0.05), (0.90, 0.05), (0.75, 0.05)]
    at_centre = [(0.40, -0.01), (0.40, 0.01), (0.42, 0.0)]
    at_vertex = [(0.0, -0.01), (0.0, 0.01), (0.02, 0.0)]
    @test SS.opening_reaches_column(opening, at_centre, h)
    @test !SS.opening_reaches_column(opening, at_vertex, h)
end

@testset "The drop edge is cut from the drop centroid" begin
    c1 = c2 = 0.40u"m"
    a1 = 2.0u"m"
    a2 = 1.0u"m"
    d = 0.20u"m"
    h = 0.10u"m"   # outside the drop; 10h = 1.0 m
    # Edge column, free edge at x = +c1/2 = 0.20 m. The drop is clipped there,
    # so its centroid is not the column centre.
    sec = SS.drop_plan_section(c1, c2, a1, a2, d, :edge, 0.0, (1.0, 0.0))
    pts, closed, reaction, origin = sec.points, sec.closed, sec.reaction, sec.centroid
    @test origin[1] < -0.5
    @test abs(origin[2]) < 1e-8
    full = SS.critical_section_properties(pts, d; closed = closed)

    # Just outside the inner face of the drop (x = −a1). Within 1 m of the drop,
    # and more than 1 m from the column.
    opening = [(-2.30, -0.05), (-2.60, -0.05), (-2.60, 0.05), (-2.30, 0.05)]
    col_face = [(0.20, -0.20), (0.20, 0.20), (-0.20, 0.20), (-0.20, -0.20)]
    @test SS.opening_reaches_column(opening, reaction, h)
    @test !SS.opening_reaches_column(opening, col_face, h)

    b0 = SS.drop_opening_b0(c1, c2, a1, a2, d, h, :edge, [opening], (0.0, 0.0))
    @test b0 !== nothing
    @test ustrip(u"m", b0) < ustrip(u"m", full.b0) - 0.05

    # Beyond 10h of the drop, the check keeps the clipped perimeter.
    far = [(5.0, -0.1), (5.4, -0.1), (5.4, 0.1), (5.0, 0.1)]
    @test SS.drop_opening_b0(c1, c2, a1, a2, d, h, :edge, [far], (0.0, 0.0)) === nothing
    col = (c1 = c1, c2 = c2, position = :edge, shape = :rectangular)
    drop = SS.DropPanelGeometry(0.05u"m", a1, a2)
    plain = SS.check_punching_at_drop_edge(col, 100.0kip, 0.0kip * u"ft", h, d, 4000.0u"psi", drop)
    # Clipped edge: legs run from the column face at c1/2 back past the centre
    # to a1 + d/2. b0 = 2(a1 + c1/2 + d/2) + (2 a2 + d).
    clipped = 2 * (a1 + c1 / 2 + d / 2) + (2 * a2 + d)
    @test ustrip(u"m", plain.b0) ≈ ustrip(u"m", clipped) atol = 1e-6
    cut = SS.check_punching_at_drop_edge(col, 100.0kip, 0.0kip * u"ft", h, d, 4000.0u"psi", drop;
                                         openings = [opening], column_xy = (0.0, 0.0))
    @test ustrip(u"m", cut.b0) ≈ ustrip(u"m", b0) atol = 1e-6
    # The clipped drop is longer than the old three-sided formula, because the
    # inward leg runs from the free edge at the column face back through the
    # column centre. The cut is measured on that outline.
    @test ustrip(u"m", cut.b0) < ustrip(u"m", full.b0) - 0.05
    far_check = SS.check_punching_at_drop_edge(col, 100.0kip, 0.0kip * u"ft", h, d, 4000.0u"psi", drop;
                                              openings = [far], column_xy = (0.0, 0.0))
    @test ustrip(u"m", far_check.b0) ≈ ustrip(u"m", plain.b0) atol = 1e-6
end

# StructurePoint DE, flat slab with drop panels, §5.2.2 and Table 13
# (sp-de-two-way-flat-slab-drop-panels-aci318-14, pages 60–62 and 107).
# 20 in columns, drop 5 ft from each centreline, d = 8.875 in (printed 8.88).
@testset "Drop-edge section matches the StructurePoint flat-slab example" begin
    c = 20.0u"inch"
    a = 5.0u"ft"
    d = 8.875u"inch"
    h = 10.0u"inch"
    fc = 5000.0u"psi"
    qu = 0.270u"kip/ft^2"
    drop = SS.DropPanelGeometry(4.25u"inch", a, a)
    M0 = 0.0kip * u"ft"
    # Gross shear on the column side of the critical section, before qu·b1·b2.
    cases = (
        (position = :interior, V = 265.24kip, b0 = 515.50, Vu = 234.10),
        (position = :edge,     V = 108.83kip, b0 = 277.75, Vu = 90.84),
        (position = :corner,   V = 61.93kip,  b0 = 148.88, Vu = 51.54),
    )
    for case in cases
        col = (c1 = c, c2 = c, position = case.position, shape = :rectangular)
        r = SS.check_punching_at_drop_edge(col, case.V, M0, h, d, fc, drop; qu = qu)
        @test ustrip(u"inch", r.b0) ≈ case.b0 atol = 0.02
        Vu_net = uconvert(kip, r.vu * r.b0 * d)
        @test ustrip(kip, Vu_net) ≈ case.Vu atol = 0.05
    end
end

# The thickened shell region is the drop itself, clipped at the column face,
# not the full centred rectangle. Same outline as the punching reaction.
@testset "The shell drop patch is the clipped drop" begin
    c = 20.0u"inch"
    a = 5.0u"ft"
    drop = SS.DropPanelGeometry(4.25u"inch", a, a)
    skel = (geometry = (vertex_coords = [0.0 0.0 0.0],),)
    struc = (skeleton = skel,)
    section = Asap.ShellSection(10.0u"inch", 30e9u"Pa", 0.2)
    function patch_for(position)
        col = (vertex_idx = 1, c1 = c, c2 = c, position = position, shape = :rectangular)
        patches = SS.build_slab_shell_patches(struc, [col], section; drop_panel = drop)
        only(p for p in patches if p.id === :drop_panel)
    end
    face = ustrip(u"m", c / 2)
    a_m = ustrip(u"m", a)

    interior = patch_for(:interior)
    @test maximum(p[1] for p in interior.vertices) ≈ a_m atol = 1e-9
    @test minimum(p[1] for p in interior.vertices) ≈ -a_m atol = 1e-9

    edge = patch_for(:edge)
    @test maximum(p[1] for p in edge.vertices) ≈ face atol = 1e-9
    @test minimum(p[1] for p in edge.vertices) ≈ -a_m atol = 1e-9
    @test maximum(abs.(getindex.(edge.vertices, 2))) ≈ a_m atol = 1e-9
    outline = SS.drop_outline(c, c, a, a, :edge, 0.0, (1.0, 0.0))
    @test edge.vertices == [(p[1], p[2]) for p in outline.polygon]

    corner = patch_for(:corner)
    @test maximum(p[1] for p in corner.vertices) ≈ face atol = 1e-9
    @test maximum(p[2] for p in corner.vertices) ≈ face atol = 1e-9
    @test minimum(p[1] for p in corner.vertices) ≈ -a_m atol = 1e-9
    @test minimum(p[2] for p in corner.vertices) ≈ -a_m atol = 1e-9
end

@testset "A re-entrant drop stays in every slab quadrant" begin
    c1, c2 = 0.4u"m", 0.4u"m"
    a1, a2 = 1.0u"m", 1.0u"m"
    function area(kind, aa2 = a2)
        poly = SS.drop_outline(c1, c2, a1, aa2, :corner, 0.0, (1.0, 0.0);
                               corner_kind = kind).polygon
        s = 0.0
        n = length(poly)
        for i in 1:n
            p, q = poly[i], poly[mod1(i + 1, n)]
            s += p[1] * q[2] - q[1] * p[2]
        end
        return abs(s) / 2
    end
    # The rectangle is 2 m by 2 m. The notch beyond both faces is 0.8 m by 0.8 m.
    re = area(:reentrant)
    @test re ≈ 4.0 - 0.8 * 0.8 atol = 1e-9
    @test re > area(:convex)
    @test area(:reentrant, 1.5u"m") > re
    again = SS.drop_outline(c1, c2, a1, a2, :corner, 0.0, (1.0, 0.0);
                            corner_kind = :reentrant).polygon
    first = SS.drop_outline(c1, c2, a1, a2, :corner, 0.0, (1.0, 0.0);
                            corner_kind = :reentrant).polygon
    @test again == first

    # The critical section is that outline, offset by d/2. A deeper slab
    # moves it further out, and the re-entrant outline gives a larger section
    # than the one quadrant a convex corner keeps.
    d = 0.15u"m"
    section(kind, depth = d) = SS.drop_plan_section(c1, c2, a1, a2, depth, :corner, 0.0,
                                                   (1.0, 0.0); corner_kind = kind)
    re_sec = section(:reentrant)
    @test ustrip(u"m^2", re_sec.area) > ustrip(u"m^2", section(:convex).area)
    @test ustrip(u"m^2", section(:reentrant, 0.25u"m").area) > ustrip(u"m^2", re_sec.area)
    @test section(:reentrant).points == re_sec.points
end
