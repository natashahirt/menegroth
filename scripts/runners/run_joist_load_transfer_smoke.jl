# Joist → girder load-transfer smoke — defect #1/#2.
#
# Verifies that when a slab has auto-generated framing (materialized joists),
# `to_asap!` routes the slab's gravity pressure onto the JOIST elements
# (tributary strips) instead of smearing the whole cell tributary onto the
# perimeter girders. The elastic frame solve then produces the girder
# demand envelope from the concentrated joist end-reactions (#2), and the
# continuous-beam reaction distribution over the girder's multiple joist
# landings (#1) — both emerge from the FEM solve, not from a hand rule.
#
# Fixture: a single 8 × 6 m two-way bay, span axis (1, 0), four perimeter
# girders (level 0) + four columns to ground (4 corner supports), populated
# with one level of steel joists at 2 m spacing. A UNITFUL slab result is
# used (CIPSlabResult with u"m" thickness) so the shell diaphragm geometry
# that the joist-aware routing reuses builds cleanly (bare-float slabs fall
# back to the per-cell path — see `_create_framed_slab_loads!`).
#
# Testsets:
#   (a) Joists carry the slab: joist elements receive TributaryLoads and
#       carry the MAJORITY of the applied gravity load.
#   (b) Girders develop demand from joist transfer: member_group_demands
#       gives nonzero girder Mu/Vu, and the supporting (joist-landing)
#       girders carry ~zero DIRECT tributary yet a large solved shear —
#       i.e. their demand comes from the joist reactions, not direct load.
#   (c) Unframed slab is unchanged: an identical bay WITHOUT joists is not
#       touched by the joist-aware path (0 cells handled) and its total
#       applied load is identical to the framed bay.
#   (d) No double counting: the framed bay's total applied gravity force
#       equals slab pressure × panel area (within tolerance).
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_joist_load_transfer_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SS = StructuralSynthesizer
const SZ = StructuralSizer

const LX = 8.0
const LY = 6.0
const HZ = 3.5
const PANEL_AREA_M2 = LX * LY        # 48 m²
const SPACING = 2.0

"""Build a single-story 8×6 m two-way bay: four perimeter girders (level 0) +
four columns to ground, corners supported. `with_joists` toggles the level-1
joist auto-generation. Returns `struc`."""
function build_bay(; with_joists::Bool)
    skel = BuildingSkeleton{Float64}()
    g1 = add_vertex!(skel, [0.0, 0.0, 0.0])
    g2 = add_vertex!(skel, [LX,  0.0, 0.0])
    g3 = add_vertex!(skel, [LX,  LY,  0.0])
    g4 = add_vertex!(skel, [0.0, LY,  0.0])
    s1 = add_vertex!(skel, [0.0, 0.0, HZ])
    s2 = add_vertex!(skel, [LX,  0.0, HZ])
    s3 = add_vertex!(skel, [LX,  LY,  HZ])
    s4 = add_vertex!(skel, [0.0, LY,  HZ])
    add_element!(skel, g1, s1; group = :columns)
    add_element!(skel, g2, s2; group = :columns)
    add_element!(skel, g3, s3; group = :columns)
    add_element!(skel, g4, s4; group = :columns)
    add_element!(skel, s1, s2; group = :beams)
    add_element!(skel, s2, s3; group = :beams)
    add_element!(skel, s3, s4; group = :beams)
    add_element!(skel, s4, s1; group = :beams)
    supports = get!(skel.groups_vertices, :support, Int[])
    append!(supports, (g1, g2, g3, g4))
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    A = PANEL_AREA_M2 * u"m^2"
    spans = SpanInfo{Float64}(LX, LY, (1.0, 0.0), 7.0)
    corners = (s1, s2, s3, s4)
    fidx = findfirst(vs -> Set(vs) == Set(corners), skel.face_vertex_indices)
    fidx === nothing && error("story-1 face not found")
    cell = Cell(fidx, A, spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    # Unitful slab result ⇒ diaphragm shell geometry builds (mirrors production
    # sizing output, and the Phase-7 shell fixture).
    push!(struc.slabs, Slab{Float64}([1],
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))

    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    for e in sort(collect(skel.groups_edges[:columns]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.columns, Column([length(struc.segments)], L))
    end

    if with_joists
        opts = (materials = (steel = A992_Steel,), spacing = SPACING)
        populate_levels!(struc; opts = opts)
    end
    return struc
end

# L-shaped (non-convex) bay: proves the convexity gate makes joist-framed slabs
# fall back to the load-conserving per-cell path (no gravity dropped on L/T/U).
const L_AREA_M2 = 48.0        # 3 cells × 16 m² (bottom bar x 0–8, y 0–4 + left riser x 0–4, y 4–8)

"""Build a 3-cell L-shaped (non-convex) slab: bottom bar (x 0–8, y 0–4) plus a
left riser (x 0–4, y 4–8). Level-0 perimeter + interior girders, and a column to
ground under EVERY story vertex (all supported at the base — so the frame solves
regardless of joist releases). `with_joists` toggles level-1 joist generation."""
function build_L_bay(; with_joists::Bool)
    skel = BuildingSkeleton{Float64}()
    z = HZ
    coord2v = Dict{Tuple{Float64, Float64}, Int}()
    story_v(x, y) = get!(() -> add_vertex!(skel, [x, y, z]), coord2v, (x, y))
    seen = Set{Tuple{Int, Int}}()
    function cell_edges!(corners)
        vis = [story_v(x, y) for (x, y) in corners]
        n = length(vis)
        for i in 1:n
            a, b = vis[i], vis[mod1(i + 1, n)]
            key = minmax(a, b)
            if !(key in seen)
                add_element!(skel, a, b; group = :beams)
                push!(seen, key)
            end
        end
        return vis
    end
    cells = [
        [(0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)],   # bottom-left
        [(4.0, 0.0), (8.0, 0.0), (8.0, 4.0), (4.0, 4.0)],   # bottom-right
        [(0.0, 4.0), (4.0, 4.0), (4.0, 8.0), (0.0, 8.0)],   # top-left riser
    ]
    cell_vis = [cell_edges!(c) for c in cells]

    support = get!(skel.groups_vertices, :support, Int[])
    for ((x, y), sv) in coord2v
        gv = add_vertex!(skel, [x, y, 0.0])
        add_element!(skel, gv, sv; group = :columns)
        push!(support, gv)
    end
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(8.0, 8.0, (1.0, 0.0), 8.0)
    cidxs = Int[]
    for vis in cell_vis
        fidx = findfirst(vs -> Set(vs) == Set(vis), skel.face_vertex_indices)
        fidx === nothing && error("L-cell face not found for $vis")
        cell = Cell(fidx, 16.0u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
        cell.floor_type = :two_way
        push!(struc.cells, cell)
        push!(cidxs, length(struc.cells))
    end
    push!(struc.slabs, Slab{Float64}(cidxs,
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))

    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    for e in sort(collect(skel.groups_edges[:columns]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.columns, Column([length(struc.segments)], L))
    end

    if with_joists
        opts = (materials = (steel = A992_Steel,), spacing = SPACING)
        populate_levels!(struc; opts = opts)
    end
    return struc
end

# ── Convex non-rectangular fixtures (P0 conservation regression) ─────────────
# The one-way midpoint-rule strips are per-member exact ONLY for a true RECTANGLE
# aligned to the joist frame, where the uniform (constant-intensity) strip pins the
# joist resultant to mid-span ⇒ correct joist moment AND a correct 50/50 girder
# end-reaction split. Correctness is enforced by the AUTHORITATIVE
# rectangle-alignment gate (interior area == joist-frame bounding-box area); the
# CONVEXITY, CONSTANT-MEMBER-LENGTH, TOTAL-AREA-MATCH and per-band checks are only
# early-outs / defense-in-depth behind it. Convexity alone is NOT enough: it admits
# trapezoids/triangles/diamonds/hexagons/parallelograms whose strips drop, inflate,
# or mis-split load. Every convex non-rectangle below must fall back to the
# load-conserving per-cell path, keeping Σ(applied) ≈ p·A. (The non-convex decagon
# in testset (g) and the sheared parallelogram in testset (i) exercise the
# complementary cases the length + area gates alone would miss.)

"""Absolute shoelace area (m²) of a simple polygon given as ordered (x, y) m
pairs."""
function poly_area_m2(corners::Vector{NTuple{2, Float64}})
    n = length(corners)
    a2 = 0.0
    for i in 1:n
        x1, y1 = corners[i]
        x2, y2 = corners[mod1(i + 1, n)]
        a2 += x1 * y2 - x2 * y1
    end
    return abs(a2) / 2
end

"""Build a single-cell convex-polygon bay from CCW `corners` (m): a story vertex +
ground column (support) at every corner, perimeter girders around the loop, and
one auto-generated joist level at `SPACING`. `span_axis` sets the one-way joist
orientation. Mirrors `build_bay` for a general polygon."""
function build_poly_bay(corners::Vector{NTuple{2, Float64}}; span_axis::NTuple{2, Float64})
    skel = BuildingSkeleton{Float64}()
    n = length(corners)
    gnd = [add_vertex!(skel, [x, y, 0.0]) for (x, y) in corners]
    sto = [add_vertex!(skel, [x, y, HZ])  for (x, y) in corners]
    for i in 1:n
        add_element!(skel, gnd[i], sto[i]; group = :columns)
    end
    for i in 1:n
        add_element!(skel, sto[i], sto[mod1(i + 1, n)]; group = :beams)
    end
    supports = get!(skel.groups_vertices, :support, Int[])
    append!(supports, gnd)
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    xs = [c[1] for c in corners]; ys = [c[2] for c in corners]
    prim = maximum(xs) - minimum(xs); sec = maximum(ys) - minimum(ys)
    spans = SpanInfo{Float64}(prim, sec, span_axis, min(prim, sec))
    fidx = findfirst(vs -> Set(vs) == Set(sto), skel.face_vertex_indices)
    fidx === nothing && error("poly face not found")
    cell = Cell(fidx, poly_area_m2(corners) * u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab{Float64}([1],
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))

    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    for e in sort(collect(skel.groups_edges[:columns]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.columns, Column([length(struc.segments)], L))
    end

    populate_levels!(struc; opts = (materials = (steel = A992_Steel,), spacing = SPACING))
    return struc
end

# ── Non-convex compensating-bulge decagon (critic's P0 counter-example) ───────
# CCW corners. This shape defeats the CONSTANT-LENGTH + TOTAL-AREA gates JOINTLY:
# span axis (1,0), spacing 2 ⇒ one joist at x=4 + two joist-parallel edge girders
# at x=2,x=6, ALL length 6, and Σ width·length = 24 = the true shoelace area
# EXACTLY (ratio 1.0). Yet the bulges dip the span-direction extent below L in one
# band and above it in another (true bands 7.0 m² at x=2 vs applied 6 ⇒ −14 %
# UNDER, and 5.0 m² at x=6 vs applied 6 ⇒ +20 % over) — an unsafe edge-girder
# under-size. ONLY the convexity gate rejects it.
const DECAGON_CORNERS = NTuple{2, Float64}[(2.0, 0.0), (3.0, -1.0), (4.0, 0.0),
    (5.0, 1.0), (6.0, 0.0), (6.0, 6.0), (5.0, 5.0), (4.0, 6.0), (3.0, 7.0), (2.0, 6.0)]

"""Build the compensating-bulge decagon as a slab of TWO CONVEX cells sharing the
interior edge (5,1)-(5,5). The SLAB union boundary is the non-convex decagon (so
the convexity gate declines the strip routing — the P0 fix), while each cell face
is convex so the per-cell fallback conserves total load. This mirrors how the real
pipeline represents non-convex bays (multiple convex faces, cf. `build_L_bay`),
never a single non-convex face (whose two-way tributary orphans reflex regions and
under-conserves). Column to ground + support under every story vertex."""
function build_decagon_bay(; with_joists::Bool)
    skel = BuildingSkeleton{Float64}()
    z = HZ
    coord2v = Dict{Tuple{Float64, Float64}, Int}()
    story_v(x, y) = get!(() -> add_vertex!(skel, [x, y, z]), coord2v, (x, y))
    seen = Set{Tuple{Int, Int}}()
    function cell_edges!(corners)
        vis = [story_v(x, y) for (x, y) in corners]
        n = length(vis)
        for i in 1:n
            a, b = vis[i], vis[mod1(i + 1, n)]
            key = minmax(a, b)
            if !(key in seen)
                add_element!(skel, a, b; group = :beams)
                push!(seen, key)
            end
        end
        return vis
    end
    # Split at the interior diagonal (5,1)-(5,5): a convex 8-gon (left) + a convex
    # quad (right). Their union is `DECAGON_CORNERS`.
    cells = [
        [(2.0, 0.0), (3.0, -1.0), (4.0, 0.0), (5.0, 1.0),
         (5.0, 5.0), (4.0, 6.0), (3.0, 7.0), (2.0, 6.0)],
        [(5.0, 1.0), (6.0, 0.0), (6.0, 6.0), (5.0, 5.0)],
    ]
    cell_vis = [cell_edges!(c) for c in cells]

    support = get!(skel.groups_vertices, :support, Int[])
    for ((x, y), sv) in coord2v
        gv = add_vertex!(skel, [x, y, 0.0])
        add_element!(skel, gv, sv; group = :columns)
        push!(support, gv)
    end
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(4.0, 8.0, (1.0, 0.0), 4.0)
    cidxs = Int[]
    for (vis, c) in zip(cell_vis, cells)
        fidx = findfirst(vs -> Set(vs) == Set(vis), skel.face_vertex_indices)
        fidx === nothing && error("decagon cell face not found for $c")
        cell = Cell(fidx, poly_area_m2(c) * u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
        cell.floor_type = :two_way
        push!(struc.cells, cell)
        push!(cidxs, length(struc.cells))
    end
    push!(struc.slabs, Slab{Float64}(cidxs,
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))

    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    for e in sort(collect(skel.groups_edges[:columns]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.columns, Column([length(struc.segments)], L))
    end

    if with_joists
        populate_levels!(struc; opts = (materials = (steel = A992_Steel,), spacing = SPACING))
    end
    return struc
end

# ── Convex KITE (critic's 5th counter-example) ───────────────────────────────
# CCW corners. This shape defeats the CONVEXITY + CONSTANT-LENGTH + TOTAL-AREA
# gates JOINTLY: span axis (1,0) ⇒ joists at y=−1 and y=+3, BOTH length 4, and
# Σ width·length = 3·4 + 5·4 = 32 = the true shoelace area EXACTLY (ratio 1.0).
# Yet the true per-band tributary areas (≈15.33 m² for the y=−1 band vs applied
# 12, and ≈16.67 m² for the y=+3 band vs applied 20) disagree with the applied
# strip areas by ~22 % — a gross per-member mis-distribution. ONLY the DIRECT
# per-band per-member tributary-area gate rejects it; all three early-outs pass.
const KITE_CORNERS = NTuple{2, Float64}[(4.0, 0.0), (0.0, 6.0), (-4.0, 0.0), (0.0, -2.0)]

# ── Sheared (routed) parallelogram (critic's 6th counter-example) ─────────────
# CCW corners of a parallelogram: bottom side along (8,0), slanted sides along
# (8,6). Joist span axis t̂ = (6,−8)/10 = (0.6,−0.8) runs PARALLEL to the slanted
# sides, so the joists are constant length and every band chord parallel to a side
# equals that side — the shape passes CONVEXITY + CONSTANT-LENGTH + TOTAL-AREA +
# per-band AREA. Yet it is NOT a rectangle (adjacent sides (8,0)·(8,6)=64 ≠ 0), so
# each band is SHEARED relative to its member: the true tributary centroid is off
# mid-span while the uniform strip pins the resultant to mid-span, mis-splitting the
# landing-girder point loads ~8–15 %. Its joist-frame bounding box is
# n_extent·t_extent = 16.4·4.8 = 78.72 m² ≠ the true area 48 m², so ONLY the
# authoritative rectangle-alignment gate rejects it — every cheaper gate passes.
const PARALLELOGRAM_CORNERS = NTuple{2, Float64}[(0.0, 0.0), (8.0, 0.0), (16.0, 6.0), (8.0, 6.0)]

"""Total downward force (N) of a `TributaryLoad`: p·L·∫₀¹ w(t) dt (trapezoid
over the normalized breakpoints × pre-stripped widths, times element length)."""
function tributary_force_N(ld::Asap.TributaryLoad)
    L = ld.element.length
    Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
    p = ld.positions
    w = ld._widths_m
    integ = 0.0
    for i in 1:(length(p) - 1)
        integ += 0.5 * (w[i] + w[i + 1]) * (p[i + 1] - p[i])
    end
    return ld._pressure_Pa * Lm * integ
end

"""Map each Asap element to its skeleton edge index (elements are built one per
edge, in edge order, and `member_group_demands` indexes them as
`model.elements[edge_idx]`)."""
function edge_of_element_map(model)
    m = IdDict{Any, Int}()
    for e in eachindex(model.elements)
        m[model.elements[e]] = e
    end
    return m
end

"""Map each level-0/level-≥1 beam edge to its member role (`:girder`, `:joist`, …)."""
function edge_role_map(struc)
    roles = Dict{Int, Symbol}()
    for b in struc.beams
        for si in SS.segment_indices(b)
            roles[struc.segments[si].edge_idx] = b.role
        end
    end
    return roles
end

"""Strip a (possibly unitful) demand scalar to its bare magnitude."""
_mag(x) = x isa Unitful.Quantity ? abs(ustrip(x)) : abs(Float64(x))

"""Max internal shear (N) and bending moment (N·m) over all segments of `beam`,
from the solved model. Takes the max over BOTH local transverse axes so the
result is independent of the element's local-axis orientation (in Asap's
convention `My` is conjugate to `Vy` and `Mz` to `Vz`, per
`ElementForceAndDisplacement`)."""
function beam_shear_moment(struc, beam, element_loads; resolution = 200)
    Vmax = 0.0; Mmax = 0.0
    for si in SS.segment_indices(beam)
        e = struc.segments[si].edge_idx
        el = struc.asap_model.elements[e]
        ell = element_loads[el.elementID]
        fd = Asap.ElementForceAndDisplacement(el, ell; resolution = resolution)
        f = fd.forces
        Vmax = max(Vmax, maximum(abs, f.Vy), maximum(abs, f.Vz))
        Mmax = max(Mmax, maximum(abs, f.My), maximum(abs, f.Mz))
    end
    return (V = Vmax, M = Mmax)
end

"""End transverse-shear reactions `(R1, R2)` (N) a joist delivers to its two
landing girders: the shear magnitude at the far ends of the joist's segment chain
(start node of its first segment, end node of its last segment), read from the
solved element LCS end-force vector `element.forces`
(`[Fx1,Fy1,Fz1,Mx1,My1,Mz1, Fx2,Fy2,Fz2,Mx2,My2,Mz2]`, SI N / N·m — populated by
`Asap.solve!` for every element type, including the `Element{Asap.Joist}` type that
`ElementForceAndDisplacement` cannot interpolate). Taken as `hypot(Fy, Fz)` so the
result is independent of the element's local transverse-axis orientation. For a
UNIFORM strip load on a joist-frame-aligned RECTANGLE these split 50/50
(`R1 ≈ R2`) by symmetry — the mid-span resultant of a constant intensity — which is
exactly the per-member-correct split the routed strip must reproduce."""
function joist_end_reactions(struc, beam)
    sis = collect(SS.segment_indices(beam))
    function end_reaction(si, at_start::Bool)
        e = struc.segments[si].edge_idx
        f = struc.asap_model.elements[e].forces   # LCS end forces (SI, N/N·m)
        return at_start ? hypot(f[2], f[3]) : hypot(f[8], f[9])
    end
    return (end_reaction(first(sis), true), end_reaction(last(sis), false))
end

"""Total downward force (N) of all TributaryLoads currently on the model."""
function total_tributary_force_N(model)
    total = 0.0
    for ld in model.loads
        ld isa Asap.TributaryLoad || continue
        total += tributary_force_N(ld)
    end
    return total
end

@testset "Joist → girder load transfer (defect #1/#2)" begin
    params = DesignParameters(materials =
        MaterialOptions(steel = A992_Steel, beam = A992_Steel))

    # ── Framed bay ──────────────────────────────────────────────────────────
    struc = build_bay(with_joists = true)
    joists = [b for b in struc.beams if SS.level_of(b) == 1]
    @test !isempty(joists)
    @test all(b -> b.role === :joist, joists)

    # Default routing (:auto → :cell_tributary with no diaphragm shells) exercises
    # the joist-aware framed-slab path inside to_asap!.
    to_asap!(struc; params = params, diaphragms = :none)
    model = struc.asap_model
    e_of_el = edge_of_element_map(model)
    roles = edge_role_map(struc)
    element_loads = Asap.get_elemental_loads(model)

    # Partition the applied tributary force by the ROLE of the element it sits on.
    F_total = 0.0; F_joist = 0.0; F_girder = 0.0
    F_on_edge = Dict{Int, Float64}()
    for ld in model.loads
        ld isa Asap.TributaryLoad || continue
        f = tributary_force_N(ld)
        F_total += f
        e = get(e_of_el, ld.element, 0)
        F_on_edge[e] = get(F_on_edge, e, 0.0) + f
        r = get(roles, e, :missing)
        r === :joist  && (F_joist  += f)
        r === :girder && (F_girder += f)
    end

    @testset "(a) joists carry the slab load" begin
        # At least one TributaryLoad sits on a joist element.
        joist_edges = Set(struc.segments[si].edge_idx
                          for b in joists for si in SS.segment_indices(b))
        @test any(ld -> ld isa Asap.TributaryLoad &&
                        get(e_of_el, ld.element, 0) in joist_edges, model.loads)
        @test F_joist > 0
        # The joists carry the MAJORITY of the applied gravity load — the slab
        # pressure is routed onto the joists, not smeared onto the girders.
        @test F_joist > 0.5 * F_total
        @test F_joist > F_girder
    end

    # Girder moment demand from the solved model (the production sizing path).
    gids, demands, = member_group_demands(struc; member_edge_group = :beams, params = params)
    @test !isempty(demands)
    Mux_max = maximum(_mag(d.Mux) for d in demands)

    # Supporting girders = the perimeter (level-0) beams the joists LANDED on —
    # they were subdivided into multi-segment chains by the landings.
    supporting = [b for b in struc.beams
                  if SS.level_of(b) == 0 && length(SS.segment_indices(b)) > 1]

    @testset "(b) girder demand is attributable to joist transfer" begin
        # Girders develop a nonzero strong-axis moment envelope from the solve.
        @test Mux_max > 0
        @test !isempty(supporting)
        # Each supporting girder carries EXACTLY zero direct tributary (one-way
        # strips go to the joists and the joist-parallel edge girders, never to
        # the girders the joists land on) yet develops a large solved shear AND
        # moment — those come entirely from the joist end-reactions delivered
        # through the frame solve, which is precisely defect #1/#2.
        for gb in supporting
            F_direct = sum(get(F_on_edge, struc.segments[si].edge_idx, 0.0)
                           for si in SS.segment_indices(gb))
            sm = beam_shear_moment(struc, gb, element_loads)
            @test F_direct < 0.05 * F_total            # negligible direct load
            @test sm.V > 1.0e3                          # but a real shear (N)
            @test sm.M > 1.0e3                          # and a real moment (N·m)
        end
    end

    # ── Unframed control bay (identical, no joists) ─────────────────────────
    struc_u = build_bay(with_joists = false)
    @test isempty([b for b in struc_u.beams if SS.level_of(b) == 1])
    @test !SS._slab_has_joist_framing(struc_u, struc_u.slabs[1])

    # The joist-aware path must NOT touch a slab without materialized joists.
    handled = SS._create_framed_slab_loads!(Asap.AbstractLoad[],
        Asap.Element[], struc_u, params;
        use_patterns = false, combo = SS.governing_combo(params))
    @test isempty(handled)

    to_asap!(struc_u; params = params, diaphragms = :none)
    F_total_unframed = total_tributary_force_N(struc_u.asap_model)

    @testset "(c) unframed slab is unchanged" begin
        # No joist elements exist, so no TributaryLoad can sit on one.
        roles_u = edge_role_map(struc_u)
        e_of_el_u = edge_of_element_map(struc_u.asap_model)
        @test !any(ld -> ld isa Asap.TributaryLoad &&
                         get(roles_u, get(e_of_el_u, ld.element, 0), :missing) === :joist,
                   struc_u.asap_model.loads)
        # Same panel, same pressure ⇒ identical total applied load as the framed
        # bay (routing changes WHERE the load lands, never HOW MUCH).
        @test isapprox(F_total_unframed, F_total; rtol = 1e-6)
    end

    @testset "(d) no double counting" begin
        # Total applied gravity force = envelope pressure × panel area. A framed
        # slab whose pressure was (incorrectly) applied to BOTH the joists and the
        # full cell tributary on the girders would read ≈ 2× this.
        cell = struc.cells[1]
        p_env = StructuralSizer.envelope_pressure(params.load_combinations,
                    cell.sdl + cell.self_weight, cell.live_load)
        p_Pa = ustrip(u"Pa", uconvert(u"Pa", p_env))
        expected_N = p_Pa * PANEL_AREA_M2
        @test isapprox(F_total, expected_N; rtol = 1e-3)
    end

    # ── Non-convex (L-shaped) bay: convexity-gate fallback conserves load ────
    @testset "(e) non-convex bay falls back and conserves load" begin
        struc_L = build_L_bay(with_joists = true)
        slab_L = struc_L.slabs[1]

        # Joists ARE materialized (so the framed-slab path is entered)…
        @test SS._slab_has_joist_framing(struc_L, slab_L)
        @test !isempty([b for b in struc_L.beams if SS.level_of(b) == 1])

        # …but the TRUE boundary is non-convex, so the one-way strip routing must
        # DECLINE (return nothing) and defer to the per-cell tributary path — the
        # P0 fix. Applying the midpoint-rule strips over each member's full length
        # on an L/T/U plate would silently drop gravity load (Σ width·L ≠ area).
        poly_L = SS._slab_interior_polygon_m(struc_L, slab_L)
        @test poly_L !== nothing
        @test Asap.is_convex_polygon(poly_L) == false
        @test SS._framed_slab_strip_geometry(struc_L, slab_L) === nothing

        to_asap!(struc_L; params = params, diaphragms = :none)
        F_total_L = total_tributary_force_N(struc_L.asap_model)

        # Total applied gravity force = envelope pressure × TRUE slab area (all
        # three cells share sdl/self-weight/live, so any cell gives the pressure).
        cellL = struc_L.cells[1]
        p_env_L = StructuralSizer.envelope_pressure(params.load_combinations,
                      cellL.sdl + cellL.self_weight, cellL.live_load)
        p_Pa_L = ustrip(u"Pa", uconvert(u"Pa", p_env_L))
        expected_L = p_Pa_L * L_AREA_M2
        @test isapprox(F_total_L, expected_L; rtol = 1e-3)

        # P2-c: PER-MEMBER conservation (not just total). The docstring claims the
        # per-cell fallback conserves BOTH total AND per-member distribution. Verify
        # per member: the true per-cell tributary band of each skeleton edge is
        # p × Σ(cached edge-tributary area) over the slab's cells; the applied
        # gravity force on that edge must match within rtol — no member silently
        # starved or double-loaded. (Both the expected band and the emitted load
        # key on the global skeleton-edge index = Asap element index, so the check
        # is exact up to the width-profile discretization.)
        exp_area = Dict{Int, Float64}()
        for ci in slab_L.cell_indices
            tribs = SS.cell_edge_tributaries(struc_L, ci)
            tribs === nothing && continue
            face_edges = struc_L.skeleton.face_edge_indices[struc_L.cells[ci].face_idx]
            for trib in tribs
                li = trib.local_edge_idx
                (1 <= li <= length(face_edges)) || continue
                ge = face_edges[li]
                exp_area[ge] = get(exp_area, ge, 0.0) + trib.area
            end
        end
        @test !isempty(exp_area)
        e_of_el_L = edge_of_element_map(struc_L.asap_model)
        F_edge = Dict{Int, Float64}()
        for ld in struc_L.asap_model.loads
            ld isa Asap.TributaryLoad || continue
            ge = get(e_of_el_L, ld.element, 0)
            F_edge[ge] = get(F_edge, ge, 0.0) + tributary_force_N(ld)
        end
        for (ge, area) in exp_area
            area < 1e-9 && continue
            @test isapprox(get(F_edge, ge, 0.0), p_Pa_L * area; rtol = 1e-3)
        end

        @info "Non-convex L-bay conservation" F_total_N = F_total_L expected_N = expected_L ratio = F_total_L / expected_L n_edges_checked = count(a -> a >= 1e-9, values(exp_area))
    end

    # ── Convex NON-RECTANGULAR bays: strip check must reject ⇒ conserve load ──
    @testset "(f) convex non-rectangular bays conserve load" begin
        # (shape name, CCW corner coords (m), one-way joist span axis)
        hex = NTuple{2, Float64}[(2.0, 0.0), (6.0, 0.0), (8.0, 3.0),
                                 (6.0, 6.0), (2.0, 6.0), (0.0, 3.0)]  # wide-middle
        # Critic's counter-example hexagon: a CONVEX shape whose midpoint strips
        # conserve TOTAL area EXACTLY (Σ width·length = 18 = shoelace area, ratio
        # 1.0 by symmetry — no rtol can see the defect) yet MIS-DISTRIBUTE per
        # member: axis (1,0), spacing 2 ⇒ one joist at x=4 (length 6) + two
        # joist-parallel edge girders at x=2,x=6 (length 3). The joist over-applies
        # +14 % and each edge girder under-applies −20 % (unsafe). It passes the
        # CONVEXITY and TOTAL-AREA gates but the CONSTANT-MEMBER-LENGTH gate
        # (6 ≠ 3) correctly rejects it and forces the per-cell fallback.
        critic_hex = NTuple{2, Float64}[(4.0, 0.0), (6.0, 1.5), (6.0, 4.5),
                                        (4.0, 6.0), (2.0, 4.5), (2.0, 1.5)]
        fixtures = [
            ("symmetric trapezoid",
                NTuple{2, Float64}[(0.0, 0.0), (8.0, 0.0), (6.0, 4.0), (2.0, 4.0)], (1.0, 0.0)),
            ("right triangle",
                NTuple{2, Float64}[(0.0, 0.0), (8.0, 0.0), (0.0, 6.0)], (1.0, 0.0)),
            ("diamond",
                NTuple{2, Float64}[(4.0, 0.0), (8.0, 4.0), (4.0, 8.0), (0.0, 4.0)], (1.0, 0.0)),
            ("wide-middle hexagon axis=(1,0)", hex, (1.0, 0.0)),
            ("wide-middle hexagon axis=(0,1)", hex, (0.0, 1.0)),
            ("critic per-member-unsafe hexagon axis=(1,0)", critic_hex, (1.0, 0.0)),
        ]
        for (name, corners, axis) in fixtures
            struc_p = build_poly_bay(corners; span_axis = axis)

            # Joists ARE materialized (the framed-slab strip path is entered)…
            @test !isempty([b for b in struc_p.beams if SS.level_of(b) == 1])
            # …the interior boundary is genuinely convex (passes the convexity gate)…
            poly_p = SS._slab_interior_polygon_m(struc_p, struc_p.slabs[1])
            @test poly_p !== nothing
            @test Asap.is_convex_polygon(poly_p) == true
            # …but its span-direction width is NOT constant, so the
            # constant-member-length gate rejects the strips (returns nothing) and
            # the slab defers to the load-conserving per-cell path. Convexity alone
            # is insufficient — this is exactly the class of shapes a convex-only
            # gate would have wrongly accepted and under-/over-loaded.
            @test SS._framed_slab_strip_geometry(struc_p, struc_p.slabs[1]) === nothing

            to_asap!(struc_p; params = params, diaphragms = :none)
            F = total_tributary_force_N(struc_p.asap_model)

            cellp = struc_p.cells[1]
            p_env_p = StructuralSizer.envelope_pressure(params.load_combinations,
                          cellp.sdl + cellp.self_weight, cellp.live_load)
            p_Pa_p = ustrip(u"Pa", uconvert(u"Pa", p_env_p))
            expected = p_Pa_p * poly_area_m2(corners)
            # Σ(applied gravity) = envelope pressure × TRUE slab area, on EVERY shape.
            @test isapprox(F, expected; rtol = 1e-3)
            @info "Convex non-rect conservation" shape = name F_N = F expected_N = expected ratio = F / expected
        end
    end

    # ── Non-convex compensating-bulge decagon: convexity gate is REQUIRED ─────
    @testset "(g) non-convex compensating-bulge decagon falls back" begin
        # Critic's P0 counter-example (see `DECAGON_CORNERS`): a NON-convex bay
        # that defeats the constant-length + total-area gates JOINTLY (all strip
        # members length 6, Σ width·length = 24 = the true shoelace area EXACTLY),
        # so ONLY the convexity gate rejects it — the length + area gates alone
        # would route via strips and under-size the x=2 edge girder ~14 %.
        @test isapprox(poly_area_m2(DECAGON_CORNERS), 24.0; atol = 1e-9)  # ratio-1.0 trap
        struc_d = build_decagon_bay(with_joists = true)
        slab_d = struc_d.slabs[1]

        # Joists ARE materialized (the framed-slab strip path is entered)…
        @test SS._slab_has_joist_framing(struc_d, slab_d)
        @test !isempty([b for b in struc_d.beams if SS.level_of(b) == 1])
        # …the SLAB boundary is genuinely NON-convex (the defect trigger)…
        poly_d = SS._slab_interior_polygon_m(struc_d, slab_d)
        @test poly_d !== nothing
        @test Asap.is_convex_polygon(poly_d) == false
        # …so the convexity gate declines the strip routing and the slab defers to
        # the load-conserving per-cell path (the P0 fix). Pre-fix, with only the
        # length + area gates, this would have PASSED and mis-sized the edge girders.
        @test SS._framed_slab_strip_geometry(struc_d, slab_d) === nothing

        to_asap!(struc_d; params = params, diaphragms = :none)
        F_d = total_tributary_force_N(struc_d.asap_model)
        # All cells share sdl/self-weight/live, so any cell gives the pressure.
        celld = struc_d.cells[1]
        p_env_d = StructuralSizer.envelope_pressure(params.load_combinations,
                      celld.sdl + celld.self_weight, celld.live_load)
        p_Pa_d = ustrip(u"Pa", uconvert(u"Pa", p_env_d))
        expected_d = p_Pa_d * poly_area_m2(DECAGON_CORNERS)
        # The per-cell fallback (over the two convex cells) conserves TOTAL load:
        # Σ(applied) = envelope pressure × the true decagon area.
        @test isapprox(F_d, expected_d; rtol = 1e-3)

        @info "Non-convex decagon fall-back conservation" F_N = F_d expected_N = expected_d ratio = F_d / expected_d
    end

    # ── Convex KITE: per-band per-member tributary gate is REQUIRED ───────────
    @testset "(h) convex kite rejected by per-band gate" begin
        # Critic's 5th counter-example (see `KITE_CORNERS`): a CONVEX kite that
        # passes CONVEXITY + CONSTANT-MEMBER-LENGTH + TOTAL-AREA jointly (joists at
        # y=−1,+3 both length 4, Σ width·length = 32 = the true shoelace area
        # EXACTLY, ratio 1.0) yet mis-distributes per member — the per-band true
        # areas (≈15.33, ≈16.67 m²) differ from the applied strip areas (12, 20 m²)
        # by ~22 %. The authoritative rectangle-alignment gate rejects it (a kite is
        # not a rectangle), and the per-band defense-in-depth gate would too; all
        # three cheap early-outs pass.
        @test isapprox(poly_area_m2(KITE_CORNERS), 32.0; atol = 1e-9)  # ratio-1.0 trap
        struc_k = build_poly_bay(KITE_CORNERS; span_axis = (1.0, 0.0))
        slab_k = struc_k.slabs[1]

        # Joists ARE materialized (the framed-slab strip path is entered)…
        @test SS._slab_has_joist_framing(struc_k, slab_k)
        @test !isempty([b for b in struc_k.beams if SS.level_of(b) == 1])
        # …the boundary IS genuinely convex (the convexity early-out passes)…
        poly_k = SS._slab_interior_polygon_m(struc_k, slab_k)
        @test poly_k !== nothing
        @test Asap.is_convex_polygon(poly_k) == true
        # …but the kite is not a joist-frame rectangle (and its emitted strip areas
        # disagree with the true per-band tributary areas), so the authoritative
        # rectangle-alignment gate declines the strip routing and the slab defers to
        # the load-conserving per-cell path. Pre-fix, with only the convex + length +
        # area early-outs, this would have PASSED and under-loaded the y=−1 joist ~22 %.
        @test SS._framed_slab_strip_geometry(struc_k, slab_k) === nothing

        to_asap!(struc_k; params = params, diaphragms = :none)
        F_k = total_tributary_force_N(struc_k.asap_model)
        cellk = struc_k.cells[1]
        p_env_k = StructuralSizer.envelope_pressure(params.load_combinations,
                      cellk.sdl + cellk.self_weight, cellk.live_load)
        p_Pa_k = ustrip(u"Pa", uconvert(u"Pa", p_env_k))
        expected_k = p_Pa_k * poly_area_m2(KITE_CORNERS)
        # The per-cell fallback conserves TOTAL load: Σ(applied) = pressure × area.
        @test isapprox(F_k, expected_k; rtol = 1e-3)

        @info "Convex kite per-band fall-back conservation" F_N = F_k expected_N = expected_k ratio = F_k / expected_k
    end

    # ── Sheared parallelogram: rectangle-alignment gate is REQUIRED ───────────
    @testset "(i) sheared parallelogram falls back" begin
        # Critic's routed-parallelogram (see `PARALLELOGRAM_CORNERS`): a CONVEX
        # parallelogram with joist span axis t̂ = (6,−8) parallel to its slanted
        # sides. It passes CONVEXITY + CONSTANT-LENGTH + TOTAL-AREA + per-band AREA
        # (every band chord parallel to a side equals that side), so ALL the cheap
        # early-outs and the per-band gate accept it — the pre-fix behaviour, which
        # routed it and mis-split the landing-girder point loads ~8–15 %. But it is
        # NOT a rectangle, so its joist-frame bounding-box area (16.4·4.8 = 78.72 m²)
        # exceeds its true area (48 m²); ONLY the authoritative rectangle-alignment
        # gate rejects it, and the slab now defers to the load-conserving per-cell
        # path.
        @test isapprox(poly_area_m2(PARALLELOGRAM_CORNERS), 48.0; atol = 1e-9)
        struc_g = build_poly_bay(PARALLELOGRAM_CORNERS; span_axis = (6.0, -8.0))
        slab_g = struc_g.slabs[1]

        # Joists ARE materialized (the framed-slab strip path is entered)…
        @test SS._slab_has_joist_framing(struc_g, slab_g)
        @test !isempty([b for b in struc_g.beams if SS.level_of(b) == 1])
        # …the boundary IS genuinely convex (the convexity early-out passes)…
        poly_g = SS._slab_interior_polygon_m(struc_g, slab_g)
        @test poly_g !== nothing
        @test Asap.is_convex_polygon(poly_g) == true
        # …but it is a sheared (non-rectangular) parallelogram, so the
        # rectangle-alignment gate declines the strip routing (returns nothing).
        @test SS._framed_slab_strip_geometry(struc_g, slab_g) === nothing

        to_asap!(struc_g; params = params, diaphragms = :none)
        F_g = total_tributary_force_N(struc_g.asap_model)
        cellg = struc_g.cells[1]
        p_env_g = StructuralSizer.envelope_pressure(params.load_combinations,
                      cellg.sdl + cellg.self_weight, cellg.live_load)
        p_Pa_g = ustrip(u"Pa", uconvert(u"Pa", p_env_g))
        expected_g = p_Pa_g * poly_area_m2(PARALLELOGRAM_CORNERS)
        # The per-cell fallback conserves TOTAL load: Σ(applied) = pressure × area.
        @test isapprox(F_g, expected_g; rtol = 1e-3)

        @info "Sheared parallelogram fall-back conservation" F_N = F_g expected_N = expected_g ratio = F_g / expected_g
    end

    # ── Routed 8×6 rectangle: per-member end-reaction split is EXACT ──────────
    @testset "(j) routed rectangle per-member reaction split" begin
        # The 8×6 bay IS a rectangle aligned to the joist frame, so the strip
        # fast-path is taken. This locks in that a ROUTED shape is per-MEMBER correct
        # — not merely total-conserving: the uniform strip's mid-span resultant must
        # give each joist a 50/50 split between its two landing girders, matching the
        # TRUE tributary split of a rectangle (constant width ⇒ centroid at
        # mid-span). A sheared band (see testset (i)) would violate this — which is
        # why it now falls back. Use a FRESH bay so `element.forces` reflects a clean
        # single-combo `to_asap!` solve, undisturbed by the enveloped
        # `member_group_demands` solve above.
        struc_r = build_bay(with_joists = true)
        @test SS._framed_slab_strip_geometry(struc_r, struc_r.slabs[1]) !== nothing
        to_asap!(struc_r; params = params, diaphragms = :none)
        joists_r = [b for b in struc_r.beams if SS.level_of(b) == 1]
        @test !isempty(joists_r)

        # Expected per-end reaction MAGNITUDE (not just symmetry): each interior
        # joist carries a uniform tributary strip of width `SPACING` over its span
        # `LY`, so each of its two landing-girder reactions must equal
        # p·w·L/2 (constant width ⇒ uniform load ⇒ 50/50 split). Asserting the
        # magnitude — not merely R1 ≈ R2 — rules out a bug that scales both ends of
        # every joist equally (which a symmetry-only check cannot see).
        cellr = struc_r.cells[1]
        p_env_r = StructuralSizer.envelope_pressure(params.load_combinations,
                      cellr.sdl + cellr.self_weight, cellr.live_load)
        p_Pa_r = ustrip(u"Pa", uconvert(u"Pa", p_env_r))
        expected_R = p_Pa_r * SPACING * LY / 2      # true per-end reaction (N)

        reaction_rtol = 1e-3
        n_checked = 0
        for jb in joists_r
            R1, R2 = joist_end_reactions(struc_r, jb)
            @test R1 > 1.0e3                                  # a real reaction (N)
            @test R2 > 1.0e3
            @test isapprox(R1, R2; rtol = reaction_rtol)      # true 50/50 split
            @test isapprox(R1, expected_R; rtol = reaction_rtol)  # correct MAGNITUDE
            @test isapprox(R2, expected_R; rtol = reaction_rtol)
            n_checked += 1
        end
        @test n_checked == length(joists_r)
        @info "Routed rectangle reaction split" n_joists_checked = n_checked expected_R_N = expected_R
    end

    @info "Joist load-transfer smoke summary" n_joists = length(joists) F_total_N = F_total F_joist_N = F_joist F_girder_N = F_girder Mux_max = Mux_max n_supporting = length(supporting)
end
