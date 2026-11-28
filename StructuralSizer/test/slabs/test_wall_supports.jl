using Test
using Unitful
using Asap
using StructuralSizer
const SS = StructuralSizer

@testset "A full panel edge is not a column; a short wall has two spans" begin
    # R13.1 (aci-318-11, page 243): the wall from column to column supports
    # the whole edge. The wall at x = 2 m, between columns 2 m and 6 m away,
    # is a column, and those distances are the §13.6.1.3 spans (page 252).
    coords = [0.0 0.0; 4.0 0.0; 8.0 0.0]
    skel = (geometry = (vertex_coords = coords,), face_vertex_indices = [[1, 2, 3]])
    struc = (skeleton = skel, cells = [1])
    col(i) = (vertex_idx = i, structural_offset = (0.0, 0.0))
    full = ((0.0, 0.0), (4.0, 0.0))
    @test SS.wall_is_fully_restrained(struc, nothing, full, [col(1), col(2)])
    short = ((2.0, 0.0), (2.0, 1.0))
    ends = [col(1), col(3)]
    @test !SS.wall_is_fully_restrained(struc, nothing, short, ends)
    sides = SS._columns_off_wall(struc, ends, short)
    @test sort([sides.pairs[1][1], sides.pairs[2][1]]) ≈ [2.0, 6.0]
end

@testset "An edge wall parallel to the span is the edge beam" begin
    # §13.6.3.3 (aci-318-11, page 254). No wall leaves βt. A wall on the
    # column line, parallel to the span, is the full edge beam (βt = 2.5).
    # An interior parallel wall is not that edge.
    coords = [0.0 0.0; 8.0 0.0; 0.0 8.0; 8.0 8.0]
    skel = (geometry = (vertex_coords = coords,), face_vertex_indices = [[1, 2, 4, 3]])
    struc = (skeleton = skel, cells = [1])
    cols = [(vertex_idx = i, structural_offset = (0.0, 0.0)) for i in 1:4]
    bare = (cell_indices = Int[],)
    @test SS.βt_with_parallel_wall(0.4, struc, bare, cols, (1.0, 0.0)) ≈ 0.4
    edge = (wall_segments = [((0.0, 0.0), (8.0, 0.0))],)
    @test SS.βt_with_parallel_wall(0.4, struc, edge, cols, (1.0, 0.0)) ≈ 2.5
    interior = (wall_segments = [((0.0, 4.0), (8.0, 4.0))],)
    @test SS.βt_with_parallel_wall(0.0, struc, interior, cols, (1.0, 0.0)) ≈ 0.0
end

@testset "§13.6.3.3 wall-end coefficients" begin
    # Column (3) is the flat plate without an edge beam. Column (5) is the
    # fully restrained edge. Column (1) is the unrestrained edge.
    # ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254).
    c3 = SS.ACI_DDM_LONGITUDINAL.end_span
    c5 = SS.ACI_DDM_LONGITUDINAL.end_span_fully_restrained
    c1 = SS.ACI_DDM_LONGITUDINAL.end_span_unrestrained
    @test (c3.ext_neg, c3.pos, c3.int_neg) == (0.26, 0.52, 0.70)
    @test (c5.ext_neg, c5.pos, c5.int_neg) == (0.65, 0.35, 0.65)
    @test (c1.ext_neg, c1.pos, c1.int_neg) == (0.0, 0.63, 0.75)
end

@testset "A span that ends on a wall uses Column (5)" begin
    wall = (position = :edge, wall_fixed = true)
    col = (position = :interior, wall_fixed = false)
    qu = 10.0u"kPa"
    on_wall = (
        tributary_width = 6.0u"m",
        span_lengths = [8.0u"m"],
        columns = [wall, col],
    )
    moms = SS._frameline_span_moments(SS.DDM(), on_wall, qu, [true, false], 0.0)
    @test moms[1].M_neg_left / moms[1].M0 ≈ 0.65
    @test moms[1].M_pos / moms[1].M0 ≈ 0.35
    @test moms[1].M_neg_right / moms[1].M0 ≈ 0.65

    on_column = (
        tributary_width = 6.0u"m",
        span_lengths = [8.0u"m"],
        columns = [col, col],
    )
    moms2 = SS._frameline_span_moments(SS.DDM(), on_column, qu, [true, false], 0.0)
    @test moms2[1].M_neg_left / moms2[1].M0 ≈ 0.26
    @test moms2[1].M_pos / moms2[1].M0 ≈ 0.52
    @test moms2[1].M_neg_right / moms2[1].M0 ≈ 0.70
end

@testset "§13.6.4 column-strip fractions" begin
    # αf = 0, βt = 0: the flat-plate row. Interior negative 75%, positive 60%,
    # exterior negative 100%. ACI 318-11 §13.6.4 (corpus: aci-318-11, pages 255–256).
    flat = SS.aci_column_strip_fractions(1.0)
    @test flat.cs_int_neg ≈ 0.75
    @test flat.cs_pos ≈ 0.60
    @test flat.cs_ext_neg ≈ 1.0

    # αf1·ℓ2/ℓ1 ≥ 1 and ℓ2/ℓ1 = 1: interior negative stays 75%, positive becomes 75%.
    stiff = SS.aci_column_strip_fractions(1.0; stiff_beam = true, βt = 2.5)
    @test stiff.cs_int_neg ≈ 0.75
    @test stiff.cs_pos ≈ 0.75
    @test stiff.cs_ext_neg ≈ 0.75

    # Same row at ℓ2/ℓ1 = 0.5: 90%. At ℓ2/ℓ1 = 2: 45%.
    narrow = SS.aci_column_strip_fractions(0.5; stiff_beam = true)
    @test narrow.cs_int_neg ≈ 0.90
    @test narrow.cs_pos ≈ 0.90
    wide = SS.aci_column_strip_fractions(2.0; stiff_beam = true, βt = 2.5)
    @test wide.cs_int_neg ≈ 0.45
    @test wide.cs_ext_neg ≈ 0.45

    # §13.6.4.3: a long wall support spreads negative moment across ℓ2.
    # Column-strip width is min(ℓ1, ℓ2)/2, so the share is 1/2 when ℓ1 = ℓ2.
    uniform = SS.aci_column_strip_fractions(1.0; uniform_negative = true,
                                            l1 = 8.0u"m", l2 = 8.0u"m")
    @test uniform.cs_int_neg ≈ 0.5
    @test uniform.cs_ext_neg ≈ 0.5
    @test uniform.cs_pos ≈ 0.60
end

@testset "FEA :frame notes a one-way panel and a clamped stiff row" begin
    # §13.7.7.5 (aci-318-11, page 262) permits the §13.6.4 split on frame
    # moments, so a one-panel slab is not a reason to drop it. Longer/shorter
    # > 2 is reported as one-way behavior (R13.6.1.2, page 252) and the
    # flat-plate row is still used. The stiff row adds its own note outside
    # 0.5–2.0, where the table is clamped (page 255).
    struc = (skeleton = (geometry = (vertex_coords = zeros(0, 2),),
                         face_vertex_indices = Vector{Int}[]),
             cells = Any[])
    panel(l1, l2; kw...) = (spans = (primary = l1, secondary = l2, axis = (1.0, 0.0)), kw...)
    along_x = [((0.0, 2.0), (4.0, 2.0))]

    bare = SS._frame_fraction_stretches(struc, panel(4.0u"m", 10.0u"m"), [])
    @test length(bare) == 1
    @test occursin("one-way", only(bare))
    @test occursin("split is still used", only(bare))
    @test occursin("2.5", only(bare))
    @test isempty(SS._frame_fraction_stretches(struc, panel(4.0u"m", 8.0u"m"), []))
    @test isempty(SS._frame_fraction_stretches(
        struc, panel(8.0u"m", 8.0u"m"; wall_segments = along_x), []))
    @test isempty(SS._frame_fraction_stretches(
        struc, panel(4.0u"m", 8.0u"m"; wall_segments = along_x), []))

    long = SS._frame_fraction_stretches(
        struc, panel(4.0u"m", 10.0u"m"; wall_segments = along_x), [])
    @test length(long) == 2
    @test count(s -> occursin("one-way", s), long) == 1
    @test any(s -> occursin("primary", s) && occursin("2.5", s), long)

    marked = SS._frame_fraction_stretches(
        struc, panel(8.0u"m", 8.0u"m"; is_rectangular = false), [])
    @test length(marked) == 1
    @test occursin("non-rectangular", only(marked))
end

@testset "One-way shear outside the section at d from a wall" begin
    # Tributary 4 m² on a 8 m wall, d = 0.2 m. The strip within d of the face
    # is 8 * 0.2 = 1.6 m², so Vu uses the remaining 2.4 m².
    qu = 10.0u"kPa"
    d = 0.2u"m"
    L = 8.0
    A = 4.0
    outside = max(A - L * ustrip(u"m", d), 0.0)
    Vu = uconvert(u"kN", qu * (outside * u"m^2"))
    @test ustrip(u"kN", Vu) ≈ 24.0
    Vc = SS.one_way_shear_capacity(30.0u"MPa", L * u"m", d)
    r = SS.check_one_way_shear(Vu, Vc)
    @test r.ratio > 0
    @test r.ok == (r.ratio <= 1)
end

@testset "A wall fixes only the strip it covers" begin
    # Frame at y = 8, strip from y = 4 to y = 12. The wall runs y = 8 to 16,
    # so it covers 4 m of an 8 m strip: a column, not a fixed joint.
    perp = (0.0, 1.0)
    seg = ((8.0, 8.0), (8.0, 16.0))
    overlap, strip = SS._wall_strip_overlap(seg, perp, 8.0, 4.0, 4.0)
    @test overlap ≈ 4.0
    @test strip ≈ 8.0
    @test overlap < strip - 0.05
    @test !(overlap > 0.5 * strip + 1e-6)

    # The same wall covers an edge strip that is only the inward 4 m.
    full, width = SS._wall_strip_overlap(seg, perp, 8.0, 0.0, 4.0)
    @test full ≈ 4.0
    @test width ≈ 4.0

    # A span from x = 8 to 16 on the line y = 8 lies on the wall.
    ax = (1.0, 0.0)
    along = ((8.0, 8.0), (16.0, 8.0))
    @test SS._span_lies_on_wall([along], ax, 8.0, 8.0, 16.0)
    @test !SS._span_lies_on_wall([along], ax, 8.0, 0.0, 8.0)
end

@testset "A wall line does not fix the slab in space" begin
    along_x = Asap.Node([4.0u"m", 0.0u"m", 0.0u"m"], [true, true, true, true, true, true])
    along_y = Asap.Node([0.0u"m", 4.0u"m", 0.0u"m"], [true, true, true, true, true, true])
    free = Asap.Node([4.0u"m", 4.0u"m", 0.0u"m"], [true, true, true, true, true, true])
    shells = [(nodes = [along_x, along_y, free],)]
    # Plan lines without a pier are not a support.
    slab = (wall_piers = StructuralSizer.FlatPlateWallPier[],)
    n, bases = SS._attach_slab_walls!(shells, (walls = Any[],), slab,
                                      Asap.ShellSection(0.2u"m", 30.0u"GPa", 0.2))
    @test n == 0
    @test isempty(bases)
    @test along_x.dof == [true, true, true, true, true, true]
    @test along_y.dof == [true, true, true, true, true, true]
    @test free.dof == [true, true, true, true, true, true]
end

@testset "The slab is joined to the wall and the base is the support" begin
    a = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], :free)
    b = Asap.Node([4.0u"m", 0.0u"m", 0.0u"m"], :free)
    c = Asap.Node([0.0u"m", 4.0u"m", 0.0u"m"], :free)
    sec = Asap.ShellSection(0.2u"m", 30.0u"GPa", 0.2)
    tri = Asap.ShellTri3((a, b, c), 0.2u"m", 30.0u"GPa", 0.2)
    shells = [tri]
    pier = SS.FlatPlateWallPier(0.0, 0.0, 4.0, 0.0, 0.30, 3.0)
    n, bases = SS._attach_slab_walls!(shells, (walls = Any[],),
                                      (wall_piers = [pier],), sec)
    @test n == 2
    @test a.dof == [true, true, true, true, true, true]
    @test b.dof == [true, true, true, true, true, true]
    @test c.dof == [true, true, true, true, true, true]
    @test length(bases) == 2
    @test all(node -> node.dof == [false, false, false, true, true, true], bases)
    @test count(s -> s.id === :wall, shells) == 2
    @test all(node -> ustrip(u"m", node.position[3]) ≈ -3.0, bases)
end

@testset "Wall moments stay off the column labels" begin
    edge = (position = :edge,)
    wall = (position = :edge, wall_fixed = false)
    interior = (position = :interior,)
    spans = [(
        span_idx = 1,
        M_neg_left = 100.0 * u"kip*ft",
        M_pos = 40.0 * u"kip*ft",
        M_neg_right = 580.0 * u"kip*ft",
    ), (
        span_idx = 2,
        M_neg_left = 200.0 * u"kip*ft",
        M_pos = 50.0 * u"kip*ft",
        M_neg_right = 90.0 * u"kip*ft",
    )]
    env = SS._envelope_support_moments(spans, [edge, wall, interior])
    @test env.M_neg_ext == 100.0 * u"kip*ft"
    @test env.M_neg_int == 90.0 * u"kip*ft"
    @test env.M_wall_int == 580.0 * u"kip*ft"
    @test env.M_wall_ext == 0.0 * u"kip*ft"
    @test env.M_pos == 50.0 * u"kip*ft"

    broken = [(
        span_idx = 1,
        M_neg_left = 400.0 * u"kip*ft",
        M_pos = -10.0 * u"kip*ft",
        M_neg_right = 400.0 * u"kip*ft",
    )]
    @test_throws ErrorException SS._envelope_support_moments(broken, [edge, interior])

    # §13.7.7.1 face moments: columns go to the face, a wall stays at its
    # centerline, and a pattern uses each span's own load.
    geom = [(l1 = 20.0u"ft", l2 = 10.0u"ft", c1_left = 2.0u"ft", c1_right = 1.0u"ft"),
            (l1 = 20.0u"ft", l2 = 10.0u"ft", c1_left = 1.0u"ft", c1_right = 2.0u"ft")]
    q = [0.2u"kip/ft^2", 0.1u"kip/ft^2"]
    faced = SS._with_face_moments(spans, geom, [edge, wall, interior], q)
    l, r = SS.span_face_moments(100.0u"kip*ft", 580.0u"kip*ft", 2.0u"kip/ft",
                                20.0u"ft", 1.0u"ft", 0.0u"ft")
    @test faced[1].M_face_left ≈ l
    @test faced[1].M_face_right == 580.0u"kip*ft"
    _, r2 = SS.span_face_moments(200.0u"kip*ft", 90.0u"kip*ft", 1.0u"kip/ft",
                                 20.0u"ft", 0.0u"ft", 1.0u"ft")
    @test faced[2].M_face_right ≈ r2
    env_face = SS._envelope_support_moments(faced, [edge, wall, interior])
    @test env_face.M_neg_ext_face ≈ l
    @test env_face.M_neg_int_face ≈ r2
    @test env_face.M_wall_int == 580.0u"kip*ft"
end

@testset "Wall faces keep dead and live apart" begin
    seg = ((0.0, 0.0), (6.0, 0.0))
    wall = (wall_fixed = true, wall_seg = seg)
    column = (position = :interior,)
    # The constant 5 is the drop, factored by 1.2: 1.2·2 + 1.6·3 sets qu.
    # Live drops it. Dead keeps its unfactored part, 5 / 1.2.
    function solve_once(q)
        M = (5.0 + ustrip(u"Pa", q[1])) * u"N*m"
        return [(span_idx = 1, M_neg_left = M, M_pos = M, M_neg_right = M)]
    end
    faces = SS._efm_wall_faces(solve_once, [wall, column], 2.0u"Pa", 3.0u"Pa", 1, false)
    @test length(faces) == 1
    @test faces[1].D ≈ 2.0 + 5.0 / 1.2
    @test faces[1].L ≈ 3.0
    @test faces[1].x1 == 0.0 && faces[1].x2 == 6.0
    @test isempty(SS._efm_wall_faces(solve_once, [column, column], 2.0u"Pa", 3.0u"Pa", 1, false))

    # Without a drop the zero solve is skipped.
    bare_solve(q) = [(span_idx = 1, M_neg_left = ustrip(u"Pa", q[1]) * u"N*m",
                      M_pos = 0.0u"N*m", M_neg_right = 0.0u"N*m")]
    no_drop = SS._efm_wall_faces(bare_solve, [wall, column], 2.0u"Pa", 3.0u"Pa", 1, false;
                                 has_drop = false)
    @test only(no_drop).D ≈ 2.0
    @test only(no_drop).L ≈ 3.0

    # Two spans meet the wall. The larger side is kept: D = 14 − 10 + 10/1.2, L = 6.
    function solve_two(q)
        M = (5.0 + ustrip(u"Pa", q[1])) * u"N*m"
        return [(span_idx = 1, M_neg_left = M, M_pos = M, M_neg_right = 2 * M),
                (span_idx = 2, M_neg_left = M, M_pos = M, M_neg_right = M)]
    end
    interior = SS._efm_wall_faces(solve_two, [column, wall, column], 2.0u"Pa", 3.0u"Pa", 2, false)
    @test length(interior) == 1
    @test interior[1].D ≈ 4.0 + 10.0 / 1.2
    @test interior[1].L ≈ 6.0

    # Direct design splits the factored support moment by qD/qu and qL/qu.
    spans = [(span_idx = 1, M_neg_left = 10.0u"N*m", M_pos = 4.0u"N*m",
              M_neg_right = 10.0u"N*m")]
    split = SS._factored_wall_faces(spans, [wall, column], 5.0u"Pa", 2.0u"Pa", 3.0u"Pa")
    @test length(split) == 1
    @test split[1].D ≈ 4.0
    @test split[1].L ≈ 6.0

    # Frame lines add. Reversed endpoints are the same wall.
    other = SS.SlabWallFaceMoment(1.0, 1.0, 6.0, 0.0, 0.0, 0.0)
    summed = SS._sum_wall_faces([[faces[1]], [other]])
    @test length(summed) == 1
    @test summed[1].D ≈ faces[1].D + 1.0
    @test summed[1].L ≈ 4.0
end

@testset "Top bars at a wall develop by embedment or a hook" begin
    # ACI 318-11 §12.2.2 other cases and §12.5.2 (corpus: aci-318-11,
    # pages 214 and 217). Grade 60, f'c = 4000 psi, λ = 1, ψt = 1.3, #4.
    fc = 4000u"psi"
    fy = 60u"ksi"
    ld = SS.tension_development_length(4, fc, fy, 1.0)
    ldh = SS.hooked_development_length(4, fc, fy, 1.0)
    @test ustrip(u"inch", ld) ≈ 3 * 60000 * 1.3 / (50 * sqrt(4000)) * 0.5 atol = 0.01
    @test ustrip(u"inch", ldh) ≈ 0.02 * 60000 / sqrt(4000) * 0.5 atol = 0.01

    # 0.30 m wall, 0.75 in cover. The straight bar does not fit. The hook does.
    cover = 0.75u"inch"
    thin = SS.wall_negative_anchorage(4, fc, fy, 1.0, 0.30u"m", cover)
    @test thin.anchorage == :hook
    @test thin.ok

    # A #8 hook is longer than that wall. §12.12.1 is not satisfied.
    thick_bar = SS.wall_negative_anchorage(8, fc, fy, 1.0, 0.30u"m", cover)
    @test thick_bar.anchorage == :insufficient
    @test !thick_bar.ok

    # §12.2.1: ℓd is not less than 12 in.
    short = SS.tension_development_length(4, 40000u"psi", fy, 1.0; ψt = 1.0)
    @test short == 12.0u"inch"
end
