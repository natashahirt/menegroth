# EFM frames are one column line each (ACI 318-11 §13.7.2).
#
# A 3×3 bay has four lines in each direction. Edge lines are half a bay
# wide (§13.7.2.4); interior lines run centerline to centerline (§13.7.2.2).
# On a square plan the four corners share one unbalanced moment and the
# eight edge columns share another. A corner is the end of a half-bay
# frame; a mid-side edge is the end of a full-bay frame.

using Test
using Unitful
using Asap
using StructuralSizer

mutable struct EFMGridBase
    L::typeof(1.0u"ft")
end

mutable struct EFMGridColumn
    vertex_idx::Int
    position::Symbol
    story::Int
    c1::typeof(1.0u"inch")
    c2::typeof(1.0u"inch")
    base::EFMGridBase
    column_above::Union{Nothing, EFMGridColumn}
end

EFMGridColumn(vi, pos, story, c1, c2, base) =
    EFMGridColumn(vi, pos, story, c1, c2, base, nothing)

"""4×4 columns on a square 3×3 bay. List order walks each X-line, which is not the span order."""
function efm_square_grid(; bay = 20.0u"ft", c = 16.0u"inch", H = 10.0u"ft",
                         sdl = 20.0u"psf", live = 150.0u"psf")
    bay_m = ustrip(u"m", bay)
    vid(i, j) = (i - 1) * 4 + j
    xy = zeros(16, 2)
    columns = EFMGridColumn[]
    meta = Tuple{Int, Int}[]
    for i in 1:4, j in 1:4
        k = vid(i, j)
        xy[k, 1] = (i - 1) * bay_m
        xy[k, 2] = (j - 1) * bay_m
        edge_x = i == 1 || i == 4
        edge_y = j == 1 || j == 4
        pos = if edge_x && edge_y
            :corner
        elseif edge_x || edge_y
            :edge
        else
            :interior
        end
        col = EFMGridColumn(k, pos, 1, c, c, EFMGridBase(H))
        col.column_above = EFMGridColumn(k, pos, 2, c, c, EFMGridBase(H))
        push!(columns, col)
        push!(meta, (i, j))
    end
    faces = Vector{Int}[]
    cells = NamedTuple[]
    for i in 1:3, j in 1:3
        push!(faces, [vid(i, j), vid(i + 1, j), vid(i + 1, j + 1), vid(i, j + 1)])
        edge_x = i == 1 || i == 3
        edge_y = j == 1 || j == 3
        pos = if edge_x && edge_y
            :corner
        elseif edge_x || edge_y
            :edge
        else
            :interior
        end
        push!(cells, (sdl = sdl, live_load = live, face_idx = length(faces), position = pos))
    end
    slab = (
        cell_indices = collect(1:9),
        spans = (primary = bay, secondary = bay),
    )
    struc = (
        skeleton = (geometry = (vertex_coords = xy,), face_vertex_indices = faces),
        cells = cells,
        columns = columns,
        slabs = [slab],
    )
    return struc, slab, columns, meta
end

function efm_run(method, struc, slab, columns; h = 9.0u"inch")
    fc = 4000.0u"psi"
    return StructuralSizer.run_moment_analysis(
        method, struc, slab, columns, h, fc, Ec(fc), 2400.0u"kg/m^3",
    )
end

function efm_run_secondary(method, struc, slab, columns; h = 9.0u"inch")
    fc = 4000.0u"psi"
    return StructuralSizer.run_secondary_moment_analysis(
        method, struc, slab, columns, h, fc, Ec(fc), 2400.0u"kg/m^3",
    )
end

kft(m) = ustrip(kip * u"ft", m)

function governing_kft(primary, secondary, k)
    return max(abs(kft(primary.unbalanced_moments[k])), abs(kft(secondary.unbalanced_moments[k])))
end

function class_indices(meta)
    corners = Int[]
    edges = Int[]
    interiors = Int[]
    west = Int[]
    south = Int[]
    for (k, (i, j)) in enumerate(meta)
        on_x = i == 1 || i == 4
        on_y = j == 1 || j == 4
        if on_x && on_y
            push!(corners, k)
        elseif on_x || on_y
            push!(edges, k)
            i == 1 && j in (2, 3) && push!(west, k)
            j == 1 && i in (2, 3) && push!(south, k)
        else
            push!(interiors, k)
        end
    end
    return (; corners, edges, interiors, west, south)
end

@testset "EFM column lines follow §13.7.2" begin
    struc, slab, columns, _meta = efm_square_grid()
    h = 9.0u"inch"
    γ = 2400.0u"kg/m^3"
    primary = StructuralSizer._moment_analysis_setup(struc, slab, columns, h, γ)
    secondary = StructuralSizer._secondary_moment_analysis_setup(struc, slab, columns, h, γ)
    x_lines = StructuralSizer._equivalent_frames(struc, columns, primary)
    y_lines = StructuralSizer._equivalent_frames(struc, columns, secondary)

    @test length(x_lines) == 4
    @test length(y_lines) == 4
    @test all(line -> length(line.columns) == 4, x_lines)
    @test all(line -> length(line.columns) == 4, y_lines)
    ids = [objectid(col) for line in x_lines for col in line.columns]
    @test length(ids) == length(unique(ids)) == 16

    xw = [ustrip(u"ft", line.tributary_width) for line in x_lines]
    yw = [ustrip(u"ft", line.tributary_width) for line in y_lines]
    @test xw[1] ≈ 10 rtol = 1e-6
    @test xw[4] ≈ 10 rtol = 1e-6
    @test xw[2] ≈ 20 rtol = 1e-6
    @test xw[3] ≈ 20 rtol = 1e-6
    @test yw ≈ xw rtol = 1e-6
end

@testset "Symmetric 3×3 bay, Hardy Cross" begin
    struc, slab, columns, meta = efm_square_grid()
    method = EFM(solver = :hardy_cross, pattern_loading = false)
    primary = efm_run(method, struc, slab, columns)
    secondary = efm_run_secondary(method, struc, slab, columns)
    ix = class_indices(meta)

    @test length(ix.corners) == 4
    @test length(ix.edges) == 8
    @test length(ix.interiors) == 4
    @test ustrip(u"ft", primary.l1) ≈ 20 rtol = 1e-6
    @test ustrip(u"ft", primary.l2) ≈ 20 rtol = 1e-6
    @test ustrip(u"ft", primary.ln) ≈ 20 - 16 / 12 rtol = 1e-4

    corners = [governing_kft(primary, secondary, k) for k in ix.corners]
    edges = [governing_kft(primary, secondary, k) for k in ix.edges]
    interiors = [governing_kft(primary, secondary, k) for k in ix.interiors]
    @test maximum(corners) ≈ minimum(corners) rtol = 1e-4
    @test maximum(edges) ≈ minimum(edges) rtol = 1e-4
    @test maximum(interiors) ≈ minimum(interiors) rtol = 1e-4
    @test 40 < minimum(edges) < 300
    @test 40 < minimum(corners) < 300

    west = ix.west[1]
    south = ix.south[1]
    @test abs(kft(primary.unbalanced_moments[west])) ≈
        abs(kft(secondary.unbalanced_moments[south])) rtol = 1e-4
    @test abs(kft(secondary.unbalanced_moments[west])) ≈
        abs(kft(primary.unbalanced_moments[south])) rtol = 1e-4

    # Same index the punching check reads. The four corners are not one beam's two ends.
    corner_x = [abs(kft(primary.unbalanced_moments[k])) for k in ix.corners]
    @test maximum(corner_x) ≈ minimum(corner_x) rtol = 1e-4
end

@testset "Pattern loading keeps the 3×3 bay symmetric" begin
    struc, slab, columns, meta = efm_square_grid()
    method = EFM(solver = :hardy_cross, pattern_loading = true)
    primary = efm_run(method, struc, slab, columns)
    secondary = efm_run_secondary(method, struc, slab, columns)
    ix = class_indices(meta)
    edges = [governing_kft(primary, secondary, k) for k in ix.edges]
    corners = [governing_kft(primary, secondary, k) for k in ix.corners]
    @test primary.pattern_loading
    @test maximum(edges) ≈ minimum(edges) rtol = 1e-4
    @test maximum(corners) ≈ minimum(corners) rtol = 1e-4
end

@testset "Perimeter moments are in DDM's range" begin
    struc, slab, columns, meta = efm_square_grid()
    efm = EFM(solver = :hardy_cross, pattern_loading = false)
    efm_x = efm_run(efm, struc, slab, columns)
    efm_y = efm_run_secondary(efm, struc, slab, columns)
    ddm = DDM()
    ddm_x = efm_run(ddm, struc, slab, columns)
    ddm_y = efm_run_secondary(ddm, struc, slab, columns)
    ix = class_indices(meta)
    for k in [ix.corners; ix.edges]
        e = governing_kft(efm_x, efm_y, k)
        d = governing_kft(ddm_x, ddm_y, k)
        @test d > 1
        @test 0.35 <= e / d <= 2.0
    end
end

@testset "ASAP and Hardy Cross agree" begin
    struc, slab, columns, meta = efm_square_grid()
    hc = EFM(solver = :hardy_cross, pattern_loading = false, column_stiffness = :Kec)
    asap = EFM(solver = :asap, pattern_loading = false, column_stiffness = :Kec)
    hc_x = efm_run(hc, struc, slab, columns)
    hc_y = efm_run_secondary(hc, struc, slab, columns)
    as_x = efm_run(asap, struc, slab, columns)
    as_y = efm_run_secondary(asap, struc, slab, columns)
    ix = class_indices(meta)
    for k in [ix.corners; ix.edges; ix.interiors]
        @test governing_kft(as_x, as_y, k) ≈ governing_kft(hc_x, hc_y, k) rtol = 0.15
    end
    for name in (:M_neg_ext, :M_neg_int, :M_pos)
        @test abs(kft(getfield(as_x, name))) ≈ abs(kft(getfield(hc_x, name))) rtol = 0.15
    end
end

# One ordered line and no skeleton geometry: the StructurePoint 3-span strip.
mutable struct EFMLineBase
    L::typeof(1.0u"ft")
end

mutable struct EFMLineColumn
    vertex_idx::Int
    position::Symbol
    story::Int
    c1::typeof(1.0u"inch")
    c2::typeof(1.0u"inch")
    base::EFMLineBase
    column_above::Union{Nothing, EFMLineColumn}
end

EFMLineColumn(vi, pos, story, c1, c2, base) =
    EFMLineColumn(vi, pos, story, c1, c2, base, nothing)

function efm_three_span_line()
    span = 18.0u"ft"
    trib = 14.0u"ft"
    c = 16.0u"inch"
    H = 9.0u"ft"
    cells = [(sdl = 20.0u"psf", live_load = 50.0u"psf", face_idx = 1)]
    columns = EFMLineColumn[]
    for i in 1:4
        pos = i == 1 || i == 4 ? :edge : :interior
        col = EFMLineColumn(i, pos, 1, c, c, EFMLineBase(H))
        col.column_above = EFMLineColumn(i, pos, 2, c, c, EFMLineBase(H))
        push!(columns, col)
    end
    slab = (cell_indices = [1], spans = (primary = span, secondary = trib))
    struc = (cells = cells, columns = columns)
    return struc, slab, columns
end

@testset "Three-span line matches across solvers" begin
    struc, slab, columns = efm_three_span_line()
    hc = efm_run(EFM(solver = :hardy_cross, pattern_loading = false), struc, slab, columns; h = 7.0u"inch")
    asap = efm_run(EFM(solver = :asap, pattern_loading = false), struc, slab, columns; h = 7.0u"inch")

    @test length(hc.unbalanced_moments) == 4
    @test ustrip(u"ft", hc.l1) ≈ 18 rtol = 1e-6
    @test ustrip(u"ft", hc.l2) ≈ 14 rtol = 1e-6
    @test abs(kft(hc.unbalanced_moments[1])) ≈ abs(kft(hc.unbalanced_moments[4])) rtol = 1e-4
    @test abs(kft(hc.unbalanced_moments[2])) ≈ abs(kft(hc.unbalanced_moments[3])) rtol = 1e-4
    for name in (:M_neg_ext, :M_neg_int, :M_pos)
        @test abs(kft(getfield(hc, name))) ≈ abs(kft(getfield(asap, name))) rtol = 0.15
    end
    for i in 1:4
        @test abs(kft(hc.unbalanced_moments[i])) ≈ abs(kft(asap.unbalanced_moments[i])) rtol = 0.15
    end
    # End span of a 3-span frame: the first interior negative exceeds the exterior negative.
    @test abs(kft(hc.M_neg_int)) > abs(kft(hc.M_neg_ext)) > 0
    @test abs(kft(hc.M_pos)) > 0
end
