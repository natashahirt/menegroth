# =============================================================================
# Irregular layouts: DDM → FEA fallback (pipeline and NLP entry points)
# =============================================================================
#
# ACI 318-11 §13.6.1 (corpus: aci-318-11, page 252) limits the Direct Design
# Method to regular layouts; §13.5.1 permits any analysis satisfying
# equilibrium and compatibility (the FEA shell model).  With DDM requested on
# an ineligible layout, `FlatPlateOptions(on_inapplicable = :fallback)` (the
# default) must design the slab by FEA and say so (result fields + trace);
# `on_inapplicable = :error` must raise `DDMApplicabilityError`.
#
# Layouts:
#   (a) honeycomb (Voronoi-style) plan — hexagonal slab faces, columns only at
#       interior (degree-3) vertices;
#   (b) 4×4-column, 20 ft office grid with every column randomly perturbed
#       (seeded) by up to 35% of the bay in x and y;
#   (c) the same grid unperturbed — DDM is permitted and must be used.
#
# Needs StructuralSynthesizer (BuildingStructure):
#   julia --project=StructuralSynthesizer StructuralSizer/test/slabs/test_irregular_layout_fallback.jl
# =============================================================================

using Test
using Random
using Unitful
using Meshes
using StructuralSynthesizer
using StructuralSizer
using StructuralSizer: psf, kip

const SSF = StructuralSizer

_quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
_pt(p, z) = Meshes.Point(uconvert(u"m", p[1] * u"ft"), uconvert(u"m", p[2] * u"ft"), z)

"""
    _plan_structure(nodes, edges, col_nodes; story_ft=10.0) -> BuildingStructure

One-story `BuildingStructure` whose floor plan is the planar graph
(`nodes` in ft, `edges` as node-index pairs) with columns at `col_nodes`.
Slab faces come from `find_faces!`; nodes without a column are slab outline
points only.
"""
function _plan_structure(nodes::Vector{NTuple{2, Float64}}, edges, col_nodes; story_ft = 10.0)
    skel = BuildingSkeleton{typeof(1.0u"m")}()
    push!(skel.stories_z, 0.0u"m")
    push!(skel.stories_z, uconvert(u"m", story_ft * u"ft"))
    z0, z1 = skel.stories_z
    for k in 0:1, (a, b) in edges
        z = skel.stories_z[k + 1]
        add_element!(skel, Meshes.Segment(_pt(nodes[a], z), _pt(nodes[b], z));
                     group = :beams, level_idx = k)
    end
    for i in col_nodes
        add_element!(skel, Meshes.Segment(_pt(nodes[i], z0), _pt(nodes[i], z1));
                     group = :columns, level_idx = 1)
        add_vertex!(skel, _pt(nodes[i], z0); group = :support)
        add_vertex!(skel, _pt(nodes[i], z1); group = :roof)
    end
    find_faces!(skel)
    for (level_idx, story) in skel.stories
        grp = level_idx == 0 ? :grade : :floor
        haskey(skel.groups_faces, grp) || (skel.groups_faces[grp] = Int[])
        append!(skel.groups_faces[grp], story.faces)
    end
    return BuildingStructure(skel)
end

"""Column grid `xs × ys` (ft), each node shifted by `shift(i, j)` ft; columns at every node."""
function _grid_plan(xs, ys; shift = (i, j) -> (0.0, 0.0))
    nx, ny = length(xs), length(ys)
    id(i, j) = (j - 1) * nx + i
    nodes = Vector{NTuple{2, Float64}}(undef, nx * ny)
    for i in 1:nx, j in 1:ny
        d = shift(i, j)
        nodes[id(i, j)] = (xs[i] + d[1], ys[j] + d[2])
    end
    edges = Tuple{Int, Int}[]
    for j in 1:ny, i in 1:(nx - 1); push!(edges, (id(i, j), id(i + 1, j))); end
    for i in 1:nx, j in 1:(ny - 1); push!(edges, (id(i, j), id(i, j + 1))); end
    return nodes, edges, collect(1:(nx * ny))
end

"""Honeycomb of `nx × ny` pointy-top hexagons of circumradius `R` ft; columns at degree-3 vertices."""
function _honeycomb_plan(nx, ny; R = 12.0)
    nodes = NTuple{2, Float64}[]
    ids = Dict{Tuple{Int, Int}, Int}()
    V(p) = get!(ids, (round(Int, 100p[1]), round(Int, 100p[2]))) do
        push!(nodes, p); length(nodes)
    end
    w = sqrt(3) * R
    faces = Vector{Int}[]
    for i in 0:(nx - 1), j in 0:(ny - 1)
        cx = i * w + (isodd(j) ? w / 2 : 0.0)
        cy = 1.5R * j
        push!(faces, [V((cx + R * cosd(60k + 30), cy + R * sind(60k + 30))) for k in 0:5])
    end
    edges = Set{Tuple{Int, Int}}()
    deg = zeros(Int, length(nodes))
    for f in faces, k in eachindex(f)
        a, b = f[k], f[mod1(k + 1, length(f))]
        push!(edges, minmax(a, b))
    end
    for (a, b) in edges; deg[a] += 1; deg[b] += 1; end
    return nodes, collect(edges), [v for v in eachindex(nodes) if deg[v] >= 3]
end

const _BAYS_FT = [0.0, 20.0, 40.0, 60.0]

_regular_layout() = _grid_plan(_BAYS_FT, _BAYS_FT)

function _perturbed_layout()
    rng = MersenneTwister(7)
    amp = 0.35 * 20.0
    d = Dict((i, j) => (amp * (2rand(rng) - 1), amp * (2rand(rng) - 1))
             for i in eachindex(_BAYS_FT), j in eachindex(_BAYS_FT))
    return _grid_plan(_BAYS_FT, _BAYS_FT; shift = (i, j) -> d[(i, j)])
end

# FEA audit finding: at R = 10 ft the 3×2 honeycomb does not converge within
# max_iterations = 10 (punching_shear, h = 8 in) but does at 12 iterations
# (columns ≤ 22 in, below the 30 in cap): short of iterations, not stuck.
_honeycomb_layout() = _honeycomb_plan(3, 2; R = 12.0)

"""
Fresh, initialized structure for `layout` with DDM requested.  Service loads
SDL = 30 psf, L = 50 psf (L/D within §13.6.1.5 even before self-weight), so
only the geometry decides DDM applicability.  Returns `(struc, slab, opts)`.
"""
function _fresh(layout; on_inapplicable = :fallback)
    struc = _plan_structure(layout()...)
    opts = FlatPlateOptions(material = RC_4000_60, method = DDM(), cover = 0.75u"inch",
                            bar_size = 5, shear_studs = :always,
                            on_inapplicable = on_inapplicable)
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 30.0psf)
        cell.live_load = uconvert(u"kN/m^2", 50.0psf)
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    to_asap!(struc)
    return struc, first(struc.slabs), opts
end

_slab_columns(struc, slab) = SSF.find_supporting_columns(struc, Set(slab.cell_indices))

_fallback_events(tc) = [e for e in tc.events
                        if e.stage == "resolve_analysis_method" && e.event_type == :fallback]

const _EQ137_UNRESOLVED = ("adjoining_spans_unresolved", "near_faces_unresolved")
_eq137_failures(tc) = [e for e in tc.events
                       if e.event_type == :failure &&
                          (startswith(e.stage, "_eq137") ||
                           get(e.data, "reason", "") in _EQ137_UNRESOLVED)]

"""Every supporting column carries a finite punching check (demand stress, ratio, Mub)."""
function _test_complete_punching(design, n_cols)
    details = design.slab_result.punching_check.details
    @test length(details) == n_cols
    for pr in values(details)
        @test isfinite(ustrip(u"psi", pr.vu))
        @test isfinite(pr.ratio)
        if hasproperty(pr, :Mub)
            @test isfinite(ustrip(kip * u"ft", pr.Mub))
        end
    end
end

"""Fallback record on a pipeline / optimizer result."""
function _test_fallback_record(res)
    @test res.method_requested isa DDM
    @test res.method_used isa FEA
    @test !isempty(res.method_fallback_reasons)
    @test any(occursin("§13.6.1", r) for r in res.method_fallback_reasons)
end

"""Fallback trace: one `resolve_analysis_method` `:fallback` event, DDM → FEA."""
function _test_fallback_trace(tc, res)
    evs = _fallback_events(tc)
    @test length(evs) == 1
    if !isempty(evs)
        ev = first(evs)
        @test ev.data["reason"] == "method_not_applicable"
        @test ev.data["method_requested"] == SSF.method_name(DDM())
        @test ev.data["method_used"] == SSF.method_name(FEA())
        @test ev.data["violations"] == res.method_fallback_reasons
    end
    @test isempty(_eq137_failures(tc))
end

"""
`check_ddm_applicability` on a light mock (no `BuildingStructure`, no FEA):
a slab meshed on the grid lines `xs × xs` (ft; triangles when `tri`) with
12 in columns at the 20 ft column grid 0:20:60 in both directions.
SDL = 100 psf, L = 50 psf.
"""
function _mock_grid_check(xs; tri = false)
    pts = NTuple{2, Float64}[]
    ids = Dict{NTuple{2, Float64}, Int}()
    V(x, y) = get!(ids, (x, y)) do
        push!(pts, (x, y)); length(pts)
    end
    faces = Vector{Int}[]
    for i in 1:(length(xs) - 1), j in 1:(length(xs) - 1)
        a, b = V(xs[i], xs[j]), V(xs[i + 1], xs[j])
        c, d = V(xs[i + 1], xs[j + 1]), V(xs[i], xs[j + 1])
        tri ? append!(faces, ([a, b, c], [a, c, d])) : push!(faces, [a, b, c, d])
    end
    col_vs = [V(x, y) for x in 0.0:20.0:60.0 for y in 0.0:20.0:60.0]
    vc = [p[k] * 0.3048 for p in pts, k in 1:2]
    cells = Any[(face_idx = k, sdl = 100.0psf, live_load = 50.0psf, self_weight = 0.0psf)
                for k in eachindex(faces)]
    cols = Any[(vertex_idx = v, position = :interior, c1 = 12.0u"inch", c2 = 12.0u"inch",
                θ = 0.0, structural_offset = (0.0, 0.0)) for v in col_vs]
    slab = (cell_indices = collect(eachindex(faces)),
            spans = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0)))
    struc = (cells = cells, slabs = Any[slab], columns = cols,
             skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    return _quiet(() -> SSF.check_ddm_applicability(struc, slab, cols; throw_on_failure = false))
end

function _test_ineligible_layout(layout)
    # (1) The layout violates ACI 318-11 §13.6.1.
    struc, slab, opts = _fresh(layout)
    cols = _slab_columns(struc, slab)
    @test length(cols) >= 4
    chk = _quiet(() -> SSF.check_ddm_applicability(struc, slab, cols; throw_on_failure = false))
    @test !chk.ok
    @test any(occursin("§13.6.1", v) for v in chk.violations)

    # (2) Pipeline, default :fallback → complete FEA design + notice.
    tc = TraceCollector()
    res = _quiet(() -> SSF.size_flat_plate!(struc, slab, ConcreteColumnOptions();
                                        method = DDM(), opts = opts, max_iterations = 20, tc = tc))
    _test_fallback_record(res)
    _test_fallback_trace(tc, res)
    @test res.converged
    if res.converged
        @test isfinite(ustrip(u"inch", res.h_final)) && res.h_final > 0u"inch"
        _test_complete_punching(res, length(cols))
    end

    # (2') NLP optimizer, default :fallback → FEA pipeline hand-off.
    struc, slab, opts = _fresh(layout)
    cols = _slab_columns(struc, slab)
    tc = TraceCollector()
    opt = _quiet(() -> SSF.size_flat_plate_optimized(struc, slab, opts; n_grid = 4, n_refine = 0,
                                                     max_iterations = 20, tc = tc))
    _test_fallback_record(opt)
    _test_fallback_trace(tc, opt)
    @test opt.status == :fea_fallback
    @test opt.fea_design !== nothing
    if opt.status == :fea_fallback
        @test isfinite(ustrip(u"inch", opt.h)) && opt.h > 0u"inch"
        @test isfinite(ustrip(u"inch", opt.c))
        @test opt.fea_design.method_used isa FEA
        _test_complete_punching(opt.fea_design, length(cols))
    end
    @test any(e -> e.stage == "size_flat_plate_optimized" && e.event_type == :decision &&
                   get(e.data, "outcome", "") == "fea_fallback", tc.events)

    # (3) on_inapplicable = :error raises on both entry points, with a :failure trace.
    struc, slab, opts = _fresh(layout; on_inapplicable = :error)
    tc = TraceCollector()
    @test_throws SSF.DDMApplicabilityError _quiet(() -> SSF.size_flat_plate!(
        struc, slab, ConcreteColumnOptions(); method = DDM(), opts = opts, tc = tc))
    @test any(e -> e.stage == "resolve_analysis_method" && e.event_type == :failure, tc.events)
    @test isempty(_fallback_events(tc))
    tc = TraceCollector()
    @test_throws SSF.DDMApplicabilityError _quiet(() -> SSF.size_flat_plate_optimized(
        struc, slab, opts; n_grid = 4, n_refine = 0, tc = tc))
    @test any(e -> e.stage == "resolve_analysis_method" && e.event_type == :failure, tc.events)
end

@testset "Irregular layout → FEA fallback" begin
    @testset "Option validation" begin
        @test FlatPlateOptions().on_inapplicable === :fallback
        @test FlatPlateOptions(on_inapplicable = :error).on_inapplicable === :error
        @test_throws ArgumentError FlatPlateOptions(on_inapplicable = :ignore)
    end

    @testset "§13.6.1.2 / §13.6.1.3 are mesh- and overhang-independent (no FEA)" begin
        quad = _mock_grid_check([0.0, 20.0, 40.0, 60.0])
        @test quad.ok
        # F6a: a triangulated or sub-divided regular grid is judged on its
        # column-bounded panels, as the quad mesh is.
        for chk in (_mock_grid_check([0.0, 20.0, 40.0, 60.0]; tri = true),
                    _mock_grid_check([0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0]))
            @test chk.ok == quad.ok
            @test !any(occursin("is not rectangular", v) for v in chk.violations)
        end
        # F6b: a 1 ft slab overhang beyond the edge columns has no far column,
        # so it is not a §13.6.1.3 span.
        ov = _mock_grid_check([-1.0, 0.0, 20.0, 40.0, 60.0, 61.0])
        @test !any(occursin("§13.6.1.3", v) for v in ov.violations)
    end

    @testset "Honeycomb (Voronoi-style) plan" begin
        _test_ineligible_layout(_honeycomb_layout)
    end

    @testset "Randomly perturbed office grid (±35% bay, seed 7)" begin
        _test_ineligible_layout(_perturbed_layout)
    end

    @testset "Regular grid keeps DDM" begin
        struc, slab, opts = _fresh(_regular_layout)
        cols = _slab_columns(struc, slab)
        chk = _quiet(() -> SSF.check_ddm_applicability(struc, slab, cols; throw_on_failure = false))
        @test chk.ok

        tc = TraceCollector()
        res = _quiet(() -> SSF.size_flat_plate!(struc, slab, ConcreteColumnOptions();
                                            method = DDM(), opts = opts, max_iterations = 20, tc = tc))
        @test res.method_requested isa DDM
        @test res.method_used isa DDM
        @test isempty(res.method_fallback_reasons)
        @test isempty(_fallback_events(tc))

        struc, slab, opts = _fresh(_regular_layout)
        tc = TraceCollector()
        opt = _quiet(() -> SSF.size_flat_plate_optimized(struc, slab, opts; n_grid = 4, n_refine = 0, tc = tc))
        @test opt.method_used isa DDM
        @test isempty(opt.method_fallback_reasons)
        @test opt.fea_design === nothing
        @test opt.status != :fea_fallback
        @test isempty(_fallback_events(tc))
    end
end
