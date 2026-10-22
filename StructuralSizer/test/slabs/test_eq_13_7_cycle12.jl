# =============================================================================
# Eq. (13-7) cycle 12 — transverse gap, far column beside a slot, edge
# overhang, and §13.6.1.1 span count.
#
# ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258).
# ℓn is face to face of columns, §13.6.2.5 (page 253).
# Three continuous spans in each direction, §13.6.1.1 (page 252).
# Reference: 20/30 ft bays, 12 in columns, qD = 150 psf, qL = 50 psf,
# design column at x = 20.  Column-to-column Mub = 168.056 kip·ft.
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

const HAS_STRUCTURAL_SYNTHESIZER = let ok = true
    try
        @eval using StructuralSynthesizer
    catch
        ok = false
    end
    ok
end

const qD = 150.0u"psf"
const qL = 50.0u"psf"
const FT = 0.3048
const HAND = 168.056

kft(x) = ustrip(u"kip*ft", x)
quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

"""Column-to-column Eq. (13-7) with ℓ2 = 20 ft, ℓn = 29 ft and 19 ft."""
function hand_137(lnA, lnB; l2A = 20.0, l2B = 20.0)
    lnA < lnB && ((lnA, lnB) = (lnB, lnA); (l2A, l2B) = (l2B, l2A))
    D = ustrip(u"psf", qD)
    L = ustrip(u"psf", qL)
    f(qDu, qLu) = 0.07 * ((qDu + 0.5 * qLu) * l2A * lnA^2 - qDu * l2B * lnB^2) / 1000
    return max(f(1.2 * D, 1.6 * L), f(1.4 * D, 0.0))
end

mk(v; pos = :interior) = (
    vertex_idx = v, position = pos, c1 = 12.0u"inch", c2 = 12.0u"inch",
    θ = 0.0, structural_offset = (0.0, 0.0), tributary_cell_indices = Int[1],
)

function assemble(pts, faces, cols)
    vc = zeros(length(pts), 2)
    for (i, p) in enumerate(pts)
        vc[i, 1] = p[1] * FT
        vc[i, 2] = p[2] * FT
    end
    cells = Any[(face_idx = k, sdl = qD, live_load = qL, self_weight = 0.0u"psf")
                for k in eachindex(faces)]
    sp = (primary = 30.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0))
    slabs = Any[(cell_indices = collect(eachindex(faces)), spans = sp)]
    return (cells = cells, slabs = slabs, columns = cols,
            skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
end

"""Transfer moment (kip·ft), trace, resolved sides, and applicability."""
function probe(st, col)
    tc = SS.TraceCollector()
    ctx = SS._eq137_context(st, st.columns)
    M0 = SS.total_static_moment(max(1.4qD, 1.2qD + 1.6qL), 20.0u"ft", 19.0u"ft")
    M = quiet(() -> SS._eq137_transfer_moment(
        st, st.slabs[1], col, (1.0, 0.0), qD, qL, 20.0u"ft", 19.0u"ft", M0;
        extra_columns = st.columns, index = ctx.index, vertex_column = ctx.vertex_column,
        cell_slab = ctx.cell_slab, partway = ctx.partway, tc = tc))
    sides = quiet(() -> SS._eq137_resolved_sides(
        st, st.slabs[1], col, (1.0, 0.0); extra_columns = st.columns))
    appl = quiet(() -> SS.check_ddm_applicability(
        st, st.slabs[1], st.columns; throw_on_failure = false))
    return (M = kft(M), M0 = kft(M0), tc = tc, sides = sides, appl = appl)
end

"""Finite moment at least the column-to-column value, or NaN with a failure trace."""
function envelope_holds(M, tc; hand = HAND)
    if isfinite(M)
        return M >= hand * (1 - 1e-6)
    end
    return any(e -> e.event_type == :failure, tc.events)
end

function grid_faces(xs, ys; drop = Set{Tuple{Int,Int}}())
    pts = NTuple{2,Float64}[]
    id = Dict{NTuple{2,Float64},Int}()
    V(x, y) = get!(id, (x, y)) do
        push!(pts, (x, y))
        length(pts)
    end
    faces = Vector{Int}[]
    for i in 1:length(xs)-1, j in 1:length(ys)-1
        (i, j) in drop && continue
        push!(faces, [V(xs[i], ys[j]), V(xs[i+1], ys[j]),
                      V(xs[i+1], ys[j+1]), V(xs[i], ys[j+1])])
    end
    return pts, faces, V
end

@testset "Eq. (13-7) cycle 12" begin
    @test hand_137(29.0, 19.0) ≈ HAND rtol = 1e-6

    @testset "P0a: sliver then a 1.5 ft gap still counts the later panel" begin
        # 3-span grid.  Bay x = 20..50, y = 20..40 is a 0.3 ft sliver and a
        # panel y = 21.8..40.  The 1.5 ft gap is wider than 0.35 m and used
        # to drop the later panel (east ℓ2 = 10.15 ft, Mub = 40.485).
        xs = [0.0, 20.0, 50.0, 70.0]
        ys = [0.0, 20.0, 40.0, 60.0]
        pts = NTuple{2,Float64}[]
        id = Dict{NTuple{2,Float64},Int}()
        V(x, y) = get!(id, (x, y)) do
            push!(pts, (x, y)); length(pts)
        end
        faces = Vector{Int}[]
        for i in 1:3, j in 1:3
            push!(faces, [V(xs[i], ys[j]), V(xs[i+1], ys[j]),
                          V(xs[i+1], ys[j+1]), V(xs[i], ys[j+1])])
        end
        target = Set([V(20.0, 20.0), V(50.0, 20.0), V(50.0, 40.0), V(20.0, 40.0)])
        faces = [f for f in faces if Set(f) != target]
        push!(faces, [V(20.0, 20.0), V(50.0, 20.0), V(50.0, 20.3), V(20.0, 20.3)])
        push!(faces, [V(20.0, 21.8), V(50.0, 21.8), V(50.0, 40.0), V(20.0, 40.0)])
        cols = Any[mk(V(x, y)) for x in xs for y in ys]
        st = assemble(pts, faces, cols)
        col = cols[findfirst(c -> c.vertex_idx == V(20.0, 20.0), cols)]
        r = probe(st, col)
        @test envelope_holds(r.M, r.tc)
        @test !(isfinite(r.M) && r.M < HAND)
        if isfinite(r.M) && r.sides isa AbstractVector
            east = only(s for s in r.sides if s.side == 1)
            # The later panel is inside the column line at y = 40, so ℓ2
            # is the full 20 ft strip, not half the sliver.
            @test ustrip(u"ft", east.l2) ≈ 20.0 rtol = 1e-6
            @test any(e -> e.event_type == :decision &&
                           get(e.data, "reason", "") == "transverse_panel_past_gap",
                      r.tc.events)
        end
    end

    @testset "P0b: slab beside a slot keeps the far column" begin
        # Thin rows y in [19.6, 20.4] dropped for x in [30, 50].  The 12 in
        # column at (50, 20) still meets the slab.  Before: :boundary,
        # ℓn = 9.5, range 0..9.5, Mub = 111.188.
        xs = [0.0, 20.0, 30.0, 50.0, 70.0]
        ys = [0.0, 19.6, 20.0, 20.4, 40.0, 60.0]
        pts = NTuple{2,Float64}[]
        id = Dict{NTuple{2,Float64},Int}()
        V(x, y) = get!(id, (x, y)) do
            push!(pts, (x, y)); length(pts)
        end
        faces = Vector{Int}[]
        for i in 1:length(xs)-1, j in 1:length(ys)-1
            slot = xs[i] >= 30.0 - 1e-9 && xs[i+1] <= 50.0 + 1e-9 &&
                   ys[j] >= 19.6 - 1e-9 && ys[j+1] <= 20.4 + 1e-9
            slot && continue
            push!(faces, [V(xs[i], ys[j]), V(xs[i+1], ys[j]),
                          V(xs[i+1], ys[j+1]), V(xs[i], ys[j+1])])
        end
        cols = Any[mk(V(x, y)) for x in (0.0, 20.0, 50.0, 70.0) for y in (0.0, 20.0, 40.0, 60.0)]
        st = assemble(pts, faces, cols)
        col = cols[findfirst(c -> c.vertex_idx == V(20.0, 20.0), cols)]
        r = probe(st, col)
        @test envelope_holds(r.M, r.tc)
        @test !(isfinite(r.M) && r.M < HAND)
        if isfinite(r.M) && r.sides isa AbstractVector
            east = only(s for s in r.sides if s.side == 1)
            # ℓn = 0 is not the top of the admitted range.
            @test ustrip(u"ft", east.ln_range[2]) >= 29.0 - 1e-6
            @test east.status != :boundary
        end
    end

    @testset "P1a: overhang across an edge line does not NaN a clean DDM" begin
        # Bottom bay is one face from y = -2 to y = 20.  Column (20, 0) is
        # mid-edge; nothing is south of y = 0.  Before: Mub = NaN,
        # near_faces_unresolved, applicability ok.
        xs = [0.0, 20.0, 50.0, 70.0]
        pts = NTuple{2,Float64}[]
        id = Dict{NTuple{2,Float64},Int}()
        V(x, y) = get!(id, (x, y)) do
            push!(pts, (x, y)); length(pts)
        end
        faces = Vector{Int}[]
        for i in 1:3
            push!(faces, [V(xs[i], -2.0), V(xs[i+1], -2.0), V(xs[i+1], 20.0), V(xs[i], 20.0)])
        end
        for i in 1:3, y0 in (20.0, 40.0)
            push!(faces, [V(xs[i], y0), V(xs[i+1], y0), V(xs[i+1], y0 + 20.0), V(xs[i], y0 + 20.0)])
        end
        cols = Any[mk(V(x, y)) for x in xs for y in (0.0, 20.0, 40.0, 60.0)]
        st = assemble(pts, faces, cols)
        edge = cols[findfirst(c -> c.vertex_idx == V(20.0, 0.0), cols)]
        r = probe(st, edge)
        # NaN together with a clean applicability check leaves no FEA fallback.
        @test !( !isfinite(r.M) && r.appl.ok )
        if isfinite(r.M)
            # §13.6.3.6 edge value of the panel in hand (0.3 M0).  The
            # overhang is not a span, so the moment is at least that large.
            @test r.M >= 0.3 * r.M0 - 1e-6
        else
            @test !r.appl.ok
            @test any(e -> e.event_type == :failure, r.tc.events)
        end
        # Interior column on the same mesh stays on the column-to-column value.
        interior = cols[findfirst(c -> c.vertex_idx == V(20.0, 20.0), cols)]
        ri = probe(st, interior)
        @test ri.M ≈ HAND rtol = 1e-4
        @test !any(e -> e.event_type == :failure, ri.tc.events)
    end

    @testset "P1c: §13.6.1.1 counts spans, not columns" begin
        # Two spans in x (0–20, 20–50) and one in y (0–20).  Six columns
        # used to pass the old n_cols >= 4 test.
        pts = NTuple{2,Float64}[]
        id = Dict{NTuple{2,Float64},Int}()
        V(x, y) = get!(id, (x, y)) do
            push!(pts, (x, y)); length(pts)
        end
        faces = Vector{Int}[
            [V(0.0, 0.0), V(20.0, 0.0), V(20.0, 20.0), V(0.0, 20.0)],
            [V(0.0, -20.0), V(20.0, -20.0), V(20.0, 0.0), V(0.0, 0.0)],
            [V(20.0, -20.0), V(50.0, -20.0), V(50.0, 0.0), V(20.0, 0.0)],
            [V(20.0, 1.5), V(50.0, 1.5), V(50.0, 20.0), V(20.0, 20.0)],
        ]
        cols = Any[mk(V(x, y)) for (x, y) in (
            (0.0, 0.0), (20.0, 0.0), (50.0, 0.0),
            (0.0, 20.0), (20.0, 20.0), (50.0, 20.0))]
        st = assemble(pts, faces, cols)
        appl = quiet(() -> SS.check_ddm_applicability(
            st, st.slabs[1], st.columns; throw_on_failure = false))
        @test !appl.ok
        @test any(v -> occursin("13.6.1.1", v), appl.violations)

        # 4 × 4 column grid: 3 spans each way.  DDM stays eligible.
        xs = [0.0, 20.0, 40.0, 60.0]
        ys = [0.0, 20.0, 40.0, 60.0]
        pts4, faces4, V4 = grid_faces(xs, ys)
        cols4 = Any[mk(V4(x, y)) for x in xs for y in ys]
        st4 = assemble(pts4, faces4, cols4)
        appl4 = quiet(() -> SS.check_ddm_applicability(
            st4, st4.slabs[1], st4.columns; throw_on_failure = false))
        @test appl4.ok
        counts = SS._ddm_continuous_span_counts(st4, st4.columns, (1.0, 0.0))
        @test counts == (3, 3)
    end

    @testset "control: 3-span interior column stays 168.056" begin
        xs = [0.0, 20.0, 50.0, 70.0]
        ys = [0.0, 20.0, 40.0, 60.0]
        pts, faces, V = grid_faces(xs, ys)
        cols = Any[mk(V(x, y)) for x in xs for y in ys]
        st = assemble(pts, faces, cols)
        col = cols[findfirst(c -> c.vertex_idx == V(20.0, 20.0), cols)]
        r = probe(st, col)
        @test r.M ≈ HAND rtol = 1e-4
        @test r.appl.ok
        @test !any(e -> e.event_type == :failure, r.tc.events)
    end

    @testset "P1b: design_building slab result keeps the fallback notice" begin
        @test HAS_STRUCTURAL_SYNTHESIZER
        blank = StructuralSynthesizer.SlabDesignResult(
            thickness = 0.2u"m", self_weight = 4.0u"kPa")
        @test hasproperty(blank, :method_requested)
        @test hasproperty(blank, :method_used)
        @test hasproperty(blank, :method_fallback_reasons)
        @test blank.method_requested === nothing
        @test blank.method_used === nothing
        @test blank.method_fallback_reasons == String[]
        noticed = StructuralSynthesizer.SlabDesignResult(
            thickness = 0.2u"m", self_weight = 4.0u"kPa")
        dd = (method_requested = SS.DDM(), method_used = SS.FEA(),
              method_fallback_reasons = ["§13.6.1.1 spans"])
        StructuralSynthesizer._copy_method_notice!(noticed, dd)
        @test noticed.method_requested isa SS.DDM
        @test noticed.method_used isa SS.FEA
        @test noticed.method_fallback_reasons == ["§13.6.1.1 spans"]
    end
end
