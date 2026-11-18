# The slab is joined to the walls. It is not fixed in space.
#
# ACI 318-11 R13.6.3.3 (corpus: aci-318-11, page 254) chooses a direct-design
# moment coefficient for an edge cast with a stiff wall. The shell shares the
# slab nodes with the wall and holds the wall's base, one pier below the slab.
# q L²/12 and q L⁴/(384 D) are the statics of a fully fixed strip. They are
# the comparison, not the answer: a wall of finite stiffness rotates, so the
# edge moment is smaller and the deflection is larger. They are not code
# coefficients.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SY = StructuralSynthesizer

"""One rectangular story. `xs` and `ys` are the boundary stations, in metres."""
function _walled_story(xs, ys; sdl, column_ys = Float64[])
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    pts = Tuple{Float64, Float64}[]
    for x in xs
        push!(pts, (x, ys[1]))
    end
    for y in ys[2:end]
        push!(pts, (xs[end], y))
    end
    for x in reverse(xs[1:end-1])
        push!(pts, (x, ys[end]))
    end
    for y in reverse(ys[2:end-1])
        push!(pts, (xs[1], y))
    end
    ids = Dict{NTuple{2, Float64}, Int}()
    order = Int[]
    for p in pts
        id = add_vertex!(skel, [p[1], p[2], z])
        ids[p] = id
        push!(order, id)
    end
    for i in eachindex(order)
        add_element!(skel, order[i], order[mod1(i + 1, length(order))]; group = :beams)
    end
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    face = findfirst(vs -> Set(vs) == Set(order), skel.face_vertex_indices)
    face === nothing && error("the wall story has no face")
    Lx = xs[end] - xs[1]
    Ly = ys[end] - ys[1]
    spans = SpanInfo{Float64}(Ly, Lx, (0.0, 1.0), min(Lx, Ly))
    cell = Cell(face, (Lx * Ly) * u"m^2", spans, sdl, 0.0u"kN/m^2")
    cell.floor_type = :one_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab([1], CIPSlabResult(0.20, 0.20, 5.0), spans; floor_type = :one_way))
    for y in (ys[1], ys[end])
        push!(struc.walls, Wall(1, 3.0; thickness = 0.30,
                                 x1 = xs[1], y1 = y, x2 = xs[end], y2 = y, story = 0))
    end
    columns = NTuple{2, Float64}[]
    for y in column_ys
        for x in (xs[1], xs[end])
            push!(struc.columns, Column(1, 3.0; vertex_idx = ids[(x, y)], story = 0))
            push!(columns, (x, y))
        end
    end
    return struc, columns
end

"""Global Myy (N·m/m) of one shell triangle. Local moments are rotated by its axes."""
function _global_myy(el, model, M, ws)
    bending_moments!(M, el, model.u, ws)
    ex2 = el.LCS[1][2]
    ey2 = el.LCS[2][2]
    return M[1] * ex2^2 + M[2] * ey2^2 + 2 * M[3] * ex2 * ey2
end

"""Area-weighted Myy of the triangles whose centroids sit in the box."""
function _band_myy(shells, model, x0, x1, y0, y1)
    M = zeros(3)
    ws = ShellMomentWorkspace()
    acc = 0.0
    area = 0.0
    yacc = 0.0
    for el in shells
        c = Asap.shell_centroid(el)
        (x0 <= c.x <= x1 && y0 <= c.y <= y1) || continue
        my = _global_myy(el, model, M, ws)
        acc += my * el.area
        yacc += c.y * el.area
        area += el.area
    end
    area > 0 || error("no shell triangles in ($x0,$x1) × ($y0,$y1)")
    return (Myy = acc / area, y = yacc / area, area = area)
end

"""
Fixed-end strip, uniform `q`, span `L`, `y` measured from one wall.

`M(0) = -q L²/12`, `M(L/2) = q L²/24`. Sagging is positive.
"""
_strip_M(q, L, y) = -q * L^2 / 12 + q * L * y / 2 - q * y^2 / 2

_xy_is(p, q; atol = 1e-9) = abs(p[1] - q[1]) <= atol && abs(p[2] - q[2]) <= atol

@testset "solid wall pieces" begin
    H = 3.0u"m"
    # The head of this window is the pier top, so the soffit has no wall there.
    reaching = WallOpening(2.0, 1.5, 1.5, 1.5, :window)
    wall = Wall(1, H; thickness = 0.20u"m", x1 = 0.0, y1 = 0.0, x2 = 6.0, y2 = 0.0,
                openings = [reaching])
    pieces = SY._solid_wall_pieces(wall)
    @test length(pieces) == 2
    @test _xy_is(pieces[1][1], (0.0, 0.0))
    @test _xy_is(pieces[1][2], (2.0, 0.0))
    @test _xy_is(pieces[2][1], (3.5, 0.0))
    @test _xy_is(pieces[2][2], (6.0, 0.0))

    # A window that stops short of the soffit leaves the support line whole.
    short = WallOpening(2.0, 0.8, 1.5, 1.2, :window)
    whole = Wall(1, H; thickness = 0.20u"m", x1 = 0.0, y1 = 0.0, x2 = 6.0, y2 = 0.0,
                 openings = [short])
    one = SY._solid_wall_pieces(whole)
    @test length(one) == 1
    @test _xy_is(one[1][1], (0.0, 0.0))
    @test _xy_is(one[1][2], (6.0, 0.0))

    # Overlapping full-height openings are one gap.
    a = WallOpening(1.0, 0.0, 2.0, 3.0, :door)
    b = WallOpening(2.5, 0.0, 1.0, 3.0, :other)
    merged = Wall(1, H; thickness = 0.20u"m", x1 = 0.0, y1 = 0.0, x2 = 6.0, y2 = 0.0,
                  openings = [b, a])
    gaps = SY._solid_wall_pieces(merged)
    @test length(gaps) == 2
    @test _xy_is(gaps[1][2], (1.0, 0.0))
    @test _xy_is(gaps[2][1], (3.5, 0.0))
end

@testset "one-way slab between two walls" begin
    Lx, Ly = 16.0, 4.0
    struc, _ = _walled_story([0.0, Lx], [0.0, Ly]; sdl = 10.0u"kN/m^2")
    @test SY._story_shell_design_levels(struc) == [0]
    lines = SY._story_wall_supports(struc, 0)
    @test length(lines) == 2

    result = analyze_story_shell(struc, 0; target_edge = 0.5u"m", service = false)
    @test result.analysis_status == :analyzed
    model = result.model
    @test model !== nothing

    edge = 0
    bases = 0
    for node in result.built.nodes
        y = ustrip(u"m", node.position[2])
        z = ustrip(u"m", node.position[3])
        (abs(y) < 1e-6 || abs(y - Ly) < 1e-6) || continue
        if abs(z) < 1e-6
            @test node.dof[3] == true
            @test node.dof[4] == true
            @test node.dof[5] == true
            edge += 1
        elseif z < -1.0
            @test node.dof[1] == false
            @test node.dof[2] == false
            @test node.dof[3] == false
            @test node.dof[4] == true
            @test node.dof[5] == true
            @test node.dof[6] == true
            bases += 1
        end
    end
    @test edge > 4
    @test bases > 4
    @test any(el -> el.id === :wall, result.model.shell_elements)

    mid = argmin(n -> hypot(ustrip(u"m", n.position[1]) - Lx / 2,
                            ustrip(u"m", n.position[2]) - Ly / 2),
                 result.built.nodes)
    el = result.built.shells[1]
    q = ustrip(u"Pa", SY.total_factored_pressure(struc.cells[1]))
    D = el.E * el.thickness^3 / (12 * (1 - el.ν^2))
    δ_fixed = q * Ly^4 / (384 * D)
    uz = ustrip(u"m", mid.displacement[3])
    # The wall rotates with the slab, so the deflection is past the fixed
    # strip and short of the simple strip (five times the fixed value).
    @test uz < 0
    @test abs(uz) > δ_fixed
    @test abs(uz) < 5 * δ_fixed

    # ShellTri3 sets κyy = −∂θx/∂y. The strip sags downward (uz < 0 above),
    # so Myy is negative at midspan and positive at the wall. The edge moment
    # is below the fixed-end value because the wall is not rigid.
    xc = Lx / 2
    support = _band_myy(result.built.shells, model, xc - 1.0, xc + 1.0, 0.0, 0.60)
    middle = _band_myy(result.built.shells, model, xc - 1.0, xc + 1.0, Ly / 2 - 0.40, Ly / 2 + 0.40)
    @test 0 < support.Myy < -_strip_M(q, Ly, support.y)
    @test middle.Myy ≈ -_strip_M(q, Ly, middle.y) rtol = 0.15
    @test middle.Myy < 0

    total = 0.0
    bottom = 0.0
    top = 0.0
    for node in model.nodes
        node.dof[3] && continue
        fz = ustrip(u"N", node.reaction[3])
        total += fz
        y = ustrip(u"m", node.position[2])
        abs(y) < 1e-3 && (bottom += fz)
        abs(y - Ly) < 1e-3 && (top += fz)
    end
    @test total ≈ q * Lx * Ly rtol = 0.01
    @test bottom > 0.4 * total
    @test top > 0.4 * total
    by_wall = SY._factored_wall_reactions(model.nodes,
                                          SY._story_wall_support_pieces(struc, 0))
    @test length(by_wall) == 2
    @test sum(values(by_wall)) ≈ total rtol = 0.01
    @test by_wall[1] ≈ bottom rtol = 0.01
    @test by_wall[2] ≈ top rtol = 0.01
end

@testset "wall and column reactions" begin
    Lx, Ly = 8.0, 6.0
    struc, columns = _walled_story([0.0, Lx], [0.0, Ly / 2, Ly];
                                   sdl = 8.0u"kN/m^2", column_ys = [Ly / 2])
    lines = SY._story_wall_supports(struc, 0)
    result = analyze_story_shell(struc, 0; target_edge = 0.5u"m", service = false)
    @test result.analysis_status == :analyzed
    model = result.model
    wall = 0.0
    column = 0.0
    total = 0.0
    for node in model.nodes
        node.dof[3] && continue
        fz = ustrip(u"N", node.reaction[3])
        total += fz
        pt = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))
        on_wall = any(seg -> StructuralSizer._point_on_segment(pt, seg[1], seg[2]), lines)
        on_col = any(p -> hypot(pt[1] - p[1], pt[2] - p[2]) <= 1e-3, columns)
        if on_wall
            wall += fz
        elseif on_col
            column += fz
            @test node.dof[4] == true
            @test node.dof[5] == true
        end
    end
    q = ustrip(u"Pa", SY.total_factored_pressure(struc.cells[1]))
    @test total ≈ q * Lx * Ly rtol = 0.01
    @test wall + column ≈ total rtol = 0.01
    @test wall > 0.2 * total
    @test column > 0.02 * total
end
