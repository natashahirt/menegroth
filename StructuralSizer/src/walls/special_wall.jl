using Unitful

# ACI 318-19 §18.10.6.1 (corpus: aci-318-19, page 326). One edge, one section.
# The need for a special boundary element is evaluated by §18.10.6.2 or by
# §18.10.6.3, not by both. §18.10.6.2 is the displacement route, and it
# applies only when hwcs/ℓw ≥ 2, the wall is effectively continuous from the
# base to the top, and it is designed for a single critical section.
# Otherwise the section is not designed by §18.10.6.2, and §18.10.6.3 is the
# route. §18.10.6.4 is evaluated when an element is required. §18.10.6.5 is
# evaluated when it is not. A stress between 0.15 f′c and 0.2 f′c neither
# starts an element nor ends one, so this one section leaves `required`
# undecided.

"""
    special_boundary_composer(; lw, hwcs, continuous, single_critical_section, ...) -> NamedTuple

One edge of one section through §18.10.6.1.

`route` is `:displacement` or `:stress`. `slender` is `hwcs/ℓw ≥ 2`. The
displacement route is the one where `continuous`, `single_critical_section`,
and `slender` are all true.

`required` is `true`, `false`, or `nothing`. `nothing` is the §18.10.6.3
band, where the stress has not exceeded `0.2 f′c` and is not less than
`0.15 f′c`. `required_by` names the sentence: `:displacement`, `:stress`,
`:not_required`, `:may_discontinue`, or `:between`.

On a required element the geometry fields are filled and `edge` is
`nothing`. `length_by`, `zone_width_by`, `extension_by`, `confinement_by`,
and `spacing_by` name every candidate that ties for the governing value.
The displacement route also fills `extension` and `alternative`; the stress
route leaves both `nothing`, because §18.10.6.2(b) is not that route.
`alternative.drift` stays `nothing` when the §18.10.6.2(b)(ii) width meets.

On an element that is not required, the geometry fields are `nothing` and
`edge` holds §18.10.6.5. `edge.ties` stays `nothing` until the boundary
ratio and its tie inputs are supplied.

Detailing inputs are read only for a required element, and each group is
all present or all absent. No bars are placed.
"""
function special_boundary_composer(;
        lw::Length,
        hwcs::Length,
        continuous::Bool,
        single_critical_section::Bool,
        c::Union{Nothing,Length} = nothing,
        δu::Union{Nothing,Length} = nothing,
        Mu = nothing,
        Vu = nothing,
        Ve = nothing,
        b::Union{Nothing,Length} = nothing,
        hu::Union{Nothing,Length} = nothing,
        hw::Union{Nothing,Length} = nothing,
        fc = nothing,
        Acv = nothing,
        σ = nothing,
        λ::Union{Nothing,Real} = nothing,
        ρ::Union{Nothing,Real} = nothing,
        fy = nothing,
        tie_spacing::Union{Nothing,Length} = nothing,
        tie_hx::Union{Nothing,Length} = nothing,
        db::Union{Nothing,Length} = nothing,
        grade::Union{Nothing,Int} = nothing,
        within_critical_reach::Union{Nothing,Bool} = nothing,
        Ag = nothing,
        Ach = nothing,
        fyt = nothing,
        spiral::Bool = false,
        least_dimension::Union{Nothing,Length} = nothing,
        hx::Union{Nothing,Length} = nothing,
        thickness::Union{Nothing,Length} = nothing,
        fc_floor = nothing,
        web_bar_spacing::Union{Nothing,Length} = nothing,
        ld::Union{Nothing,Length} = nothing,
        into_foundation::Bool = false,
        foundation_minimum::Union{Nothing,Length} = nothing,
        gap::Union{Nothing,Length} = nothing,
        can_develop::Union{Nothing,Bool} = nothing,
        web_asfy_per_s = nothing,
        boundary_asfyt_per_s = nothing,
        Ash = nothing,
        bc::Union{Nothing,Length} = nothing,
        in_compression::Bool = false,
        effective_flange_width::Union{Nothing,Length} = nothing,
        height_above_section::Union{Nothing,Length} = nothing,
        distance_to_adjacent_web::Union{Nothing,Length} = nothing,
        detailed_flange::Union{Nothing,Length} = nothing)
    h_m = ustrip(u"m", hwcs)
    lw_m = ustrip(u"m", lw)
    h_m > 0 || throw(ArgumentError("special boundary composer: hwcs must be positive (got $hwcs)"))
    lw_m > 0 || throw(ArgumentError("special boundary composer: ℓw must be positive (got $lw)"))
    # §18.10.6.2 (corpus: aci-318-19, page 326): all three, or this is not that section.
    slenderness = h_m / lw_m
    slender = slenderness >= 2
    displacement = continuous && single_critical_section && slender
    if displacement
        c = _composer_need(c, "c")
        δu = _composer_need(δu, "δu")
        trigger = displacement_boundary_element(c, lw, δu, hwcs;
                                               single_critical_section = true)
        trigger.required isa Bool || throw(ArgumentError(
            "special boundary composer: the displacement section did not apply"))
        if trigger.required
            detail = _composer_element(;
                displacement = true, lw = lw, hwcs = hwcs, c = c, δu = δu,
                continuous = continuous, single_critical_section = single_critical_section,
                Mu = Mu, Vu = Vu, Ve = Ve, b = b, hu = hu, hw = hw, fc = fc, Acv = Acv,
                Ag = Ag, Ach = Ach, fyt = fyt, spiral = spiral,
                least_dimension = least_dimension, db = db, hx = hx, grade = grade,
                within_critical_reach = within_critical_reach, thickness = thickness,
                fc_floor = fc_floor, web_bar_spacing = web_bar_spacing,
                ld = ld, into_foundation = into_foundation,
                foundation_minimum = foundation_minimum,
                gap = gap, can_develop = can_develop,
                web_asfy_per_s = web_asfy_per_s, boundary_asfyt_per_s = boundary_asfyt_per_s,
                Ash = Ash, bc = bc, in_compression = in_compression,
                effective_flange_width = effective_flange_width,
                height_above_section = height_above_section,
                distance_to_adjacent_web = distance_to_adjacent_web,
                detailed_flange = detailed_flange)
            return _composer_result(;
                route = :displacement, slenderness = slenderness, slender = slender,
                continuous = continuous, single_critical_section = single_critical_section,
                required = true, required_by = :displacement,
                trigger = trigger, stress = nothing, edge = nothing, detail = detail)
        end
        return _composer_result(;
            route = :displacement, slenderness = slenderness, slender = slender,
            continuous = continuous, single_critical_section = single_critical_section,
            required = false, required_by = :not_required,
            trigger = trigger, stress = nothing,
            edge = _composer_edge(; Vu = Vu, λ = λ, fc = fc, Acv = Acv, ρ = ρ, fy = fy,
                                 c = c, lw = lw, tie_spacing = tie_spacing, tie_hx = tie_hx,
                                 db = db, grade = grade,
                                 within_critical_reach = within_critical_reach),
            detail = _composer_blank())
    end
    # §18.10.6.3 (corpus: aci-318-19, page 327): a wall not designed by §18.10.6.2.
    σ = _composer_need(σ, "the extreme-fiber stress σ")
    fc = _composer_need(fc, "f′c")
    stress = stress_boundary_element(σ, fc)
    if stress.triggered
        c = _composer_need(c, "c")
        detail = _composer_element(;
            displacement = false, lw = lw, hwcs = hwcs, c = c, δu = δu,
            continuous = continuous, single_critical_section = single_critical_section,
            Mu = Mu, Vu = Vu, Ve = Ve, b = b, hu = hu, hw = hw, fc = fc, Acv = Acv,
            Ag = Ag, Ach = Ach, fyt = fyt, spiral = spiral,
            least_dimension = least_dimension, db = db, hx = hx, grade = grade,
            within_critical_reach = within_critical_reach, thickness = thickness,
            fc_floor = fc_floor, web_bar_spacing = web_bar_spacing,
            ld = ld, into_foundation = into_foundation,
            foundation_minimum = foundation_minimum,
            gap = gap, can_develop = can_develop,
            web_asfy_per_s = web_asfy_per_s, boundary_asfyt_per_s = boundary_asfyt_per_s,
            Ash = Ash, bc = bc, in_compression = in_compression,
            effective_flange_width = effective_flange_width,
            height_above_section = height_above_section,
            distance_to_adjacent_web = distance_to_adjacent_web,
            detailed_flange = detailed_flange)
        return _composer_result(;
            route = :stress, slenderness = slenderness, slender = slender,
            continuous = continuous, single_critical_section = single_critical_section,
            required = true, required_by = :stress,
            trigger = nothing, stress = stress, edge = nothing, detail = detail)
    end
    if stress.may_discontinue
        return _composer_result(;
            route = :stress, slenderness = slenderness, slender = slender,
            continuous = continuous, single_critical_section = single_critical_section,
            required = false, required_by = :may_discontinue,
            trigger = nothing, stress = stress,
            edge = _composer_edge(; Vu = Vu, λ = λ, fc = fc, Acv = Acv, ρ = ρ, fy = fy,
                                 c = c, lw = lw, tie_spacing = tie_spacing, tie_hx = tie_hx,
                                 db = db, grade = grade,
                                 within_critical_reach = within_critical_reach),
            detail = _composer_blank())
    end
    return _composer_result(;
        route = :stress, slenderness = slenderness, slender = slender,
        continuous = continuous, single_critical_section = single_critical_section,
        required = nothing, required_by = :between,
        trigger = nothing, stress = stress, edge = nothing, detail = _composer_blank())
end

function _composer_need(value, what)
    value === nothing &&
        throw(ArgumentError("special boundary composer: $what is required on this route"))
    return value
end

function _composer_together(label, values)
    present = map(v -> v !== nothing, values)
    any(present) || return false
    all(present) || throw(ArgumentError(
        "special boundary composer: $label are supplied together"))
    return true
end

# Names of every candidate that lands on the extreme. Order is the order given.
function _composer_extreme(items; least::Bool)
    present = [(name, value) for (name, value) in items if value !== nothing]
    extreme = least ? minimum(last, present) : maximum(last, present)
    # A crossover the code writes as an equality can differ by a rounding unit.
    matches(value) = value == extreme || isapprox(value, extreme; rtol = 1e-8)
    return Tuple(name for (name, value) in present if matches(value))
end

function _composer_blank()
    return (
        extension = nothing, extension_by = nothing, alternative = nothing,
        length = nothing, length_by = nothing,
        zone_width = nothing, zone_width_by = nothing,
        zone_width_meets = nothing, zone_width_shortfall = nothing,
        overhang = nothing, flange = nothing,
        confinement = nothing, confinement_by = nothing,
        spacing = nothing, spacing_by = nothing,
        hoops = nothing, hoop_hx_by = nothing, hoop_overlap_by = nothing, hoop_spacing = nothing,
        floor = nothing, web_bars = nothing, support = nothing, termination = nothing,
    )
end

function _composer_result(; route, slenderness, slender, continuous, single_critical_section,
                         required, required_by, trigger, stress, edge, detail)
    return (
        route = route,
        slenderness = slenderness,
        slender = slender,
        continuous = continuous,
        single_critical_section = single_critical_section,
        required = required,
        required_by = required_by,
        trigger = trigger,
        stress = stress,
        edge = edge,
        detail...,
    )
end

function _composer_edge(; Vu, λ, fc, Acv, ρ, fy, c, lw, tie_spacing, tie_hx, db, grade,
                       within_critical_reach)
    Vu = _composer_need(Vu, "Vu")
    λ = _composer_need(λ, "λ")
    fc = _composer_need(fc, "f′c")
    Acv = _composer_need(Acv, "Acv")
    # §18.10.6.5(a) (corpus: aci-318-19, page 332).
    threshold = lambda_sqrt_fc_Acv(λ, fc, Acv)
    hook = horizontal_edge_anchorage(Vu, threshold)
    ties = nothing
    # `c` is already known on the displacement route. Its presence does not
    # ask for the tie check. The check opens only when the tie data is supplied.
    if _composer_together("the §18.10.6.5(b) tie inputs",
                          (ρ, fy, tie_spacing, tie_hx, db, grade, within_critical_reach))
        c = _composer_need(c, "c")
        # §18.10.6.5(b) (corpus: aci-318-19, page 332).
        ties = boundary_ratio_ties(ρ, fy, c, lw, tie_spacing, tie_hx, db;
                                  grade = grade, within_critical_reach = within_critical_reach)
    end
    return (hook = hook, ties = ties)
end

function _composer_element(; displacement::Bool, lw, hwcs, c, δu, continuous, single_critical_section,
                          Mu, Vu, Ve, b, hu, hw, fc, Acv,
                          Ag, Ach, fyt, spiral, least_dimension, db, hx, grade,
                          within_critical_reach, thickness, fc_floor, web_bar_spacing,
                          ld, into_foundation, foundation_minimum, gap, can_develop,
                          web_asfy_per_s, boundary_asfyt_per_s, Ash, bc, in_compression,
                          effective_flange_width, height_above_section, distance_to_adjacent_web,
                          detailed_flange)
    b = _composer_need(b, "b")
    hu = _composer_need(hu, "hu")
    hw = _composer_need(hw, "hw")
    extension = nothing
    extension_by = nothing
    alternative = nothing
    if displacement
        Mu = _composer_need(Mu, "Mu")
        Vu = _composer_need(Vu, "Vu")
        Ve = _composer_need(Ve, "Ve")
        fc = _composer_need(fc, "f′c")
        Acv = _composer_need(Acv, "Acv")
        # §18.10.6.2(b) (corpus: aci-318-19, page 326).
        extension = boundary_transverse_extension(lw, Mu, Vu)
        extension_by = _composer_extreme(((:length, extension.from_length),
                                          (:shear, extension.from_shear)); least = false)
        alternative = boundary_width_or_drift(lw, b, c, Ve, fc, Acv, δu, hwcs)
    end
    # §18.10.6.4(a) (corpus: aci-318-19, page 327).
    length = boundary_element_horizontal_length(c, lw)
    length_by = _composer_extreme(((:offset, length.from_offset),
                                   (:half, length.from_half)); least = false)
    # §18.10.6.4(b) and (c) (corpus: aci-318-19, page 327).
    zone = compression_zone_width(hu, hw, lw, c;
                                 continuous = continuous,
                                 single_critical_section = single_critical_section)
    zone_by = zone.floor_applies ?
        _composer_extreme(((:unsupported, zone.from_unsupported),
                           (:floor, zone.thickness_floor)); least = false) :
        (:unsupported,)
    flange = flanged_boundary_element(; in_compression = in_compression,
                                     effective_flange_width = effective_flange_width)
    overhang = nothing
    if height_above_section !== nothing
        # §18.10.5.2 (corpus: aci-318-19, page 325).
        overhang = effective_flange_overhang(height_above_section;
                                            distance_to_adjacent_web = distance_to_adjacent_web,
                                            detailed = detailed_flange)
    elseif distance_to_adjacent_web !== nothing || detailed_flange !== nothing
        throw(ArgumentError(
            "special boundary composer: a flange overhang needs the height above the section"))
    end
    confinement = nothing
    confinement_by = nothing
    if _composer_together("Ag, Ach, and fyt", (Ag, Ach, fyt))
        # Table 18.10.6.4(g) (corpus: aci-318-19, page 328).
        confinement = boundary_transverse_amount(Ag, Ach, fc, fyt; spiral = spiral)
        confinement_by = _composer_extreme(((:cover, confinement.cover_term),
                                            (:constant, confinement.constant_term)); least = false)
    end
    spacing = nothing
    spacing_by = nothing
    if _composer_together("the vertical-spacing inputs",
                          (least_dimension, db, hx, grade, within_critical_reach))
        # §18.10.6.4(e) (corpus: aci-318-19, page 328).
        spacing = boundary_element_vertical_spacing(least_dimension, db, hx;
                                                   grade = grade,
                                                   within_critical_reach = within_critical_reach)
        spacing_by = _composer_extreme(((:dimension, spacing.from_dimension),
                                        (:bar, spacing.from_bar),
                                        (:so, spacing.from_so),
                                        (:table, spacing.from_table)); least = true)
    end
    hoops = nothing
    hoop_hx_by = nothing
    hoop_overlap_by = nothing
    if thickness !== nothing
        # §18.10.6.4(f) (corpus: aci-318-19, page 328). hx and the overlap are
        # each the lesser of a fixed cap and two-thirds of the thickness.
        hoops = boundary_transverse_spacing(thickness)
        hoop_hx_by = _composer_extreme(((:cap, hoops.hx_from_cap),
                                        (:thickness, hoops.hx_from_thickness)); least = true)
        hoop_overlap_by = _composer_extreme(((:cap, hoops.overlap_from_cap),
                                             (:thickness, hoops.overlap_from_thickness)); least = true)
    end
    hoop_spacing = nothing
    if _composer_together("Ash and bc", (Ash, bc))
        (confinement === nothing || spacing === nothing) && throw(ArgumentError(
            "special boundary composer: hoop spacing needs the confinement ratio and the vertical spacing"))
        hoop_spacing = boundary_hoop_spacing(Ash, bc, confinement.required, spacing.required)
    end
    floor = nothing
    if fc_floor !== nothing
        floor = floor_concrete_at_boundary(fc_floor, fc)
    end
    web_bars = nothing
    if web_bar_spacing !== nothing
        web_bars = web_vertical_support_spacing(web_bar_spacing)
    end
    support = nothing
    if ld !== nothing || foundation_minimum !== nothing
        ld = _composer_need(ld, "ℓd")
        support = boundary_support_extension(ld; into_foundation = into_foundation,
                                            foundation_minimum = foundation_minimum)
    end
    termination = nothing
    if gap !== nothing || can_develop !== nothing
        gap = _composer_need(gap, "the web-bar gap")
        can_develop = _composer_need(can_develop, "whether the boundary can develop the web bar")
        termination = horizontal_web_termination(gap; can_develop = can_develop,
                                                web_asfy_per_s = web_asfy_per_s,
                                                boundary_asfyt_per_s = boundary_asfyt_per_s)
    end
    return (
        extension = extension,
        extension_by = extension_by,
        alternative = alternative,
        length = length,
        length_by = length_by,
        zone_width = zone,
        zone_width_by = zone_by,
        zone_width_meets = b >= zone.required,
        zone_width_shortfall = max(zero(zone.required), zone.required - b),
        overhang = overhang,
        flange = flange,
        confinement = confinement,
        confinement_by = confinement_by,
        spacing = spacing,
        spacing_by = spacing_by,
        hoops = hoops,
        hoop_hx_by = hoop_hx_by,
        hoop_overlap_by = hoop_overlap_by,
        hoop_spacing = hoop_spacing,
        floor = floor,
        web_bars = web_bars,
        support = support,
        termination = termination,
    )
end

"""
    boundary_minimum_thickness(result) -> length or nothing

The compression-zone thickness a required element needs. It is the greater
of the §18.10.6.4(b)/(c) width and, on the displacement route, the
§18.10.6.2(b)(ii) width. Meeting that (ii) width is what lets the route
skip the drift check. An element that is not required returns `nothing`.
"""
function boundary_minimum_thickness(result)
    result.required === true || return nothing
    result.zone_width === nothing && return nothing
    required = result.zone_width.required
    if result.alternative !== nothing
        required = max(required, result.alternative.width.required)
    end
    return required
end
