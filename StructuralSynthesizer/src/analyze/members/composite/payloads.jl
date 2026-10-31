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
    isempty(model.frame_elements) && return nothing
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
        el = struc.asap_model.frame_elements[seg.edge_idx]
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
    d_rebar = 0.0u"m",
    variable_inertia::Bool = false,
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
                           cp_class = cp_class, d_rebar = d_rebar)
    return PerStationComposite(ctx, fields, variable_inertia)
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
    d_rebar = 0.0u"m",
    variable_inertia::Bool = false,
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
                                deck_attachment = deck_attachment,
                                d_rebar = d_rebar,
                                variable_inertia = variable_inertia)
    end
end
