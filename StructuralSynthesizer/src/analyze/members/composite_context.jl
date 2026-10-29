# =============================================================================
# Composite Context + Per-Station Check from the Building — AISC 360-16 Ch. I
# =============================================================================
#
# Bridges the building's reinforcement-axis-aware tributary geometry to the
# StructuralSizer composite checks (AISC 360-16 Chapter I). Two products:
#
#   1. `composite_context_from_beam` — a scalar `CompositeContext` (material +
#      representative geometry) for the construction-stage / scalar-fallback
#      paths, with every derived field user-overridable.
#   2. `beam_side_profiles` + `check_composite_beam` — the PER-STATION design
#      check: a §I3.1a effective width `b_eff(s)` built from the PER-SIDE
#      tributary extent profiles (stitched across ALL edges a beam spans, so
#      multi-edge / chained members are supported), combined with the EXACT FEM
#      `TributaryLoad` demand field `M(s)` and the grid-independent
#      governing-station search in StructuralSizer `per_station.jl`.
#
# Why per-side (not the summed combined profile): AISC 360-16 §I3.1a (corpus:
# aisc-360-16, PDF p. 150) caps each side independently at `L/8`; capping the
# SUM at `L/4` is unconservative when the two sides are asymmetric. The building's
# combined `beam.tributary_profile` sums the two sides, so the per-station b_eff
# is instead built from the per-side extents kept separate here.
#
# Dependency direction (Asap → StructuralSizer → StructuralSynthesizer) is
# respected: this layer only CONSUMES exported Sizer types/helpers
# (`SideExtentProfile`, `b_eff_at_station`, `governing_composite_station`,
# `get_I_LB`, the `*SlabOnBeam` / `CompositeContext` types) and the Synthesizer
# tributary/FEM accessors; no §I3.1a/§I3.2 mechanics are re-derived here.
# =============================================================================

# -----------------------------------------------------------------------------
# Per-side tributary extent profiles (multi-edge, reinforcement-axis-aware)
# -----------------------------------------------------------------------------

"""
    _edge_perside_canonical(struc, e) -> (left, right)

For global skeleton edge `e`, return the per-side tributary extent profiles of
the (≤ 2) adjacent cells, each as `(positions, extents_m)` in the edge's
CANONICAL orientation (`s = 0` at `edge_indices[e][1]`), or `nothing` for a side
with no adjacent cell (a slab edge).

Sides are split by the adjacent face's TRAVERSAL DIRECTION of the edge, not by the
sign of the tributary distance `d` (which `_extract_width_profile` stores as an
unsigned magnitude — both adjacent cells report `d > 0`). Faces are wound
consistently, so a shared interior edge is traversed in opposite directions by its
two adjacent faces: the face traversing the canonical direction (`v1 → v2`) has its
interior on the canonical LEFT, the reverse-traversing face on the canonical RIGHT.
The same traversal test also reorients each cell profile into the canonical edge
frame (mirrors `_accumulate_edge_width_profiles`).
"""
function _edge_perside_canonical(struc::BuildingStructure, e::Int)
    skel = struc.skeleton
    left = nothing
    right = nothing
    av1, av2 = skel.edge_indices[e]
    for (cell_idx, cell) in enumerate(struc.cells)
        face_edges = skel.face_edge_indices[cell.face_idx]
        local_idx = findfirst(==(e), face_edges)
        local_idx === nothing && continue

        tribs = cell_edge_tributaries(struc, cell_idx)
        tribs === nothing && continue
        idx = findfirst(t -> t.local_edge_idx == local_idx, tribs)
        idx === nothing && continue
        trib = tribs[idx]
        isempty(trib.d) && continue

        # Extract (positions, |d|) sorted along the edge in the cell-face local
        # orientation; `reversed` is true when the face traverses the edge
        # opposite to the canonical direction (`edge_indices[e] = (av1, av2)`).
        positions, extents_m = _extract_width_profile(trib)
        length(positions) < 2 && continue
        face_verts = skel.face_vertex_indices[cell.face_idx]
        n_verts = length(face_verts)
        expected_v1 = face_verts[local_idx]
        expected_v2 = face_verts[mod1(local_idx + 1, n_verts)]
        reversed = (av1 == expected_v2 && av2 == expected_v1)
        if reversed
            positions = reverse(1.0 .- positions)
            extents_m = reverse(extents_m)
        end

        # Consistent winding ⇒ a forward-traversing face lies on the canonical
        # LEFT of v1→v2, a reverse-traversing face on the canonical RIGHT.
        if reversed
            right = (positions, extents_m)
        else
            left = (positions, extents_m)
        end
    end
    return (left, right)
end

"""
    beam_side_profiles(struc, beam) -> (left, right)

Per-side tributary extent profiles for a composite `beam` as
[`SideExtentProfile`](@ref)s over the beam's normalized span `[0, 1]`, or
`nothing` for a slab-edge side. The per-cell edge tributaries are stitched across
ALL skeleton edges the beam spans (chain order, mapped onto `[0, 1]` by physical
length), so **multi-edge / chained members are supported** — no error is raised.

The left/right labelling is taken in the beam's traversal frame: an edge whose
canonical orientation disagrees with the beam direction has its side sign flipped,
so the labelling is consistent along a (collinear) chain. The labelling is
immaterial to the §I3.1a effective width, which sums the two sides.
"""
function beam_side_profiles(struc::BuildingStructure, beam::Beam)
    skel = struc.skeleton
    segs = segment_indices(beam)
    isempty(segs) && return (nothing, nothing)

    edges = [struc.segments[si].edge_idx for si in segs]
    verts = _ordered_chain_vertices(skel, edges)

    seg_len_m = Float64[]
    for si in segs
        L = struc.segments[si].L
        push!(seg_len_m, L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L))
    end
    total = sum(seg_len_m)
    total <= 0 && return (nothing, nothing)

    left_pos  = Float64[]; left_d  = Float64[]
    right_pos = Float64[]; right_d = Float64[]
    any_left = false; any_right = false
    offset = 0.0

    for k in eachindex(edges)
        e = edges[k]
        Lk = seg_len_m[k]
        perside = _edge_perside_canonical(struc, e)
        a, _ = skel.edge_indices[e]
        rev = verts[k] != a      # beam traverses the edge opposite to canonical

        # Canonical (left, right); flip labels in the beam frame when reversed.
        can_left, can_right = perside
        beam_left  = rev ? can_right : can_left
        beam_right = rev ? can_left  : can_right

        for (prof, is_left) in ((beam_left, true), (beam_right, false))
            prof === nothing && continue
            pos, d = prof
            if rev
                pos = reverse(1.0 .- pos)
                d = reverse(d)
            end
            pos, d = _span_unit_interval(pos, d)
            dst_pos = is_left ? left_pos : right_pos
            dst_d   = is_left ? left_d   : right_d
            for j in eachindex(pos)
                push!(dst_pos, (offset + pos[j] * Lk) / total)
                push!(dst_d, d[j])
            end
            is_left ? (any_left = true) : (any_right = true)
        end
        offset += Lk
    end

    left  = any_left  ? _finalize_side_profile(left_pos, left_d)   : nothing
    right = any_right ? _finalize_side_profile(right_pos, right_d) : nothing
    return (left, right)
end

"""Clamp a stitched `(positions, extents)` list to `[0, 1]`, enforce monotonic
positions, and wrap as a [`SideExtentProfile`](@ref)."""
function _finalize_side_profile(pos::Vector{Float64}, d::Vector{Float64})
    isempty(pos) && return nothing
    pos = copy(pos); d = copy(d)
    pos[1] = 0.0
    pos[end] = 1.0
    for i in 2:length(pos)
        pos[i] < pos[i - 1] && (pos[i] = pos[i - 1])
    end
    return SideExtentProfile(pos, d)
end

"""Mean per-side extent `∫₀¹ d(s) ds` (m) of a [`SideExtentProfile`](@ref) —
the representative distance used for the scalar `CompositeContext` fallback (NOT
the governing per-station value)."""
function _mean_extent_m(p::SideExtentProfile)
    pos, d = p.positions, p.extents_m
    total = 0.0
    @inbounds for i in 1:(length(pos) - 1)
        total += (d[i] + d[i + 1]) * 0.5 * (pos[i + 1] - pos[i])
    end
    return total
end

# -----------------------------------------------------------------------------
# Scalar CompositeContext from the building (material + representative geometry)
# -----------------------------------------------------------------------------

"""
    composite_context_from_beam(struc, beam; t_slab, fc′, Ec, wc, Es, anchor,
        deck=nothing, L_beam=nothing,
        beam_spacing_left=nothing, beam_spacing_right=nothing,
        edge_dist_left=:building, edge_dist_right=:building,
        slab=nothing, shored=false, Lb_const=nothing,
        Asr=0.0u"mm²", Fysr=0.0u"MPa", neg_moment=false) -> CompositeContext

Build a scalar `CompositeContext` (StructuralSizer, AISC 360-16 Chapter I) for a
composite steel `beam`. The slab material is taken from the arguments; the
representative per-side spacing is derived from the building's PER-SIDE tributary
extent profiles ([`beam_side_profiles`](@ref), multi-edge). Every derived field
is user-overridable.

# Building-derived defaults (representative scalar)
For each side the representative half-distance is the MEAN per-side tributary
extent `d̄ = ∫₀¹ d(s) ds`, mapped to §I3.1a inputs as `beam_spacing_side = 2·d̄`
(interior side) or `edge_dist_side = 0` (slab-edge side — no adjacent cell). This
scalar context drives the construction-stage check and the scalar `get_b_eff`
fallback; the governing composite strength uses the per-station `b_eff(s)` (see
[`check_composite_beam`](@ref)), which reduces to this scalar on a regular grid.

The MEAN (not a moment-weighted) extent is used deliberately as a neutral
representative — the moment-weighted collapse is NOT applied to the §I3.1a width.

# Overrides
`L_beam` (⇒ `member_length`), `beam_spacing_left/right` (`nothing` ⇒ derived),
`edge_dist_left/right` (sentinel `:building` ⇒ derived; `nothing` forces an
interior side; a length pins a slab-edge distance), `slab` (a prebuilt
`AbstractSlabOnBeam` bypasses all derivation), and the `CompositeContext`
passthroughs `shored` / `Lb_const` / `Asr` / `Fysr` / `neg_moment`.
"""
function composite_context_from_beam(
    struc::BuildingStructure, beam::Beam;
    t_slab, fc′, Ec, wc, Es, anchor,
    deck = nothing,
    L_beam = nothing,
    beam_spacing_left = nothing, beam_spacing_right = nothing,
    edge_dist_left = :building, edge_dist_right = :building,
    slab = nothing,
    shored::Bool = false, Lb_const = nothing,
    Asr = 0.0u"mm^2", Fysr = 0.0u"MPa", neg_moment::Bool = false,
    ΣQn_neg = nothing,
    L_twist = nothing,
)
    # --- Span (c-to-c); building default = member length ---------------------
    L = isnothing(L_beam) ? member_length(beam) : L_beam
    L = L isa Unitful.Quantity ? L : L * u"m"

    # --- Full-slab override: skip all slab-field derivation ------------------
    if !isnothing(slab)
        return CompositeContext(slab, anchor, L; shored = shored, Lb_const = Lb_const,
                                Asr = Asr, Fysr = Fysr, neg_moment = neg_moment,
                                ΣQn_neg = ΣQn_neg, L_twist = L_twist)
    end

    # --- Per-side representative extents (building default) -------------------
    prof_left, prof_right = beam_side_profiles(struc, beam)
    d_left  = isnothing(prof_left)  ? nothing : _mean_extent_m(prof_left)  * u"m"
    d_right = isnothing(prof_right) ? nothing : _mean_extent_m(prof_right) * u"m"

    # Map d̄ → §I3.1a(b)/(c) slab inputs: interior → beam_spacing = 2·d̄, no edge;
    # slab-edge side → edge_dist = 0 (that side contributes zero effective width).
    derived_bsl = isnothing(d_left)  ? 0.0u"m" : 2 * d_left
    derived_bsr = isnothing(d_right) ? 0.0u"m" : 2 * d_right
    derived_edl = isnothing(d_left)  ? 0.0u"m" : nothing
    derived_edr = isnothing(d_right) ? 0.0u"m" : nothing

    # --- Apply overrides (explicit value beats the building default) ---------
    bsl = isnothing(beam_spacing_left)  ? derived_bsl : beam_spacing_left
    bsr = isnothing(beam_spacing_right) ? derived_bsr : beam_spacing_right
    edl = edge_dist_left  === :building ? derived_edl : edge_dist_left
    edr = edge_dist_right === :building ? derived_edr : edge_dist_right

    # --- Build the slab-on-beam config ---------------------------------------
    slab_built = if isnothing(deck)
        SolidSlabOnBeam(t_slab, fc′, Ec, wc, Es, bsl, bsr;
                        edge_dist_left = edl, edge_dist_right = edr)
    else
        θ = get(deck, :rib_angle, nothing)
        if deck.orientation === :from_slab
            θ = beam_rib_angle(struc, beam)
        end
        orient = θ === nothing ? deck.orientation : StructuralSizer.rib_orientation(θ)
        DeckSlabOnBeam(t_slab, fc′, Ec, wc, Es, deck.hr, deck.wr, orient,
                       bsl, bsr; edge_dist_left = edl, edge_dist_right = edr,
                       e_mid_ht = get(deck, :e_mid_ht, nothing),
                       anchorage_spacing = get(deck, :anchorage_spacing, nothing),
                       rib_angle = θ, rib_pitch = get(deck, :rib_pitch, nothing))
    end

    return CompositeContext(slab_built, anchor, L; shored = shored, Lb_const = Lb_const,
                            Asr = Asr, Fysr = Fysr, neg_moment = neg_moment,
                            ΣQn_neg = ΣQn_neg, L_twist = L_twist)
end

# -----------------------------------------------------------------------------
# Exact FEM demand field M(s) (reuse of the TributaryLoad internal-force field)
# -----------------------------------------------------------------------------

"""
    _element_signed_moment_at(el, loads, x_m) -> Float64

Signed strong-axis internal moment `My` (N·m) of Asap frame element `el` at local
abscissa `x_m` (m), from the CURRENT solved displacements (`el.nodeStart/.nodeEnd`
displacements baked into `el`) plus the exact closed-form `TributaryLoad`
contribution. Mirrors `Asap.ElementForceAndDisplacement`'s force path
(`Flocal = R·K·u_global`, then `accumulate_force!`) evaluated at the single
station `x_m`, so there is NO grid sampling and NO new demand machinery.
"""
function _element_signed_moment_at(el, loads, x_m::Float64)
    dofs = Asap.etype2DOF[typeof(el)]
    ep = Asap.ElementProps(el)
    ug = Vector{Float64}(undef, 12)
    Asap._fill_uglobal!(ug, el)
    Flocal = el.R * (el.K * ug)
    @inbounds for i in 1:12
        Flocal[i] *= dofs[i]
    end
    Vystart = Flocal[2]
    Mystart = Flocal[6]

    xs = Float64[x_m]
    P  = Float64[0.0]
    My = Float64[Vystart * x_m - Mystart]
    Vy = Float64[Vystart]
    Mz = Float64[0.0]
    Vz = Float64[0.0]
    for load in loads
        Asap.accumulate_force!(load, xs, P, My, Vy, Mz, Vz, ep)
    end
    return My[1]
end

# -----------------------------------------------------------------------------
# Interior supports of a chained beam (§I3.1a span, center-to-center of supports)
# -----------------------------------------------------------------------------

"""
    beam_support_lookup(struc) -> NamedTuple

Vertices that can support a beam, built once per structure for
[`beam_interior_supports`](@ref): `fixed` holds vertices where a column or
wall edge ends, or that are in the `:support` group. `through` counts, per
vertex, the beams that pass through it (the vertex is interior to the beam's
chain).
"""
function beam_support_lookup(struc::BuildingStructure)
    skel = struc.skeleton
    fixed = Set{Int}(get(skel.groups_vertices, :support, Int[]))
    for grp in (:columns, :walls)
        for e in get(skel.groups_edges, grp, Int[])
            a, b = skel.edge_indices[e]
            push!(fixed, a, b)
        end
    end
    through = Dict{Int, Int}()
    for beam in struc.beams
        verts = _beam_chain_vertices(struc, beam)
        for v in @view verts[2:end-1]
            through[v] = get(through, v, 0) + 1
        end
    end
    return (; fixed, through)
end

"""Ordered skeleton vertices along `beam`, matching `segment_indices(beam)`."""
function _beam_chain_vertices(struc::BuildingStructure, beam::Beam)
    edges = [struc.segments[si].edge_idx for si in segment_indices(beam)]
    return _ordered_chain_vertices(struc.skeleton, edges)
end

"""
    beam_interior_supports(struc, beam; lookup=beam_support_lookup(struc)) -> Vector{Float64}

Fractions of the beam length at its interior supports. A beam drawn as one
line across several bays is one member; AISC 360-22 §I3.1a(a) (corpus:
aisc-360-22, PDF p. 168) measures `L/8` on "the beam span, center-to-center
of supports", so each bay needs its own span.

# ENGINEERING JUDGMENT
An interior chain vertex is a support when a column, a wall, or a `:support`
vertex is there, or when another beam passes straight through it. A beam that
only ends on this one is carried by it and is not a support. Where two
continuous beams cross, each counts the other as a support; more supports
give shorter spans and smaller effective widths.
"""
function beam_interior_supports(struc::BuildingStructure, beam::Beam;
                                lookup = beam_support_lookup(struc))
    verts = _beam_chain_vertices(struc, beam)
    length(verts) <= 2 && return Float64[]
    skel = struc.skeleton
    xyz(v) = (c = Meshes.coords(skel.vertices[v]);
              (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z)))
    cum = zeros(length(verts))
    for k in 2:length(verts)
        a, b = xyz(verts[k - 1]), xyz(verts[k])
        cum[k] = cum[k - 1] + sqrt(sum(abs2, a .- b))
    end
    total = cum[end]
    out = Float64[]
    for k in 2:(length(verts) - 1)
        v = verts[k]
        # This beam counts itself once in `through`.
        if v in lookup.fixed || get(lookup.through, v, 0) >= 2
            push!(out, cum[k] / total)
        end
    end
    return out
end

"""
    beam_signed_moment_field(struc, beam) -> (M_of_s, breakpoints)

Return a callable `M_of_s(s) -> Moment` giving the EXACT, continuity-correct
signed demand moment at normalized station `s ∈ [0, 1]` along `beam` (SAGGING
POSITIVE, hogging negative), plus the `breakpoints` where the field's segment
structure changes (element boundaries and `TributaryLoad` width breakpoints).

The sign is physical sagging-positive, obtained with the same `ly_z` convention
as `_asap_signed_My_envelopes`. The model must already be solved (call
`to_asap!` + `solve!` / the sizing pipeline first). Reuses the Asap internal-force
recovery exactly — no Riemann sampling, no new demand path.
"""
function beam_signed_moment_field(struc::BuildingStructure, beam::Beam)
    segs = segment_indices(beam)
    isempty(segs) && throw(ArgumentError("beam has no segments"))

    # Per-segment element, loads, physical length, and sagging-sign.
    els = Any[]; loads_per = Any[]; len_m = Float64[]; sag_sign = Float64[]
    element_loads = Asap.get_elemental_loads(struc.asap_model)
    for si in segs
        seg = struc.segments[si]
        el = struc.asap_model.elements[seg.edge_idx]
        push!(els, el)
        push!(loads_per, element_loads[el.elementID])
        # The element's own length: the force recovery asserts 0 ≤ x ≤ that length,
        # and the segment's stored length can differ from it.
        push!(len_m, Float64(Asap.ElementProps(el).L))
        ly_z = el.LCS[2][3]
        push!(sag_sign, ly_z >= 0 ? 1.0 : -1.0)   # map My → sagging-positive
    end
    total = sum(len_m)

    # Cumulative normalized breakpoints at element boundaries.
    cum = cumsum(len_m)
    bps = Float64[0.0]
    for c in cum
        push!(bps, c / total)
    end
    bps = unique!(clamp.(bps, 0.0, 1.0))

    function M_of_s(s::Real)
        sc = clamp(Float64(s), 0.0, 1.0)
        x_global = sc * total
        # Locate the element and local abscissa.
        acc = 0.0
        k = 1
        while k < length(len_m) && x_global > acc + len_m[k]
            acc += len_m[k]; k += 1
        end
        x_local = clamp(x_global - acc, 0.0, len_m[k])
        My = _element_signed_moment_at(els[k], loads_per[k], x_local)
        return (My * sag_sign[k]) * u"N*m"
    end

    return (M_of_s, bps)
end

# -----------------------------------------------------------------------------
# Per-station composite design check (strength + continuity + FEM deflection)
# -----------------------------------------------------------------------------

"""
    check_composite_beam(struc, beam, section, material, ctx; ΣQn,
        Asr=ctx.Asr, Fysr=ctx.Fysr, d_rebar=0.0u"m", ϕ=0.9,
        w_DL=nothing, w_LL=nothing, δ_LL=nothing) -> NamedTuple

Per-station composite flexural check for `beam` per AISC 360-16 §I3.1a / §I3.2a /
§I3.2b, combining:
  • the per-side §I3.1a effective width `b_eff(s)` from [`beam_side_profiles`];
  • the exact FEM demand field `M(s)` from [`beam_signed_moment_field`];
  • the grid-independent governing-station search (`governing_composite_station`).

`ΣQn` is the available shear transfer at the governing section (v1: one scalar
value with a continuity-ready interface — full per-station stud/shear-flow
accumulation is DEFERRED). Returns the governing record (`s_star`, `dcr_max`,
`b_eff`, `ϕMn`, `Mn`, `sense`, `M`) plus `I_LB`, `I_neg`, and `I_service`.

`I_LB` is the positive-moment lower-bound inertia at the peak sagging station.
`I_service` is the constant stiffness used to scale the steel-model deflection
([`composite_deflection_scale`](@ref)).
"""
function check_composite_beam(struc::BuildingStructure, beam::Beam, section, material,
                              ctx::CompositeContext; ΣQn,
                              Asr = ctx.Asr, Fysr = ctx.Fysr,
                              d_rebar = 0.0u"m", ϕ = 0.9)
    left, right = beam_side_profiles(struc, beam)
    M_of_s, demand_bps = beam_signed_moment_field(struc, beam)
    supports = beam_interior_supports(struc, beam)

    g = governing_composite_station(section, material, ctx.slab, ctx.L_beam,
                                    M_of_s, ΣQn; left = left, right = right,
                                    Asr = Asr, Fysr = Fysr, d_rebar = d_rebar, ϕ = ϕ,
                                    neg_moment = ctx.neg_moment,
                                    extra_breakpoints = demand_bps,
                                    supports = supports)

    # I_pos at the peak sagging station. A hogging governing station is not
    # the positive-moment section Eq. C-I3-5 names. A very large steel φMn
    # makes the sagging search follow M⁺, because φMn is then constant.
    sag = governing_sagging_station(section, material, ctx.slab, ctx.L_beam,
                                    M_of_s, 1.0e30;
                                    left = left, right = right,
                                    extra_breakpoints = demand_bps,
                                    supports = supports)
    I_pos = sag.M_pos > 0 ?
        get_I_LB(section, material, ctx.slab, sag.b_eff, ΣQn) : section.Ix
    # AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502):
    # I = 0.6 I_pos + 0.4 I_neg for a continuous beam under gravity.
    # A beam with no negative moment keeps I_pos. I_neg is the cracked steel +
    # developed-bar section when the negative region is composite, else Ix
    # (ENGINEERING JUDGMENT, see get_I_cracked_negative).
    continuous = StructuralSizer.moment_field_has_negative(M_of_s)
    I_neg = ctx.neg_moment ?
        get_I_cracked_negative(section, Asr; d_rebar = d_rebar) : section.Ix
    I_service = composite_service_inertia(I_pos, I_neg; continuous = continuous)
    return (; g..., I_LB = I_pos, I_neg = I_neg, I_service = I_service,
              left = left, right = right)
end

"""
    composite_deflection_scale(section, I_service) -> Float64

Multiplier that converts a bare-steel FEM deflection into the deflection of
the commentary's constant composite stiffness:
`δ_composite = δ_steel · (Ix / I_service)`.

`I_service` is `I_LB` when the moment does not change sign. For a continuous
beam it is AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502),
`0.6 I_pos + 0.4 I_neg`, from [`check_composite_beam`](@ref). The analysis
model carries the steel section, so one ratio applies that inertia to the
whole member. The commentary specifies this constant stiffness for the
elastic analysis.
"""
composite_deflection_scale(section, I_service) = ustrip(section.Ix / I_service)

# -----------------------------------------------------------------------------
# Production payload for size_beams! (one PerStationComposite per group)
# -----------------------------------------------------------------------------

"""
Stud from the beam options. AISC 360-22 Eq. I8-1 uses `Fu`, not the stud yield
strength (corpus: aisc-360-22, PDF p. 181). `Fy` is stored as zero so it is
not a stand-in grade. Density is the stud steel density used only for weight.

With all three stud fields unset, the stud is
[`StructuralSizer.default_headed_stud`](@ref), whose `source` names the
AISC Manual 14th ed. and the edition gap. A partly named stud throws.
"""
function composite_anchor_from_options(opts)
    if opts.composite_anchor_d === nothing && opts.composite_anchor_length === nothing &&
            opts.composite_anchor_Fu === nothing
        hr = opts.composite_slab_type === :deck ? composite_deck_hr_wr(opts).hr : nothing
        return StructuralSizer.default_headed_stud(; hr = hr)
    end
    opts.composite_anchor_d === nothing && throw(ArgumentError(
        "Composite beam design needs the stud diameter (composite_anchor_d)."))
    opts.composite_anchor_length === nothing && throw(ArgumentError(
        "Composite beam design needs the stud length (composite_anchor_length)."))
    opts.composite_anchor_Fu === nothing && throw(ArgumentError(
        "Composite beam design needs the stud tensile strength (composite_anchor_Fu)."))
    HeadedStudAnchor(opts.composite_anchor_d, opts.composite_anchor_length,
                     opts.composite_anchor_Fu, 0.0u"ksi", 490.0u"lb/ft^3")
end

"""
    composite_deck_hr_wr(opts) -> (hr, wr)

Rib height and average rib width for composite deck. With
`composite_deck_profile` set they come from the Vulcraft catalog
([`StructuralSizer.composite_deck_profile`](@ref)); an explicit
`composite_deck_hr` or `composite_deck_wr` that differs from the profile by
more than 1/32 in. throws. Without a profile the explicit values are returned
as given (possibly `nothing`).
"""
function composite_deck_hr_wr(opts)
    name = opts.composite_deck_profile
    name === nothing && return (hr = opts.composite_deck_hr, wr = opts.composite_deck_wr)
    prof = StructuralSizer.composite_deck_profile(name)
    hr, wr = prof.hr, StructuralSizer.deck_wr(prof)
    tol = (1 / 32) * u"inch"
    for (lbl, given, cat) in (("composite_deck_hr", opts.composite_deck_hr, hr),
                              ("composite_deck_wr", opts.composite_deck_wr, wr))
        given === nothing && continue
        abs(uconvert(u"m", given) - cat) <= tol || throw(ArgumentError(
            "$lbl = $given does not match deck profile $(prof.name) " *
            "($(round(u"inch", cat; digits=3)), $(prof.source))."))
    end
    return (hr = hr, wr = wr)
end

"""
    composite_deck_pitch(opts) -> Length or nothing

Rib pitch from `composite_deck_profile`, or `composite_deck_pitch` when no
profile is named. An explicit pitch that differs from the profile by more
than 1/32 in. throws.
"""
function composite_deck_pitch(opts)
    given = opts.composite_deck_pitch
    name = opts.composite_deck_profile
    name === nothing && return given === nothing ? nothing : uconvert(u"m", given)
    prof = StructuralSizer.composite_deck_profile(name)
    if given !== nothing && abs(uconvert(u"m", given) - prof.pitch) > (1 / 32) * u"inch"
        throw(ArgumentError(
            "composite_deck_pitch = $given does not match deck profile $(prof.name) " *
            "($(round(u"inch", prof.pitch; digits=3)), $(prof.source))."))
    end
    return prof.pitch
end

"""
    beam_rib_angle(struc, beam) -> Float64

Angle in radians, in `[0, π/2]`, between `beam` and the deck ribs of the slabs
it bears on. The ribs run along each slab's span axis (`slab.spans.axis`); the
beam direction runs from its first to its last chain vertex in plan.

With slabs at different angles on one beam, the result is the smallest angle
among the slabs that are not parallel to the beam, or `0` when every slab is
parallel. That pairs the perpendicular `Rg`/`Rp` with the sparsest rib
crossings, the lower bound over the decks that may sit on the flange.

Throws when the beam bears on no slab or has no plan length.
"""
function beam_rib_angle(struc::BuildingStructure, beam)
    skel = struc.skeleton
    edges = [struc.segments[si].edge_idx for si in segment_indices(beam)]
    isempty(edges) && throw(ArgumentError("Beam has no segments."))
    verts = _ordered_chain_vertices(skel, edges)
    a = _vertex_xy_m(skel, first(verts))
    b = _vertex_xy_m(skel, last(verts))
    dir = (b[1] - a[1], b[2] - a[2])
    hypot(dir...) > 1e-9 || throw(ArgumentError(
        "Beam has no plan length, so its deck rib angle is undefined."))
    slabs = _slabs_on_beam(struc, beam)
    isempty(slabs) && throw(ArgumentError(
        "composite_deck_orientation = :from_slab needs a slab on the beam to read " *
        "the deck span axis. Set :perpendicular or :parallel to assert it."))
    θ_skew = Inf
    for slab in slabs
        θ = StructuralSizer.rib_angle_between(slab.spans.axis, dir)
        StructuralSizer.rib_orientation(θ) === :parallel && continue
        θ_skew = min(θ_skew, θ)
    end
    return isfinite(θ_skew) ? θ_skew : 0.0
end

"""
Deck fastening recorded on a deck beam, or `:auto` for a solid slab.

A deck with no pattern given gets the 36/4 default. `Sn` has no default.
"""
function deck_attachment_from_options(opts)
    opts.composite_slab_type === :deck || return :auto
    pattern = opts.composite_deck_support_pattern
    StructuralSizer.DeckAttachment(;
        support_pattern = pattern === nothing ?
            StructuralSizer.DEFAULT_DECK_SUPPORT_PATTERN : pattern,
        sidelap_per_span = opts.composite_deck_sidelap_per_span,
        Sn = opts.composite_diaphragm_Sn)
end

"""Keyword bundle `size!` and `design_building` pass into `size_beams!`."""
function composite_option_kwargs(opts)
    opts isa StructuralSizer.SteelBeamOptions && opts.composite || return (;)
    return (;
        composite_anchor = composite_anchor_from_options(opts),
        composite_t_slab = opts.composite_t_slab,
        composite_shored = opts.composite_shored,
        composite_cp_class = opts.composite_cp_class,
        composite_slab_type = opts.composite_slab_type,
        composite_deck_hr = composite_deck_hr_wr(opts).hr,
        composite_deck_wr = composite_deck_hr_wr(opts).wr,
        composite_deck_orientation = opts.composite_deck_orientation,
    )
end

"""Slabs whose cells share an edge with `beam`."""
function _slabs_on_beam(struc::BuildingStructure, beam)
    skel = struc.skeleton
    edge_set = Set{Int}()
    for si in segment_indices(beam)
        push!(edge_set, struc.segments[si].edge_idx)
    end
    out = Any[]
    for slab in struc.slabs
        hits = false
        for cell_idx in slab.cell_indices
            face_idx = struc.cells[cell_idx].face_idx
            if any(e -> e in edge_set, skel.face_edge_indices[face_idx])
                hits = true
                break
            end
        end
        hits && push!(out, slab)
    end
    return out
end

"""
Solid thickness of a sized slab, in meters.

A vault's total depth is shell thickness plus rise. A shaped slab stores
volume per area. Neither is the solid thickness `t` in `Ac = b_eff · t`.
"""
function _solid_slab_thickness(result)
    if result isa StructuralSizer.VaultResult
        throw(ArgumentError(
            "A vault is not a solid slab thickness for a composite beam. " *
            "Its total depth is the shell thickness plus the rise."))
    end
    if result isa StructuralSizer.ShapedSlabResult
        throw(ArgumentError(
            "A shaped slab has no single solid thickness for a composite beam. " *
            "Volume per area is not a thickness."))
    end
    # Concrete above the deck: the `t_slab` of `DeckSlabOnBeam`.
    result isa StructuralSizer.CompositeDeckResult && return uconvert(u"m", result.fill_depth)
    hasproperty(result, :thickness) || throw(ArgumentError(
        "Slab result $(typeof(result)) has no solid thickness for a composite beam."))
    t = result.thickness
    return t isa Unitful.Quantity ? uconvert(u"m", t) : t * u"m"
end

"""
Deck profile of the sized composite deck floor a beam bears on, or `nothing`
when it bears on no deck floor. A beam between a deck floor and another slab
type, or between two different profiles, throws: one `DeckSlabOnBeam` cannot
represent both sides.
"""
function _beam_floor_deck(struc::BuildingStructure, beam)
    slabs = _slabs_on_beam(struc, beam)
    decks = [s.result for s in slabs if s.result isa StructuralSizer.CompositeDeckResult]
    isempty(decks) && return nothing
    length(decks) == length(slabs) || throw(ArgumentError(
        "A beam bears on a composite deck floor and on another slab type. " *
        "Mixed slab types on one beam are not modeled."))
    names = unique(d.deck_profile for d in decks)
    length(names) == 1 || throw(ArgumentError(
        "A beam bears on deck floors of different profiles ($(join(names, ", ")))."))
    return StructuralSizer.composite_deck_profile(only(names))
end

"""
`(hr, wr, pitch)` of a deck floor profile. Beam-option values that are set
must match the profile within 1/32 in.
"""
function _floor_deck_geometry(prof, deck_hr, deck_wr, deck_pitch)
    tol = (1 / 32) * u"inch"
    hr, wr, pitch = prof.hr, StructuralSizer.deck_wr(prof), prof.pitch
    for (lbl, given, cat) in (("composite_deck_hr", deck_hr, hr),
                              ("composite_deck_wr", deck_wr, wr),
                              ("composite_deck_pitch", deck_pitch, pitch))
        given === nothing && continue
        abs(uconvert(u"m", given) - cat) <= tol || throw(ArgumentError(
            "$lbl = $given does not match the deck floor profile $(prof.name) " *
            "($(round(u"inch", cat; digits=3)))."))
    end
    return (hr, wr, pitch)
end

"""The `Concrete` stored on a slab's volume map, or `nothing`."""
function _concrete_of_slab(slab)
    found = nothing
    for mat in keys(slab.volumes)
        mat isa StructuralSizer.Concrete || continue
        if found !== nothing
            throw(ArgumentError(
                "A slab's volume map lists more than one concrete. " *
                "Composite beam design needs the one concrete the beam bears on."))
        end
        found = mat
    end
    return found
end

"""
Thickness and concrete for one beam.

Each adjacent solid slab contributes its own thickness and, when the volume
map records one, its own concrete. Several slabs on one beam: the thinnest
governs, and equal thicknesses take the lower `f′c`. That pairing is
engineering judgment. It keeps one beam from being designed for a neighbor's
thinner slab, which is what a group-wide minimum did.

`fallback_t` and `fallback_concrete` apply only when this beam has no adjacent
sized slab, or when a slab's volume map does not name a concrete.
"""
function _beam_slab_inputs(struc::BuildingStructure, beam, fallback_t, fallback_concrete)
    slabs = _slabs_on_beam(struc, beam)
    best = nothing
    for slab in slabs
        t = _solid_slab_thickness(slab.result)
        conc = _concrete_of_slab(slab)
        conc === nothing && (conc = fallback_concrete)
        conc === nothing && throw(ArgumentError(
            "Composite beam design needs the concrete of the slab this beam bears on."))
        fc = ustrip(u"Pa", conc.fc′)
        tm = ustrip(u"m", t)
        if best === nothing || tm < best.tm - 1e-9 ||
                (abs(tm - best.tm) <= 1e-9 && fc < best.fc)
            best = (t = t, conc = conc, tm = tm, fc = fc)
        end
    end
    if best === nothing
        fallback_t === nothing && throw(ArgumentError(
            "Composite beam design needs a slab thickness. Size the slab this " *
            "beam bears on, or pass composite_t_slab=."))
        fallback_concrete === nothing && throw(ArgumentError(
            "Composite beam design needs the slab concrete (fc′, E, density)."))
        t = fallback_t isa Unitful.Quantity ? uconvert(u"m", fallback_t) : fallback_t * u"m"
        return (t, fallback_concrete)
    end
    return (best.t, best.conc)
end

_as_length(L) = L isa Unitful.Quantity ? uconvert(u"m", L) : L * u"m"

"""
Uniform line load of tributary loads, or `nothing` when the width varies.

A varying width is not the layout of the construction line load, so the
pre-cure moment must not be scaled from it.
"""
function _uniform_tributary_line_load(loads)
    isempty(loads) && return nothing
    w = 0.0
    for load in loads
        load isa Asap.TributaryLoad || return nothing
        widths = load._widths_m
        w0 = widths[1]
        for wi in widths
            isapprox(wi, w0; rtol=1e-5, atol=1e-8) || return nothing
        end
        w += load._pressure_Pa * w0
    end
    w > 0 || return nothing
    return w
end

"""Dead-load displacement vector, or `nothing` when the model has no dead case."""
function _dead_load_displacement(struc::BuildingStructure)
    loads = Asap.AbstractLoad[]
    for v in values(struc.cell_dead_loads)
        append!(loads, v)
    end
    isempty(loads) && return nothing
    model = struc.asap_model
    isempty(model.elements) && return nothing
    return Asap.solve(model, [loads])[1]
end

function _dead_loads_by_element(struc::BuildingStructure)
    by = Dict{Int, Vector{Asap.AbstractLoad}}()
    for loads in values(struc.cell_dead_loads)
        for load in loads
            id = load.element.elementID
            push!(get!(() -> Asap.AbstractLoad[], by, id), load)
        end
    end
    return by
end

"""
    beam_pre_cure_shape(struc, beam, u_dead, by_element) -> PreCureShape or nothing

Extrema of absolute strong-axis moment and shear on `beam` from the dead-load
displacement `u_dead`, plus the uniform line load that produced them.

Returns `nothing` when any segment is unloaded or the line load changes along
the beam. The construction check then keeps the simple-span statics.
"""
function beam_pre_cure_shape(struc::BuildingStructure, beam::Beam, u_dead, by_element)
    w_beam = nothing
    M = 0.0
    V = 0.0
    n = 0
    for si in segment_indices(beam)
        seg = struc.segments[si]
        el = struc.asap_model.elements[seg.edge_idx]
        loads = get(by_element, el.elementID, Asap.AbstractLoad[])
        w_el = _uniform_tributary_line_load(loads)
        w_el === nothing && return nothing
        if w_beam === nothing
            w_beam = w_el
        elseif !isapprox(w_beam, w_el; rtol=1e-5, atol=1e-6)
            return nothing
        end
        f = _element_forces_from_u(el, u_dead, loads; resolution=40)
        M = max(M, mapreduce(abs, max, f.My))
        V = max(V, mapreduce(abs, max, f.Vy))
        n += 1
    end
    n == 0 && return nothing
    return (M_ref = M * u"N*m", V_ref = V * u"N", w_ref = w_beam * u"N/m")
end

"""
    composite_group_payload(struc, beams, L_beam, concrete, t_slab, Es;
        anchor, shored=false, Lb_const=nothing,
        Asr=0.0u"mm^2", Fysr=0.0u"MPa", neg_moment=false,
        cp_class=:medium, slab_type=:solid,
        deck_hr=nothing, deck_wr=nothing, deck_orientation=:from_slab,
        deck_pitch=nothing) -> PerStationComposite

One [`PerStationComposite`](@ref) for a beam group. Each beam keeps its own
center-to-center span (AISC 360-22 §I3.1, the `L/8` cap; corpus: aisc-360-22,
PDF p. 168) and the solid slab it bears on. `L_beam` is only the context span
used when a field has no length of its own. Passing the sum of the group is
safe: the checker reads each field's span, and the default construction
unbraced length follows that span.

`anchor` is required here. `composite_anchor_from_options` supplies the
named default stud when the options leave every stud field unset.

`t_slab`, when given, is the thickness for every beam. When it is `nothing`,
each beam uses its own adjacent solid slab. Concrete comes from that slab's
volume map when the map names one concrete; otherwise from `concrete`.

`slab_type = :deck` builds a `DeckSlabOnBeam` and requires `deck_hr` and
`deck_wr`. A beam bearing on a sized composite deck floor is always a deck
beam: rib height, rib width, and pitch come from the floor's profile, the
topping from its `fill_depth`, and any of `deck_hr`, `deck_wr`, `deck_pitch`
that is set must match. `deck_e_mid_ht`, `deck_anchorage_spacing`, and
`deck_pitch` are optional. The §I3.2c deck limits are applied by the stud design in the checker.
`deck_orientation = :from_slab` gives each beam its own rib angle from
[`beam_rib_angle`](@ref); `:perpendicular` or `:parallel` applies to every beam.
`L_twist` is the optional twist-restraint spacing for the hogging check.

`Asr` stays caller-supplied. `neg_moment` defaults to false, so hogging uses
Chapter F until developed slab reinforcement and negative-region anchors are
provided (AISC 360-22 §I3.2b).
"""
function composite_group_payload(
    struc::BuildingStructure, beams, L_beam, concrete, t_slab, Es;
    anchor = nothing,
    shored::Bool = false,
    Lb_const = nothing,
    Asr = 0.0u"mm^2",
    Fysr = 0.0u"MPa",
    neg_moment::Bool = false,
    ΣQn_neg = nothing,
    cp_class::Symbol = :medium,
    slab_type::Symbol = :solid,
    deck_hr = nothing,
    deck_wr = nothing,
    deck_orientation::Symbol = :from_slab,
    deck_e_mid_ht = nothing,
    deck_anchorage_spacing = nothing,
    deck_pitch = nothing,
    L_twist = nothing,
    deck_attachment = :auto,
)
    anchor === nothing && throw(ArgumentError(
        "Composite beam design needs the stud anchor diameter (composite_anchor_d), " *
        "length (composite_anchor_length), and Fu (composite_anchor_Fu)."))
    slab_type in (:solid, :deck) || throw(ArgumentError(
        "composite_slab_type must be :solid or :deck, got :$slab_type."))
    deck_orientation in (:from_slab, :perpendicular, :parallel) || throw(ArgumentError(
        "composite_deck_orientation must be :from_slab, :perpendicular, or :parallel, " *
        "got :$deck_orientation."))
    L = _as_length(L_beam)
    # One dead-load solve for the group. A beam whose dead load is not a
    # uniform line load keeps `pre_cure = nothing` and the simple-span check.
    u_dead = _dead_load_displacement(struc)
    by_element = u_dead === nothing ? nothing : _dead_loads_by_element(struc)
    supports_lookup = beam_support_lookup(struc)
    fields = map(beams) do beam
        t_i, conc_i = _beam_slab_inputs(struc, beam,
                                        t_slab === nothing ? nothing : t_slab,
                                        concrete)
        # An explicit thickness overrides the sized slab. The concrete still
        # comes from the slab the beam bears on.
        if t_slab !== nothing
            t_i = _as_length(t_slab)
        end
        # A sized deck floor sets the rib geometry; the options must agree with it.
        floor_deck = _beam_floor_deck(struc, beam)
        # Zero spacing: a side with no profile contributes no width. Real sides
        # come from the profiles, and the checker restuffs spacing at the station.
        slab_i = if floor_deck !== nothing || slab_type === :deck
            hr_i, wr_i, pitch_i = floor_deck === nothing ? (deck_hr, deck_wr, deck_pitch) :
                _floor_deck_geometry(floor_deck, deck_hr, deck_wr, deck_pitch)
            hr_i === nothing && throw(ArgumentError(
                "Composite beam design needs the deck rib height (composite_deck_hr)."))
            wr_i === nothing && throw(ArgumentError(
                "Composite beam design needs the deck rib width (composite_deck_wr)."))
            θ = deck_orientation === :from_slab ? beam_rib_angle(struc, beam) :
                deck_orientation === :parallel ? 0.0 : π / 2
            DeckSlabOnBeam(t_i, conc_i.fc′, conc_i.E, conc_i.ρ, Es,
                           hr_i, wr_i, StructuralSizer.rib_orientation(θ),
                           0.0u"m", 0.0u"m";
                           e_mid_ht = deck_e_mid_ht,
                           anchorage_spacing = deck_anchorage_spacing,
                           rib_angle = θ, rib_pitch = pitch_i)
        else
            SolidSlabOnBeam(t_i, conc_i.fc′, conc_i.E, conc_i.ρ, Es,
                            0.0u"m", 0.0u"m")
        end
        left, right = beam_side_profiles(struc, beam)
        M_of_s, bps = beam_signed_moment_field(struc, beam)
        L_i = _as_length(member_length(beam))
        pre = u_dead === nothing ? nothing :
            beam_pre_cure_shape(struc, beam, u_dead, by_element)
        BeamSaggingField(left, right, M_of_s, collect(Float64, bps), L_i, slab_i;
                         pre_cure = pre,
                         supports = beam_interior_supports(struc, beam;
                                                           lookup = supports_lookup))
    end
    isempty(fields) && throw(ArgumentError("composite_group_payload needs at least one beam"))
    ctx = CompositeContext(first(fields).slab, anchor, L; shored = shored, Lb_const = Lb_const,
                           Asr = Asr, Fysr = Fysr, neg_moment = neg_moment,
                           ΣQn_neg = ΣQn_neg, L_twist = L_twist,
                           deck_attachment = deck_attachment,
                           cp_class = cp_class)
    return PerStationComposite(ctx, fields)
end

"""
    composite_payloads_for_groups(struc, group_ids, L_totals, concrete, Es;
        t_slab=nothing, anchor=nothing) -> Vector

One payload per steel beam group. A group with no slab on any of its beams,
and no `t_slab`, gets `false`: the sizer designs it as bare steel. `L_totals[i]` may be the sum of the beams
in the group; each beam is still checked at its own span. `t_slab`, when
given, overrides every beam. Otherwise each beam uses the solid thickness of
the slab it bears on. `concrete` is the fallback when that slab's volume map
does not name a concrete. It is not used in place of a concrete the slab
already records.
"""
function composite_payloads_for_groups(
    struc::BuildingStructure, group_ids, L_totals, concrete, Es;
    t_slab = nothing, anchor = nothing,
    shored::Bool = false, cp_class::Symbol = :medium,
    slab_type::Symbol = :solid,
    deck_hr = nothing, deck_wr = nothing,
    deck_orientation::Symbol = :from_slab,
    deck_e_mid_ht = nothing, deck_anchorage_spacing = nothing,
    deck_pitch = nothing,
    L_twist = nothing,
    deck_attachment = :auto,
)
    map(enumerate(group_ids)) do (g_idx, gid)
        mg = struc.member_groups[gid]
        beams = [struc.beams[i] for i in mg.member_indices]
        # No slab on any beam of the group and no thickness override: there is
        # nothing to act compositely with, so the group is bare steel (Chapter F).
        if t_slab === nothing && all(b -> isempty(_slabs_on_beam(struc, b)), beams)
            return false
        end
        composite_group_payload(struc, beams, L_totals[g_idx] * u"m",
                                concrete, t_slab, Es; anchor = anchor,
                                shored = shored, cp_class = cp_class,
                                slab_type = slab_type, deck_hr = deck_hr,
                                deck_wr = deck_wr, deck_orientation = deck_orientation,
                                deck_e_mid_ht = deck_e_mid_ht,
                                deck_anchorage_spacing = deck_anchorage_spacing,
                                deck_pitch = deck_pitch,
                                L_twist = L_twist,
                                deck_attachment = deck_attachment)
    end
end
