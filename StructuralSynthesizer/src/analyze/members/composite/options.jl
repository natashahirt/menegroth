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

