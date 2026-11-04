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
        tribs === nothing && _omit_missing_tributary_cache(cell, cell_idx) && continue
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
    return _clip_profiles_at_openings(struc, verts, seg_len_m, left, right)
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
    d_rebar = 0.0u"m",
)
    # --- Span (c-to-c); building default = member length ---------------------
    L = isnothing(L_beam) ? member_length(beam) : L_beam
    L = L isa Unitful.Quantity ? L : L * u"m"

    # --- Full-slab override: skip all slab-field derivation ------------------
    if !isnothing(slab)
        return CompositeContext(slab, anchor, L; shored = shored, Lb_const = Lb_const,
                                Asr = Asr, Fysr = Fysr, neg_moment = neg_moment,
                                ΣQn_neg = ΣQn_neg, L_twist = L_twist, d_rebar = d_rebar)
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
                            ΣQn_neg = ΣQn_neg, L_twist = L_twist, d_rebar = d_rebar)
end

