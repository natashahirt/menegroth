# =============================================================================
# Eq. (13-7) cycle 13 — the transverse half-strip must reach the panel
# centerline, not the slab edge.
#
# ACI 318-11 §13.6.2.1 (corpus: aci-318-11, page 253): the total static
# moment is taken on a strip bounded laterally by the centerline of panel on
# each side of the centerline of supports.  §13.6.2.3 (page 253): ℓ2 is the
# center-to-center transverse span.  So the half-strip on a side reaches the
# panel centerline at line / 2, and `_eq137_side_width` caps the covered run
# at that centerline: width = min(run, line / 2).
#
# Regression for the cycle 13 P0: the old `min(run, line) / 2` halved the
# distance to the slab EDGE, so a panel that stopped short of the next column
# line but still covered the centerline reported ℓ2 below 20 ft and an
# unconservative transferred moment.
#
# Reference: 20/30 ft bays, 12 in columns, qD = 150 psf, qL = 50 psf, design
# column at x = 20.  Full-coverage column-to-column Mub = 168.056 kip·ft.
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

const qD = 150.0u"psf"
const qL = 50.0u"psf"
const FT = 0.3048
const HAND = 168.056

kft(x) = ustrip(u"kip*ft", x)
quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

"""
Column-to-column Eq. (13-7) with per-span transverse widths `l2A` (the
ln = 29 ft east span) and `l2B` (the ln = 19 ft west span).  Mirrors the
cycle 12 hand reference; ℓ2 enters each adjoining span's term separately.
"""
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

"""
3-span grid whose two east-bay panels touching the design frame line (y = 20)
are rebuilt with a north edge at `north_hi` and a south edge at `south_lo`.
The east-span transverse centerlines are y = 30 (north) and y = 10 (south),
so the north half reaches its centerline when `north_hi >= 30` and the south
half when `south_lo <= 10`.  Returns `(st, col)` for the design column (20, 20).
"""
function east_bay_case(; north_hi = 40.0, south_lo = 0.0)
    xs = [0.0, 20.0, 50.0, 70.0]
    ys = [0.0, 20.0, 40.0, 60.0]
    pts = NTuple{2,Float64}[]
    id = Dict{NTuple{2,Float64},Int}()
    V(x, y) = get!(id, (x, y)) do
        push!(pts, (x, y)); length(pts)
    end
    faces = Vector{Int}[]
    for i in 1:3, j in 1:3
        # The two east-bay panels straddling the design frame line are rebuilt below.
        (xs[i] == 20.0 && (ys[j] == 20.0 || ys[j] == 0.0)) && continue
        push!(faces, [V(xs[i], ys[j]), V(xs[i+1], ys[j]),
                      V(xs[i+1], ys[j+1]), V(xs[i], ys[j+1])])
    end
    push!(faces, [V(20.0, 20.0), V(50.0, 20.0), V(50.0, north_hi), V(20.0, north_hi)])
    push!(faces, [V(20.0, south_lo), V(50.0, south_lo), V(50.0, 20.0), V(20.0, 20.0)])
    cols = Any[mk(V(x, y)) for x in xs for y in ys]
    st = assemble(pts, faces, cols)
    col = cols[findfirst(c -> c.vertex_idx == V(20.0, 20.0), cols)]
    return (st = st, col = col)
end

"""
East-bay north panel stopping `gap_ft` short of the y = 40 column line (south
half full).  Its transverse centerline is y = 30, covered whenever
`40 - gap_ft > 30`.  Returns `(st, col)` for the design column (20, 20).
"""
gap_case(gap_ft) = east_bay_case(north_hi = 40.0 - gap_ft)

"""Probe of the design column for the `gap_ft` short-north grid."""
gap_probe(gap_ft) = (c = gap_case(gap_ft); probe(c.st, c.col))

"""
Eq. (13-7) transfer moment (kip·ft) and trace for `col`, WITHOUT the
`_eq137_resolved_sides` pass — which rethrows the ambiguous-geometry
`ArgumentError` for a rejected panel.  Used to read the NaN + `:failure` that
`_eq137_transfer_moment` produces when a half-strip stops short of the
centerline.
"""
function transfer_only(st, col)
    tc = SS.TraceCollector()
    ctx = SS._eq137_context(st, st.columns)
    M0 = SS.total_static_moment(max(1.4qD, 1.2qD + 1.6qL), 20.0u"ft", 19.0u"ft")
    M = quiet(() -> SS._eq137_transfer_moment(
        st, st.slabs[1], col, (1.0, 0.0), qD, qL, 20.0u"ft", 19.0u"ft", M0;
        extra_columns = st.columns, index = ctx.index,
        vertex_column = ctx.vertex_column, cell_slab = ctx.cell_slab,
        partway = ctx.partway, tc = tc))
    return (M = kft(M), tc = tc)
end

east_l2(sides) = ustrip(u"ft", only(s for s in sides if s.side == 1).l2)
west_l2(sides) = ustrip(u"ft", only(s for s in sides if s.side == -1).l2)

@testset "Eq. (13-7) cycle 13 — centerline half-strip" begin
    @test hand_137(29.0, 19.0) ≈ HAND rtol = 1e-6

    @testset "(a) 1.2 ft gap over R restores the centerline ℓ2 = 20 ft" begin
        # East-bay north panel y = 20..38.8: 1.2 ft short of the y = 40 line
        # (gap > 0.35 m bridge) but the centerline y = 30 is covered.  The
        # old min(run, line) / 2 halved the slab edge (ℓ2 = 19.4, Mub =
        # 160.285, unconservative).  min(run, line / 2) caps at the
        # centerline, so the full 20 ft strip is restored (§13.6.2.1).
        r = gap_probe(1.2)
        @test r.appl.ok
        @test !any(e -> e.event_type == :failure, r.tc.events)
        @test east_l2(r.sides) ≈ 20.0 rtol = 1e-6
        @test west_l2(r.sides) ≈ 20.0 rtol = 1e-6
        @test r.M ≈ HAND rtol = 1e-4
    end

    @testset "(c) 1.0 ft gap under the bridge stays ℓ2 = 20 ft" begin
        # Gap 1.0 ft < 0.35 m: bridged, so the run reaches the y = 40 line and
        # the strip is the full 20 ft either way.  Guards against the fix
        # disturbing the already-correct sub-bridge case.
        r = gap_probe(1.0)
        @test r.appl.ok
        @test !any(e -> e.event_type == :failure, r.tc.events)
        @test east_l2(r.sides) ≈ 20.0 rtol = 1e-6
        @test r.M ≈ HAND rtol = 1e-4
    end

    @testset "(b) strip stopping before the centerline is rejected (fail closed)" begin
        # East-bay north panel y = 20..26: only 6 ft of slab, so the north
        # transverse half-strip (centerline y = 30, line / 2 = 10 ft from the
        # frame) does NOT reach the panel centerline that §13.6.2.1 requires
        # the strip be bounded by.  The strip is therefore not bounded by the
        # centerline of panel and its center-to-center ℓ2 (§13.6.2.3) is
        # undefined, so `_eq137_side_width` must FAIL CLOSED with the
        # §13.6.9.2 ambiguous-geometry ArgumentError rather than return the
        # reduced, UNCONSERVATIVE covered run (the cycle-13 P0: it used to
        # report ℓ2 = 16 ft and Mub = 116.25 < 168.056 with appl.ok and no
        # :failure).  Here Eq. (13-7) must come back NaN with a :failure trace.
        c = gap_case(14.0)
        r = transfer_only(c.st, c.col)
        @test isnan(r.M)
        fails = filter(e -> e.event_type == :failure, r.tc.events)
        @test !isempty(fails)
        @test any(e -> get(e.data, "reason", nothing) == "adjoining_spans_unresolved",
                  fails)
        # The ambiguous geometry surfaces as an ArgumentError from the sides pass.
        @test_throws ArgumentError quiet(() -> SS._eq137_resolved_sides(
            c.st, c.st.slabs[1], c.col, (1.0, 0.0); extra_columns = c.st.columns))
    end

    @testset "(d) asymmetric coverage (one half past the centerline, one short) is rejected" begin
        # East span: the NORTH transverse half covers fully past its centerline
        # (y = 40 line, run 20 ft > line / 2 = 10 ft) while the SOUTH half stops
        # at y = 14 — only a 6 ft run, short of its centerline (y = 10).  One
        # half reaching its centerline does not make the strip centerline-bounded
        # (§13.6.2.1), so the panel must still be rejected (fail closed) on the
        # short half: NaN transfer moment with an `adjoining_spans_unresolved`
        # :failure trace, never a reduced ℓ2.
        c = east_bay_case(south_lo = 14.0)
        r = transfer_only(c.st, c.col)
        @test isnan(r.M)
        @test any(e -> e.event_type == :failure &&
                       get(e.data, "reason", nothing) == "adjoining_spans_unresolved",
                  r.tc.events)
        @test_throws ArgumentError quiet(() -> SS._eq137_resolved_sides(
            c.st, c.st.slabs[1], c.col, (1.0, 0.0); extra_columns = c.st.columns))
    end

    @testset "protected oracle: 3-span interior column stays 168.056" begin
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
        cols = Any[mk(V(x, y)) for x in xs for y in ys]
        st = assemble(pts, faces, cols)
        col = cols[findfirst(c -> c.vertex_idx == V(20.0, 20.0), cols)]
        r = probe(st, col)
        @test r.M ≈ HAND rtol = 1e-4
        @test r.appl.ok
        @test !any(e -> e.event_type == :failure, r.tc.events)
    end
end
