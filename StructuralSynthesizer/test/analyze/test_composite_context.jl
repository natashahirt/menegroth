# ==============================================================================
# CompositeContext from the Building — AISC 360-16 §I3.1a effective width
# ==============================================================================
#
# Verifies that `composite_context_from_beam` derives the slab-on-beam geometry
# (effective width per AISC 360-16 §I3.1a, corpus: aisc-360-16, PDF p. 150) from
# the building's per-cell tributary polygons, and that every derived field is
# user-overridable.
#
# Geometry: two thin, long adjacent bays sharing an interior beam, so the shared
# beam is interior (a tributary cell on each side) and the perimeter beams are
# edge beams (one cell). The bays are 2 m wide × 12 m long, so the shared edge
# L/8 = 1.5 m exceeds the ~1 m per-side tributary extent — the moment-weighted
# extent (not the L/8 cap) governs, exercising the irregular-geometry path.
# ==============================================================================

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap
import JSON3
import Meshes   # qualified only: `using Meshes` would shadow `Segment`

# --- Slab material / anchor inputs (shared by every context build) -----------
const _T_SLAB = 8.0u"inch"
const _FC     = 4.0u"ksi"
const _EC     = 3644.0u"ksi"
const _WC     = 145.0u"lb/ft^3"
const _ES     = 29000.0u"ksi"
const _ANCHOR = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi",
                                 7850.0u"kg/m^3")

"""Build the two-bay test building and return `(struc, interior_beam, edge_beam)`."""
function _build_two_bay()
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    v1 = add_vertex!(skel, [4.0,  0.0, z])
    v2 = add_vertex!(skel, [6.0,  0.0, z])
    v3 = add_vertex!(skel, [8.0,  0.0, z])
    v4 = add_vertex!(skel, [8.0, 12.0, z])
    v5 = add_vertex!(skel, [6.0, 12.0, z])
    v6 = add_vertex!(skel, [4.0, 12.0, z])
    # Bay 1 loop (v1,v2,v5,v6); Bay 2 loop (v2,v3,v4,v5). Shared edge v2–v5 once.
    add_element!(skel, v1, v2; group = :beams)
    add_element!(skel, v2, v5; group = :beams)   # shared interior edge
    add_element!(skel, v5, v6; group = :beams)
    add_element!(skel, v6, v1; group = :beams)   # bay-1 left perimeter edge
    add_element!(skel, v2, v3; group = :beams)
    add_element!(skel, v3, v4; group = :beams)
    add_element!(skel, v4, v5; group = :beams)

    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)

    # One two-way CIP slab/cell per bay (isotropic straight-skeleton tributary).
    A  = 24.0u"m^2"
    dl = 2.0u"kN/m^2"
    ll = 3.0u"kN/m^2"
    spans = SpanInfo{Float64}(2.0, 12.0, (1.0, 0.0), 7.0)
    function push_bay!(corners)
        want = Set(corners)
        fidx = findfirst(vs -> Set(vs) == want, skel.face_vertex_indices)
        fidx === nothing && error("no face for $corners")
        cell = Cell(fidx, A, spans, dl, ll)
        cell.floor_type = :two_way
        push!(struc.cells, cell)
        cidx = length(struc.cells)
        slab = Slab{Float64}([cidx], CIPSlabResult(0.2, 0.2, 5.0), :two_way, spans,
                             :interior, nothing, MaterialVolumes(), nothing, nothing,
                             FramingLevel{Float64}[])
        push!(struc.slabs, slab)
    end
    push_bay!((v1, v2, v5, v6))
    push_bay!((v2, v3, v4, v5))

    # Populate per-cell edge tributary polygons (the production input).
    compute_cell_tributaries!(struc)

    # One Segment + Beam per skeleton edge (as initialize_members! would).
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end

    # Locate the beam sitting on a given (va, vb) edge (orientation-agnostic).
    function beam_on(va, vb)
        for b in struc.beams
            e = struc.segments[only(segment_indices(b))].edge_idx
            x, y = skel.edge_indices[e]
            (Set((x, y)) == Set((va, vb))) && return b
        end
        error("no beam on edge ($va,$vb)")
    end

    return (struc, beam_on(v2, v5), beam_on(v6, v1))
end

"""Build a context for `beam`, supplying the fixed material/anchor inputs."""
_mkctx(struc, beam; kwargs...) = composite_context_from_beam(
    struc, beam; t_slab = _T_SLAB, fc′ = _FC, Ec = _EC, wc = _WC, Es = _ES,
    anchor = _ANCHOR, kwargs...)

"""Locate the single-segment beam sitting on skeleton edge `(va, vb)`."""
function beam_on_edge(struc, va, vb)
    skel = struc.skeleton
    for b in struc.beams
        e = struc.segments[only(segment_indices(b))].edge_idx
        x, y = skel.edge_indices[e]
        Set((x, y)) == Set((va, vb)) && return b
    end
    error("no beam on edge ($va,$vb)")
end

"""Per-side effective width at station `s` from the §I3.1a per-side extents,
evaluated directly from the profile samples (independent of `b_eff_at_station`)."""
function _hand_beff(slab, L, s, left, right)
    cap = L / 8
    dl = left  === nothing ? _half_scalar(L, slab.beam_spacing_left,  slab.edge_dist_left)  :
         min(cap, StructuralSizer._sample_extent(left, s) * u"m")
    dr = right === nothing ? _half_scalar(L, slab.beam_spacing_right, slab.edge_dist_right) :
         min(cap, StructuralSizer._sample_extent(right, s) * u"m")
    return dl + dr
end
_half_scalar(L, bs, ed) = ed === nothing ? min(L / 8, bs / 2) : min(L / 8, bs / 2, ed)

@testset "CompositeContext + per-station bridge (AISC I3.1a)" begin
    struc, ibeam, ebeam = _build_two_bay()

    # ======================================================================
    # 1. INTERIOR beam: per-side profiles from BOTH adjacent bays; b_eff(s)
    #    applies the §I3.1a per-side caps on the LOCAL extents.
    # ======================================================================
    @testset "1. Interior beam: two per-side profiles, per-station §I3.1a b_eff" begin
        left, right = beam_side_profiles(struc, ibeam)
        @test left !== nothing && right !== nothing      # interior ⇒ two sides
        @test left.positions[1] == 0.0 && left.positions[end] == 1.0
        @test right.positions[1] == 0.0 && right.positions[end] == 1.0

        ctx = _mkctx(struc, ibeam)
        L = ctx.L_beam
        # b_eff_at_station matches the independent per-side §I3.1a hand formula at
        # EVERY station (incl. the corners, where the straight-skeleton tributary
        # extent tapers to zero ⇒ b_eff = 0 — physically correct, not a failure).
        for s in (0.0, 0.25, 0.5, 0.75, 1.0)
            b = b_eff_at_station(ctx.slab, L, s; left = left, right = right)
            @test isapprox(b, _hand_beff(ctx.slab, L, s, left, right); rtol = 1e-9)
        end
        # Interior stations carry a strictly positive effective width.
        for s in (0.25, 0.5, 0.75)
            @test ustrip(u"m", b_eff_at_station(ctx.slab, L, s; left = left, right = right)) > 0
        end
        @test isapprox(ctx.L_beam, 12.0u"m"; rtol = 1e-9)
        @test ctx.slab.edge_dist_left === nothing && ctx.slab.edge_dist_right === nothing
    end

    # ======================================================================
    # 2. SYMMETRY — identical bays ⇒ left/right profiles match pointwise.
    # ======================================================================
    @testset "2. Symmetric bays ⇒ symmetric per-side profiles" begin
        left, right = beam_side_profiles(struc, ibeam)
        for s in (0.1, 0.3, 0.5, 0.7, 0.9)
            @test isapprox(StructuralSizer._sample_extent(left, s),
                           StructuralSizer._sample_extent(right, s); rtol = 1e-6)
        end
        # Representative scalar context b_eff is positive and bounded by 2·(L/8).
        ctx = _mkctx(struc, ibeam)
        b = get_b_eff(ctx.slab, ctx.L_beam)
        @test ustrip(u"m", b) > 0
        @test b <= 2 * (ctx.L_beam / 8) + 1e-9u"m"
    end

    # ======================================================================
    # 3. EDGE beam: one side is a slab edge (no adjacent cell) ⇒ one-sided.
    # ======================================================================
    @testset "3. Edge beam: one-sided per-side profile" begin
        left, right = beam_side_profiles(struc, ebeam)
        @test (left === nothing) ⊻ (right === nothing)   # exactly one side present

        ctx = _mkctx(struc, ebeam)
        L = ctx.L_beam
        # The slab-edge side is pinned to edge distance 0 ⇒ contributes nothing.
        @test (ctx.slab.edge_dist_left == 0.0u"m") || (ctx.slab.edge_dist_right == 0.0u"m")
        # Per-station b_eff is one-sided and positive.
        b = b_eff_at_station(ctx.slab, L, 0.5; left = left, right = right)
        @test ustrip(u"m", b) > 0
        @test isapprox(b, _hand_beff(ctx.slab, L, 0.5, left, right); rtol = 1e-9)
    end

    # ======================================================================
    # 4. OVERRIDES (F16): an explicit field beats the building default.
    # ======================================================================
    @testset "4. Explicit overrides beat the building default" begin
        left, _ = beam_side_profiles(struc, ibeam)
        default_bsl = 2 * StructuralSynthesizer._mean_extent_m(left)   # building-derived (m)

        ctx_bs = _mkctx(struc, ibeam; beam_spacing_left = 4.0u"m")
        @test isapprox(ctx_bs.slab.beam_spacing_left, 4.0u"m"; rtol = 1e-9)
        @test !isapprox(ustrip(u"m", ctx_bs.slab.beam_spacing_left), default_bsl; rtol = 1e-3)

        ctx_ed = _mkctx(struc, ibeam; edge_dist_left = 0.5u"m")
        @test isapprox(ctx_ed.slab.edge_dist_left, 0.5u"m"; rtol = 1e-9)

        ctx_L = _mkctx(struc, ibeam; L_beam = 20.0u"m")
        @test isapprox(ctx_L.L_beam, 20.0u"m"; rtol = 1e-9)

        custom = SolidSlabOnBeam(_T_SLAB, _FC, _EC, _WC, _ES, 3.0u"ft", 3.0u"ft")
        ctx_slab = _mkctx(struc, ibeam; slab = custom)
        @test ctx_slab.slab === custom

        ctx_opts = _mkctx(struc, ibeam; shored = true, neg_moment = true,
                          Asr = 1.0u"inch^2", Fysr = 60.0u"ksi")
        @test ctx_opts.shored == true && ctx_opts.neg_moment == true
        @test isapprox(ctx_opts.Asr, uconvert(u"mm^2", 1.0u"inch^2"); rtol = 1e-6)
    end

    # ======================================================================
    # 5. MULTI-EDGE (chained) beam — SUPPORTED (no throw); profile stitches
    #    across both bays onto the beam's [0,1]. (C9 at the building level.)
    # ======================================================================
    @testset "5. Multi-edge chained beam is supported (stitched, no throw)" begin
        # Two collinear perimeter edges along y = 0: (v1,v2) [bay 1] + (v2,v3)
        # [bay 2]. Both bays sit on the +y side, so the chained beam is a
        # one-sided EDGE beam whose extent steps from bay 1 to bay 2 at v2.
        s12 = only(segment_indices(beam_on_edge(struc, 1, 2)))
        s23 = only(segment_indices(beam_on_edge(struc, 2, 3)))
        Lchain = member_length(beam_on_edge(struc, 1, 2)) +
                 member_length(beam_on_edge(struc, 2, 3))
        chained = Beam([s12, s23], Lchain; role = :girder)

        left, right = beam_side_profiles(struc, chained)   # must NOT throw
        present = left === nothing ? right : left
        @test present !== nothing
        @test present.positions[1] == 0.0 && present.positions[end] == 1.0
        # The one adjacent-cell side is present; the slab-edge side is empty.
        @test (left === nothing) ⊻ (right === nothing)
    end
end

# =============================================================================
# B5. EXACT FEM DEMAND FIELD — `_element_signed_moment_at` recovers the exact
#     TributaryLoad internal-moment field (no sampling, no new demand path).
# =============================================================================
#
# Simply-supported beam along +X (pin at x=0, roller at x=L) — the realistic,
# both-ends-supported configuration the production pipeline always produces.
# `Element`'s default roll Ψ = π/2 puts local-y = +global-Z, so the gravity
# moment lands in `My` (the component `_element_signed_moment_at` returns).
# DOF layout is [UX, UY, UZ, RX, RY, RZ] with `true` = FREE. We free BOTH bending
# rotations (RY, RZ) at each support and fix torsion (RX) — the gravity-bending
# release (My is about local-y under Ψ = π/2) then gives true zero-moment pins,
# while fixing RX keeps the single-element model non-singular.
@testset "B5. Exact TributaryLoad moment-field recovery" begin
    sec = Asap.Section(0.01u"m^2", 200e9u"Pa", 77e9u"Pa",
                       1e-4u"m^4", 1e-4u"m^4", 1e-4u"m^4")
    pin_dof    = [false, false, false, false, true, true]    # UX,UY,UZ,RX fixed; RY,RZ free
    roller_dof = [true,  false, false, false, true, true]    # +UX free (roller); RY,RZ free
    Lm = 8.0                                                  # m
    w  = 1000.0                                               # N/m (1000 Pa × 1 m)

    # --- Uniform load: simply-supported M(x) = w·x(L−x)/2, peak wL²/8 at mid ----
    n1 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], pin_dof)
    n2 = Asap.Node([8.0u"m", 0.0u"m", 0.0u"m"], roller_dof)
    el = Asap.Element(n1, n2, sec)
    tload = Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"], 1000.0u"Pa",
                               (0.0, 0.0, -1.0))
    model = Asap.Model([n1, n2], [el], [tload])
    Asap.solve!(model)

    My_at(x) = StructuralSynthesizer._element_signed_moment_at(el, [tload], x)

    # Analytic ground truth on the LOAD INTEGRATION via the beam equation
    # d²M/dx² = −w(x). The second difference annihilates any constant/linear term,
    # so it is immune to the single-element My sign/offset convention and isolates
    # the x² coefficient = −w/2 ⇒ |ΔΔM/h²| = w. (This is the closed-form check the
    # §I3 demand ultimately rests on: the exact TributaryLoad moment curvature.)
    h = 0.5
    for x in (2.0, 4.0, 6.0)
        curv = (My_at(x + h) - 2 * My_at(x) + My_at(x - h)) / h^2
        @test isapprox(abs(curv), w; rtol = 1e-6)        # = w (uniform) everywhere
    end

    # Exact mirror of Asap's own (reference-validated) field recovery at every
    # station — the single-station path is the same math, no sampling. (Asap's
    # TributaryLoad field is itself validated vs a reference calculator in
    # external/Asap/test/loads/test_tributary_load.jl.)
    IF = Asap.ElementInternalForces(el, [tload]; resolution = 21)
    for i in eachindex(IF.x)
        @test isapprox(My_at(IF.x[i]), IF.My[i]; rtol = 1e-8, atol = 1e-6)
    end
    @test maximum(abs, IF.My) > 0                          # field is non-trivial

    # --- Triangular load (0 → 2000 N/m): matches the trusted Asap field --------
    m1 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], pin_dof)
    m2 = Asap.Node([8.0u"m", 0.0u"m", 0.0u"m"], roller_dof)
    el_t = Asap.Element(m1, m2, sec)
    tri = Asap.TributaryLoad(el_t, [0.0, 1.0], [0.0u"m", 2.0u"m"], 1000.0u"Pa",
                             (0.0, 0.0, -1.0))
    model_t = Asap.Model([m1, m2], [el_t], [tri])
    Asap.solve!(model_t)

    Mt_at(x) = StructuralSynthesizer._element_signed_moment_at(el_t, [tri], x)
    # Single-station recovery equals Asap's trusted multi-station field for the
    # non-uniform (triangular) load as well — no sampling, same math.
    IF_t = Asap.ElementInternalForces(el_t, [tri]; resolution = 21)
    for i in eachindex(IF_t.x)
        @test isapprox(Mt_at(IF_t.x[i]), IF_t.My[i]; rtol = 1e-8, atol = 1e-6)
    end
    @test maximum(abs, IF_t.My) > 0
end

# =============================================================================
# E. DEFLECTION — the composite-stiffness correction factor applied to the FEM δ
#    (δ_composite = δ_steel · Ix / I_LB). The FEM δ itself (continuity-correct)
#    comes from `member_group_demands`; here we verify the correction multiplier.
# =============================================================================
@testset "E. Composite deflection scale = Ix / I_LB (< 1, stiffer)" begin
    section  = W("W21X55")
    material = A992_Steel
    slab = SolidSlabOnBeam(7.5u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
                           29000.0u"ksi", 10.0u"ft", 10.0u"ft")
    L     = 45.0u"ft"
    b_eff = get_b_eff(slab, L)
    ΣQn   = 292.0u"kip"

    I_LB  = get_I_LB(section, material, slab, b_eff, ΣQn)
    scale = composite_deflection_scale(section, I_LB)

    @test scale ≈ ustrip(section.Ix / I_LB)
    @test I_LB > section.Ix        # composite (lower-bound) is stiffer than steel
    @test 0 < scale < 1            # ⇒ composite deflection < bare-steel FEM δ

    # Zero composite action ⇒ I_LB = Ix ⇒ no correction (scale = 1).
    I_LB0 = get_I_LB(section, material, slab, b_eff, 0.0u"kip")
    @test isapprox(composite_deflection_scale(section, I_LB0), 1.0; rtol = 1e-9)
end

# =============================================================================
# REAL SOLVED-MODEL FIXTURES — multi-element beams / a column-supported frame.
# =============================================================================
#
# The isolated single Asap element (B5) is degenerate for an ABSOLUTE moment
# recovery: a lone element spanning two translation-fixed support nodes carries a
# spurious constant moment offset (its end nodes cannot rotate/translate with a
# surrounding frame). The fixtures below instead build REAL solved models whose
# beams behave exactly as the production pipeline's do:
#   • multi-element simply-supported beams with FREE interior nodes (T1, T2a);
#   • a two-span continuous beam (T2b);
#   • a column-supported two-bay frame with pin-released (`:freefixed`) single-
#     element beams, so each beam is a true simple span whose end nodes are free
#     (carried by fixed-base columns) — the configuration under which the single
#     element per edge recovers its exact field (T3).
# Tolerances are governed by the `TributaryLoad` lumped-load FEM convergence,
# measured to ~0.3 % at nel = 24 and ~0.16 % at nel = 32 (δ_FEM / δ_Euler), so a
# 1 % tolerance on deflection and 2 % on the recovered peak moment are safe.

"""Max |global-Z| nodal displacement (m) of a solved model — the FEM deflection δ."""
_max_vertical_disp_m(model) = maximum(abs(ustrip(u"m", n.displacement[3])) for n in model.nodes)

# DOF layout is [UX, UY, UZ, RX, RY, RZ], `true` = FREE. Gravity acts in −Z, and
# `Element`'s default roll Ψ = π/2 puts the strong-axis bending in `My`.
const _PIN_DOF    = [false, false, false, false, true, true]   # UX,UY,UZ,RX fixed; RY,RZ free
const _ROLLER_DOF = [true,  false, false, false, true, true]   # +UX free (roller)
const _FREE_DOF   = [true,  true,  true,  true,  true, true]    # interior / frame node
const _FIXED_DOF  = [false, false, false, false, false, false] # column base

"""
    _solve_ss_beam(; L, w, nel, sec) -> Asap.Model

Build and solve a simply-supported beam along +X of span `L` (m), discretized into
`nel` equal elements with FREE interior nodes (pin at x = 0, roller at x = L). A
uniform `TributaryLoad` (`w` N/m, gravity −Z) is applied to every element.
"""
function _solve_ss_beam(; L::Float64, w::Float64, nel::Int, sec::Asap.Section)
    xs = range(0.0, L; length = nel + 1)
    nodes = [Asap.Node([x * u"m", 0.0u"m", 0.0u"m"],
                        i == 1 ? _PIN_DOF : (i == nel + 1 ? _ROLLER_DOF : _FREE_DOF))
             for (i, x) in enumerate(xs)]
    elements = [Asap.Element(nodes[i], nodes[i + 1], sec) for i in 1:nel]
    loads = [Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"], w * u"Pa",
                                (0.0, 0.0, -1.0)) for el in elements]
    model = Asap.Model(nodes, elements, loads)
    Asap.solve!(model)
    return model
end

"""
    _solve_two_span(; L, w, nel_span, sec) -> Asap.Model

Build and solve a TWO-SPAN continuous beam along +X (supports at x = 0, L, 2L),
each span discretized into `nel_span` elements with free interior nodes and a
uniform `TributaryLoad` over the full length.
"""
function _solve_two_span(; L::Float64, w::Float64, nel_span::Int, sec::Asap.Section)
    ntot = 2 * nel_span
    xs   = range(0.0, 2L; length = ntot + 1)
    mid  = nel_span + 1                     # interior support node (x = L)
    dof(i) = i == 1 ? _PIN_DOF :
             (i == ntot + 1 || i == mid) ? _ROLLER_DOF : _FREE_DOF
    nodes = [Asap.Node([x * u"m", 0.0u"m", 0.0u"m"], dof(i)) for (i, x) in enumerate(xs)]
    elements = [Asap.Element(nodes[i], nodes[i + 1], sec) for i in 1:ntot]
    loads = [Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"], w * u"Pa",
                                (0.0, 0.0, -1.0)) for el in elements]
    model = Asap.Model(nodes, elements, loads)
    Asap.solve!(model)
    return model
end

"""
    _wrap_beam_building(model, seg_lengths) -> (struc, beam)

Wrap a solved multi-element beam `model` in a minimal `BuildingStructure` so the
building-level `beam_signed_moment_field` can run. Element `i` ↔ segment `i` ↔
`edge_idx i`; `seg_lengths` are the per-element physical lengths (m). The skeleton
is a throw-away single edge — the moment field never reads it.
"""
function _wrap_beam_building(model, seg_lengths::Vector{Float64})
    skel = BuildingSkeleton{Float64}()
    add_vertex!(skel, [0.0, 0.0, 0.0]); add_vertex!(skel, [1.0, 0.0, 0.0])
    add_element!(skel, 1, 2; group = :beams)
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    for (i, L) in enumerate(seg_lengths)
        push!(struc.segments, Segment(i, L))
    end
    beam = Beam(collect(1:length(seg_lengths)), sum(seg_lengths); role = :girder, level = 0)
    push!(struc.beams, beam)
    struc.asap_model = model
    return (struc, beam)
end

# =============================================================================
# T1. ABSOLUTE MOMENT SIGN on a solved multi-element beam.
#     `beam_signed_moment_field` is SAGGING-POSITIVE and matches wL²/8 at
#     midspan with ≈ 0 at the two pinned ends. (The absolute-sign assertion that
#     is unsafe on an isolated single element.)
# =============================================================================
@testset "T1. Absolute moment sign on a solved multi-element beam" begin
    L = 10.0; w = 12_000.0; nel = 32                      # 32 elements ⇒ ~0.2 % peak error
    sec = Asap.Section(0.013u"m^2", 200e9u"Pa", 77e9u"Pa",
                       4.7e-4u"m^4", 4.7e-4u"m^4", 1e-5u"m^4")
    model = _solve_ss_beam(; L = L, w = w, nel = nel, sec = sec)
    struc, beam = _wrap_beam_building(model, fill(L / nel, nel))

    M_of_s, bps = beam_signed_moment_field(struc, beam)
    M_mid  = ustrip(u"N*m", M_of_s(0.5))
    M_end0 = ustrip(u"N*m", M_of_s(0.0))
    M_end1 = ustrip(u"N*m", M_of_s(1.0))

    M_ref = w * L^2 / 8                                   # simple-span sagging peak
    @test M_mid > 0                                       # SAGGING POSITIVE (absolute sign)
    @test isapprox(M_mid, M_ref; rtol = 0.02)             # ≈ wL²/8 (lumped-load FEM)
    @test abs(M_end0) < 0.02 * M_ref                      # pinned ends ⇒ ≈ 0
    @test abs(M_end1) < 0.02 * M_ref
    @test !isempty(bps)                                   # element-boundary breakpoints
end

# =============================================================================
# T2. DEFLECTION REDUCTION + CONTINUITY (AISC Commentary §I3.2 / Manual T3-20).
#   (a) Simple span: bare-steel FEM δ × composite_deflection_scale (Ix / I_LB)
#       matches the composite 5wL⁴/384EI_LB form within 1 % (FEM convergence).
#   (b) Continuous two-span: the scaled FEM δ is DEMONSTRABLY NOT the simple-span
#       5wL⁴/384EI form — so that closed form must not be used for a continuous
#       member (the whole point of the FEM-δ path).
# =============================================================================
@testset "T2. Composite deflection reduction + continuity" begin
    section  = W("W21X55")
    material = A992_Steel
    sec_asap = StructuralSizer.to_asap_section(section, material)
    E_Pa  = ustrip(u"Pa", uconvert(u"Pa", material.E))
    Ix_m4 = ustrip(u"m^4", uconvert(u"m^4", section.Ix))

    slab  = SolidSlabOnBeam(7.5u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
                            29000.0u"ksi", 10.0u"ft", 10.0u"ft")
    L = 10.0; w = 12_000.0; nel = 32
    b_eff   = get_b_eff(slab, L * u"m")
    ΣQn     = 292.0u"kip"
    I_LB    = get_I_LB(section, material, slab, b_eff, ΣQn)
    I_LB_m4 = ustrip(u"m^4", uconvert(u"m^4", I_LB))
    scale   = composite_deflection_scale(section, I_LB)

    δ_eb   = 5 * w * L^4 / (384 * E_Pa * Ix_m4)            # bare-steel Euler-Bernoulli
    δ_comp = 5 * w * L^4 / (384 * E_Pa * I_LB_m4)          # composite (I_LB) form

    # --- (a) SIMPLE SPAN ------------------------------------------------------
    δ_fem = _max_vertical_disp_m(_solve_ss_beam(; L = L, w = w, nel = nel, sec = sec_asap))
    @test isapprox(δ_fem, δ_eb; rtol = 0.01)              # FEM ≈ 5wL⁴/384EIx (nel = 32)
    @test isapprox(δ_fem * scale, δ_comp; rtol = 0.01)    # scaled ≈ 5wL⁴/384EI_LB
    @test δ_fem * scale < δ_fem                           # composite is stiffer (scale < 1)

    # --- (b) CONTINUOUS (two equal spans) -------------------------------------
    δ_cont = _max_vertical_disp_m(_solve_two_span(; L = L, w = w, nel_span = nel, sec = sec_asap))
    @test !isapprox(δ_cont, δ_eb; rtol = 0.10)            # ≠ simple-span formula …
    @test δ_cont < δ_eb                                   # … continuity makes it stiffer
    @test 0.30 < δ_cont / δ_eb < 0.60                     # ≈ 0.42× (two-span closed form)
    @test !isapprox(δ_cont * scale, δ_comp; rtol = 0.10)  # ⇒ SS composite form invalid here
end

# =============================================================================
# T3. END-TO-END on a solved column-supported two-bay building. Tributaries +
#     solve + `composite_context_from_beam` + `check_composite_beam` on an
#     INTERIOR beam (tributary both sides) and an EDGE beam (one-sided).
#     `:freefixed` leaves a negative moment at the fixed end. AISC 360-22
#     §I3.2b (corpus: aisc-360-22, PDF p. 170) keeps that station on Chapter F
#     when the negative-region gates are closed, and that end governs.
# =============================================================================

"""
    _solve_two_bay_frame!(struc; w) -> struc

Build and solve a real frame over the two-bay floor: every skeleton vertex gets a
FREE floor node (z = 3 m) carried by a fixed-base column (ground node at z = 0),
and every skeleton beam edge becomes ONE pin-released (`:freefixed`, simply
supported) steel element carrying a uniform gravity `TributaryLoad` (`w` N/m).
Element `i` ↔ skeleton edge `i`, so `beam_signed_moment_field` recovers each
beam's exact simple-span sagging field. Mutates and returns `struc`.
"""
function _solve_two_bay_frame!(struc; w::Float64 = 10_000.0)
    skel = struc.skeleton
    nv   = length(skel.vertices)
    coord(v) = (ustrip(u"m", Meshes.coords(skel.vertices[v]).x),
                ustrip(u"m", Meshes.coords(skel.vertices[v]).y),
                ustrip(u"m", Meshes.coords(skel.vertices[v]).z))

    floor_nodes  = [Asap.Node([c[1] * u"m", c[2] * u"m", c[3] * u"m"], copy(_FREE_DOF))
                    for c in (coord(v) for v in 1:nv)]
    ground_nodes = [Asap.Node([c[1] * u"m", c[2] * u"m", 0.0u"m"], copy(_FIXED_DOF))
                    for c in (coord(v) for v in 1:nv)]

    beam_sec = StructuralSizer.to_asap_section(W("W21X55"), A992_Steel)
    col_sec  = Asap.Section(0.05u"m^2", 200e9u"Pa", 77e9u"Pa",
                            1e-3u"m^4", 1e-3u"m^4", 1e-3u"m^4", 7850.0u"kg/m^3")

    # Beam elements FIRST ⇒ element index == skeleton edge index. `:freefixed`
    # releases the start and fixes the end into the column, so the end moment
    # is real. It is not a simple span.
    beam_els = [Asap.Element(floor_nodes[v1], floor_nodes[v2], beam_sec; release = :freefixed)
                for (v1, v2) in skel.edge_indices]
    col_els  = [Asap.Element(ground_nodes[v], floor_nodes[v], col_sec) for v in 1:nv]
    loads = [Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"], w * u"Pa",
                                (0.0, 0.0, -1.0)) for el in beam_els]

    model = Asap.Model(vcat(floor_nodes, ground_nodes), vcat(beam_els, col_els), loads)
    Asap.solve!(model)
    struc.asap_model = model
    return struc
end

@testset "T3. End-to-end composite check on a solved two-bay building" begin
    struc, ibeam, ebeam = _build_two_bay()
    _solve_two_bay_frame!(struc)

    section  = W("W21X55")
    material = A992_Steel

    for (beam, two_sided) in ((ibeam, true), (ebeam, false))
        left, right = beam_side_profiles(struc, beam)
        if two_sided
            @test left !== nothing && right !== nothing       # interior ⇒ tributary both sides
        else
            @test (left === nothing) ⊻ (right === nothing)    # edge ⇒ exactly one side
        end

        ctx = _mkctx(struc, beam)
        res = check_composite_beam(struc, beam, section, material, ctx; ΣQn = 292.0u"kip")
        M_of_s, _ = beam_signed_moment_field(struc, beam)

        @test isfinite(res.dcr_max) && res.dcr_max > 0
        M_gov = ustrip(u"N*m", uconvert(u"N*m", res.M))
        M_mid = ustrip(u"N*m", M_of_s(0.5))
        # The fixed-end moment is the same order as midspan, not solver noise.
        @test abs(M_gov) > 0.1 * abs(M_mid)
        if res.sense == :negative
            @test M_gov < 0
            # No negative-region anchors and no slab reinforcement, so §I3.2b
            # stays on Chapter F at Lb = this member's span. That is below φMp.
            ϕF = StructuralSizer.available_negative_flexure(
                section, material; Lb = ctx.L_beam,
                Asr = 0.0u"mm^2", Fysr = 0.0u"MPa", neg_moment = false)
            @test isapprox(uconvert(u"N*m", res.ϕMn), uconvert(u"N*m", ϕF); rtol = 1e-6)
            @test uconvert(u"N*m", res.ϕMn) < uconvert(u"N*m", 0.9 * section.Zx * material.Fy)
        else
            @test M_gov >= 0
            @test ustrip(u"m", res.b_eff) > 0
            @test res.I_LB > section.Ix
        end
        # The sagging region still has slab. A corner station can have none.
        b_mid = b_eff_at_station(ctx.slab, ctx.L_beam, 0.5; left = left, right = right)
        @test ustrip(u"m", b_mid) > 0
        @test get_I_LB(section, material, ctx.slab, b_mid, 292.0u"kip") > section.Ix
    end
end

@testset "size_beams! wires per-station composite" begin
    struc, ibeam, _ebeam = _build_two_bay()
    _solve_two_bay_frame!(struc)
    conc = Concrete(_EC, _FC, _WC, 0.20, 0.1)

    payload = composite_group_payload(struc, [ibeam], member_length(ibeam),
                                      conc, _T_SLAB, _ES; anchor = _ANCHOR)
    @test payload isa PerStationComposite
    field = only(payload.fields)
    section = W("W21X55")
    g = governing_sagging_station(section, A992_Steel, payload.ctx.slab, payload.ctx.L_beam,
                                  field.demand_of_s, 1.0e12;
                                  left = field.left, right = field.right,
                                  extra_breakpoints = field.breakpoints)
    b_direct = b_eff_at_station(payload.ctx.slab, payload.ctx.L_beam, g.s_star;
                                left = field.left, right = field.right)
    @test isapprox(g.b_eff, b_direct; rtol = 1e-9)
    @test g.M_pos > 0
    st = CompositeSaggingStation(g.b_eff, g.M_pos * u"N*m", g.spacing_left, g.spacing_right)
    ctx_st = context_at_sagging_station(payload.ctx, st)
    @test isapprox(get_b_eff(ctx_st.slab, ctx_st.L_beam), g.b_eff; rtol = 1e-9)

    # The fixture stores only TributaryLoad, so size_beams! can add self-weight.
    widen = Asap.AbstractLoad[]
    append!(widen, struc.asap_model.loads)
    struc.asap_model.loads = widen

    # Unshored pre-cure, SEI/ASCE 37-02 Eq. 2-3 on a simple span (corpus:
    # sei-asce-37-02, PDF p. 16), with the medium personnel load. On these
    # 12 m beams the wet 8 in slab over about 1–2 m of tributary exceeds
    # Chapter F at Lb = the span for W21×55 (φMn ≈ 112 kN·m) and W27×84
    # (φMn ≈ 273 kN·m). W14×90 (φMn ≈ 532 kN·m) clears it. The 2 m beams
    # still take the lighter shape. wL²/8 is the engineering-judgment span.
    opts = SteelBeamOptions(composite = true,
                             composite_anchor_d = 0.75u"inch",
                             composite_anchor_length = 5.0u"inch",
                             composite_anchor_Fu = 65.0u"ksi",
                             custom_catalog = [W("W21X55"), W("W14X90")],
                             deflection_limit = nothing,
                             total_deflection_limit = nothing)
    size_beams!(struc, opts; reanalyze = false,
                composite_concrete = conc, composite_t_slab = _T_SLAB)
    @test !isempty(struc.member_groups)
    @test all(g -> g.section !== nothing, values(struc.member_groups))
    for g in values(struc.member_groups)
        lengths = (member_length(struc.beams[i]) for i in g.member_indices)
        Lmax = maximum(L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L) for L in lengths)
        @test g.section.name == (Lmax > 10 ? "W14X90" : "W21X55")
    end

    struc_bare, _, _ = _build_two_bay()
    _solve_two_bay_frame!(struc_bare)
    bare_loads = Asap.AbstractLoad[]
    append!(bare_loads, struc_bare.asap_model.loads)
    struc_bare.asap_model.loads = bare_loads
    @test_throws ArgumentError size_beams!(struc_bare, SteelBeamOptions(composite = true);
                                           reanalyze = false)
end

# =============================================================================
# Each beam keeps its own span, thickness, and concrete.
# =============================================================================

@testset "Per-beam span, thickness, and concrete" begin
    struc, _, _ = _build_two_bay()
    _solve_two_bay_frame!(struc)

    bay1 = beam_on_edge(struc, 6, 1)   # long edge of the first bay only
    bay2 = beam_on_edge(struc, 3, 4)   # long edge of the second bay only
    L1 = member_length(bay1)
    L2 = member_length(bay2)
    Lsum = (L1 isa Unitful.Quantity ? L1 : L1 * u"m") +
           (L2 isa Unitful.Quantity ? L2 : L2 * u"m")

    c5 = Concrete(3600.0u"ksi", 5.0u"ksi", 145.0u"lb/ft^3", 0.20, 0.1)
    c3 = Concrete(3200.0u"ksi", 3.0u"ksi", 145.0u"lb/ft^3", 0.20, 0.1)
    cascade = Concrete(_EC, _FC, _WC, 0.20, 0.1)   # 4 ksi, not either slab
    struc.slabs[1].result = CIPSlabResult(0.15u"m", 0.15u"m", 3.6u"kN/m^2")
    struc.slabs[2].result = CIPSlabResult(0.25u"m", 0.25u"m", 6.0u"kN/m^2")
    struc.slabs[1].volumes[c5] = 1.0u"m^3"
    struc.slabs[2].volumes[c3] = 1.0u"m^3"

    payload = composite_group_payload(struc, [bay1, bay2], Lsum, cascade, nothing, _ES;
                                      anchor = _ANCHOR)
    @test length(payload.fields) == 2
    f1, f2 = payload.fields
    @test isapprox(f1.L_beam, L1 isa Unitful.Quantity ? uconvert(u"m", L1) : L1 * u"m"; rtol = 1e-9)
    @test isapprox(f2.L_beam, L2 isa Unitful.Quantity ? uconvert(u"m", L2) : L2 * u"m"; rtol = 1e-9)
    @test !isapprox(f1.L_beam, Lsum; rtol = 1e-3)
    # First bay is 6 in of 5 ksi concrete, not the 4 ksi cascade and not the
    # other bay's 10 in slab.
    @test isapprox(f1.slab.t_slab, 0.15u"m"; rtol = 1e-9)
    @test isapprox(f1.slab.fc′, 5.0u"ksi"; rtol = 1e-6)
    @test isapprox(f2.slab.t_slab, 0.25u"m"; rtol = 1e-9)
    @test isapprox(f2.slab.fc′, 3.0u"ksi"; rtol = 1e-6)

    # The summed length would be the context span. Each field is shorter, so
    # its L/8 cap is tighter wherever the tributary exceeds that cap.
    b_own = b_eff_at_station(f1.slab, f1.L_beam, 0.5; left = f1.left, right = f1.right)
    b_sum = b_eff_at_station(f1.slab, Lsum, 0.5; left = f1.left, right = f1.right)
    @test b_own <= b_sum + 1e-9u"m"

    struc.slabs[1].result = StructuralSizer.ShapedSlabResult(0.2u"m", 5.0u"kN/m^2")
    @test_throws ArgumentError composite_group_payload(struc, [bay1], L1, cascade, nothing, _ES;
                                                       anchor = _ANCHOR)

    struc.slabs[1].result = StructuralSizer.VaultResult(
        0.10u"m", 0.40u"m", 1.0u"m",
        1.0u"kN/m", 1.0u"kN/m",
        0.10u"m", 5.0u"kN/m^2",
        1.0, :symmetric,
        (σ = 1.0, σ_allow = 2.0, ratio = 0.5, ok = true),
        (δ = 0.01, limit = 0.02, ratio = 0.5, ok = true),
        (converged = true, iterations = 1))
    @test_throws ArgumentError composite_group_payload(struc, [bay1], L1, cascade, nothing, _ES;
                                                       anchor = _ANCHOR)
end

# ==============================================================================
# Explicit slab, anchor, and shoring inputs. No nominal stud.
# ==============================================================================

@testset "Composite inputs are explicit" begin
    struc, beam, _ = _build_two_bay()
    empty!(struc.slabs)
    L = member_length(beam)
    conc = Concrete(_EC, _FC, _WC, 0.20, 0.1)

    err_t = try
        composite_group_payload(struc, [beam], L, conc, nothing, _ES; anchor = _ANCHOR)
        nothing
    catch e
        e
    end
    @test err_t isa ArgumentError
    @test occursin("slab thickness", err_t.msg)

    err_c = try
        composite_group_payload(struc, [beam], L, nothing, _T_SLAB, _ES; anchor = _ANCHOR)
        nothing
    catch e
        e
    end
    @test err_c isa ArgumentError
    @test occursin("slab concrete", err_c.msg)
    @test !occursin("slab thickness", err_c.msg)

    err_d = try
        composite_anchor_from_options(SteelBeamOptions(composite = true,
            composite_anchor_length = 5.0u"inch", composite_anchor_Fu = 65.0u"ksi"))
        nothing
    catch e
        e
    end
    @test err_d isa ArgumentError
    @test occursin("composite_anchor_d", err_d.msg)

    bare = _build_two_bay()[1]
    err_nlp = try
        size_beams!(bare, SteelBeamOptions(composite = true, sizing_strategy = :nlp);
                    reanalyze = false)
        nothing
    catch e
        e
    end
    @test err_nlp isa ArgumentError
    @test occursin("discrete", err_nlp.msg)

    # All three stud fields unset: the named default stud, not an error.
    dflt = composite_anchor_from_options(SteelBeamOptions(composite = true))
    @test isapprox(dflt.d_sa, 0.75u"inch"; rtol = 1e-9)
    @test isapprox(dflt.l_sa, 3.0u"inch"; rtol = 1e-9)
    @test isapprox(dflt.Fu, 65.0u"ksi"; rtol = 1e-9)
    @test occursin("aisc-scm-14th", dflt.source)
    @test occursin("predates AISC 360-22", dflt.source)
    dflt_deck = composite_anchor_from_options(SteelBeamOptions(composite = true,
        composite_slab_type = :deck, composite_deck_hr = 3.0u"inch",
        composite_deck_wr = 6.0u"inch"))
    @test isapprox(dflt_deck.l_sa, 4.5u"inch"; rtol = 1e-9)

    opts_ok = SteelBeamOptions(composite = true, sizing_strategy = :nlp,
                               composite_anchor_d = 0.75u"inch",
                               composite_anchor_length = 5.0u"inch",
                               composite_anchor_Fu = 65.0u"ksi")
    err_path = try
        size_beams!(bare, opts_ok; reanalyze = false)
        nothing
    catch e
        e
    end
    @test err_path isa ArgumentError
    @test occursin("discrete", err_path.msg)
    @test_throws MethodError size_beams!(bare, SteelBeamOptions(sizing_strategy = :nlp);
                                         reanalyze = false)
end

@testset "Pre-cure moment follows a uniform dead-load field" begin
    struc, ibeam, _ = _build_two_bay()
    _solve_two_bay_frame!(struc; w = 10_000.0)
    # The fixture load is the dead case: 10 kPa over a constant 1 m width.
    struc.cell_dead_loads[1] = Asap.TributaryLoad[]
    for load in struc.asap_model.loads
        load isa Asap.TributaryLoad && push!(struc.cell_dead_loads[1], load)
    end
    u = StructuralSynthesizer._dead_load_displacement(struc)
    by = StructuralSynthesizer._dead_loads_by_element(struc)
    shape = StructuralSynthesizer.beam_pre_cure_shape(struc, ibeam, u, by)
    @test shape !== nothing
    @test isapprox(ustrip(u"N/m", shape.w_ref), 10_000.0; rtol=1e-8)
    L = member_length(ibeam)
    Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
    simple_M = 10_000.0 * Lm^2 / 8
    simple_V = 10_000.0 * Lm / 2
    # A uniform load on a prismatic span cannot exceed the simple-span moment.
    # The larger end shear is at least wL/2 and at most the propped 5wL/8.
    @test 0.5 * simple_M < ustrip(u"N*m", shape.M_ref) <= simple_M * 1.001
    @test simple_V * 0.99 <= ustrip(u"N", shape.V_ref) <= (5 / 8) * 10_000.0 * Lm * 1.01

    el = struc.asap_model.elements[struc.segments[only(segment_indices(ibeam))].edge_idx]
    varied = Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 2.0u"m"], 10_000.0u"Pa")
    struc.cell_dead_loads[1] = [varied]
    @test StructuralSynthesizer.beam_pre_cure_shape(
        struc, ibeam, u, StructuralSynthesizer._dead_loads_by_element(struc)) === nothing
end

@testset "API round-trips composite beam inputs" begin
    raw = StructuralSynthesizer.APIParams(
        beam_type = "steel_w",
        composite = true,
        composite_slab_type = "deck",
        composite_t_slab_in = 4.5,
        composite_anchor_d_in = 0.75,
        composite_anchor_length_in = 5.0,
        composite_anchor_Fu_ksi = 65.0,
        composite_shored = true,
        composite_cp_class = "light",
        composite_deck_hr_in = 3.0,
        composite_deck_wr_in = 6.0,
        composite_deck_orientation = "parallel",
    )
    again = JSON3.read(JSON3.write(raw), StructuralSynthesizer.APIParams)
    opts = StructuralSynthesizer._resolve_beam_options(again)
    @test opts.composite
    @test opts.composite_slab_type === :deck
    @test opts.composite_shored
    @test opts.composite_cp_class === :light
    @test opts.composite_deck_orientation === :parallel
    @test isapprox(opts.composite_t_slab, 4.5u"inch"; rtol = 1e-6)
    @test isapprox(opts.composite_anchor_d, 0.75u"inch"; rtol = 1e-6)
    @test isapprox(opts.composite_anchor_length, 5.0u"inch"; rtol = 1e-6)
    @test isapprox(opts.composite_anchor_Fu, 65.0u"ksi"; rtol = 1e-6)
    @test isapprox(opts.composite_deck_hr, 3.0u"inch"; rtol = 1e-6)
    @test isapprox(opts.composite_deck_wr, 6.0u"inch"; rtol = 1e-6)
    schema = StructuralSynthesizer.api_input_schema()
    @test haskey(schema["params"]["fields"], "composite_anchor_d_in")
end
