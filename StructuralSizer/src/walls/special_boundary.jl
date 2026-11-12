# ==============================================================================
# Special structural wall — displacement boundary-element trigger
# ==============================================================================
# ACI 318-19 §18.10.6.2(a), Eq. (18.10.6.2a) (corpus: aci-318-19, page 326).
#
# §18.10.6.2 applies to walls or wall piers with hwcs/ℓw ≥ 2.0 that are
# effectively continuous from the base of structure to top of wall and are
# designed to have a single critical section for flexure and axial loads.
# This file evaluates only (a):
#       1.5 δu / hwcs ≥ ℓw / (600 c)                         (18.10.6.2a)
# and c is the largest neutral-axis depth calculated for the factored axial
# force and nominal moment strength consistent with the design displacement
# δu. The ratio δu/hwcs shall not be taken less than 0.005.
# Continuity from the base is the caller's statement, not something this
# function infers. Also evaluated here, each as its own function: the
# §18.10.6.2(b)(i) vertical extension, Eq. (18.10.6.2b) and (iii), the
# §18.10.6.3 stress limits, the §18.10.6.4(a)–(c) geometry, the §18.10.5.2
# flange overhang and the §18.10.6.4(d) web extension, the §18.10.6.4(e)
# vertical spacing, the §18.10.6.4(f) hoop spacing, the §18.10.6.4(h)–(k)
# continuity limits, Table 18.10.6.4(g), the §18.10.6.2(b)(ii) width
# shortcut, §18.10.6.5 for a wall with no special boundary element,
# the §25.7.2.2 tie size and the accepted hoop arrangement, the
# §18.10.7 coupling-beam route and Eq. (18.10.7.4), and the §18.14
# path for a frame member outside the seismic force-resisting system.
# The radical in (ii) and in §18.10.6.5(a) was read from the rendered page:
# the text layer drops it. §18.7.5.2(a)–(d) are configuration requirements
# and are not evaluated.
# No bars are placed.

using Unitful

"""
    displacement_boundary_element(c, lw, δu, hwcs; single_critical_section) -> NamedTuple

Whether Eq. (18.10.6.2a) requires a special boundary element.

`c` is the neutral-axis depth at nominal moment strength for the factored
axial force consistent with `δu` (ACI 318-19 §22.2, as §18.10.6.2 states it).
`lw` is ℓw. `hwcs` is the wall height above the critical section. All four are
lengths.

The section applies when `hwcs/lw ≥ 2` and `single_critical_section` is true.
That flag is the caller's statement that the wall is designed to have a single
critical section for flexure and axial loads. When the section does not apply,
`required` is `nothing`: §18.10.6.3 is the other evaluation and is not run.

`drift_ratio` is `δu/hwcs`, not taken less than 0.005. A boundary element is
required when `1.5 * drift_ratio ≥ lw/(600 c)`.

# Citation
ACI 318-19 §18.10.6.2(a), Eq. (18.10.6.2a) (corpus: aci-318-19, page 326).
"""
function displacement_boundary_element(c::Length, lw::Length, δu::Length, hwcs::Length;
                                      single_critical_section::Bool)
    c_m = ustrip(u"m", c)
    lw_m = ustrip(u"m", lw)
    δu_m = ustrip(u"m", δu)
    h_m = ustrip(u"m", hwcs)
    c_m > 0 || throw(ArgumentError(
        "displacement boundary element: neutral-axis depth must be positive (got $c)"))
    lw_m > 0 || throw(ArgumentError(
        "displacement boundary element: ℓw must be positive (got $lw)"))
    h_m > 0 || throw(ArgumentError(
        "displacement boundary element: height above the critical section must be positive (got $hwcs)"))
    δu_m >= 0 || throw(ArgumentError(
        "displacement boundary element: design displacement must be non-negative (got $δu)"))
    # §18.10.6.2 (corpus: aci-318-19, page 326): hwcs/ℓw ≥ 2.0, and one
    # critical section for flexure and axial load.
    slenderness = h_m / lw_m
    applicable = slenderness >= 2.0 && single_critical_section
    # The ratio δu/hwcs shall not be taken less than 0.005.
    drift_ratio = max(δu_m / h_m, 0.005)
    demand = 1.5 * drift_ratio
    capacity = lw_m / (600 * c_m)
    required = applicable ? demand >= capacity - 1e-12 : nothing
    return (applicable = applicable,
            required = required,
            slenderness = slenderness,
            drift_ratio = drift_ratio,
            demand = demand,
            neutral_axis_term = capacity)
end

"""
    boundary_transverse_extension(lw, Mu, Vu) -> NamedTuple

How far §18.10.6.2(b)(i) carries the special-boundary transverse
reinforcement above and below the critical section: the greater of `lw`
(ℓw) and `Mu / (4 Vu)`.

`Mu` is a moment and `Vu` is a force, both taken positive. A negative
moment or a non-positive shear is rejected, because a sign error would
otherwise hide behind the length term.

`from_length` and `from_shear` are the two candidates. `extension` is
their greater.

# Citation
ACI 318-19 §18.10.6.2(b)(i) (corpus: aci-318-19, page 326).
"""
function boundary_transverse_extension(lw::Length, Mu, Vu)
    lw_m = ustrip(u"m", lw)
    lw_m > 0 || throw(ArgumentError(
        "boundary transverse extension: ℓw must be positive (got $lw)"))
    ustrip(u"N*m", Mu) >= 0 || throw(ArgumentError(
        "boundary transverse extension: Mu is taken positive (got $Mu)"))
    ustrip(u"N", Vu) > 0 || throw(ArgumentError(
        "boundary transverse extension: Vu must be positive (got $Vu)"))
    # §18.10.6.2(b)(i) (corpus: aci-318-19, page 326): the greater of ℓw and Mu/4Vu.
    from_shear = (Mu / Vu) / 4
    return (extension = max(lw, from_shear),
            from_length = lw,
            from_shear = from_shear)
end

"""
    boundary_element_horizontal_length(c, lw) -> NamedTuple

How far §18.10.6.4(a) runs the boundary element in from the extreme
compression fiber: the greater of `c − 0.1 lw` and `c / 2`.

Below `c = 0.2 lw` the half-depth term is the longer one, and `c − 0.1 lw`
can be negative. The negative candidate does not set the length; `c / 2`
does. At `c = 0.2 lw` the two candidates are equal. Above it, `c − 0.1 lw`
is longer.

# Citation
ACI 318-19 §18.10.6.4(a) (corpus: aci-318-19, page 327).
"""
function boundary_element_horizontal_length(c::Length, lw::Length)
    c_m = ustrip(u"m", c)
    lw_m = ustrip(u"m", lw)
    c_m > 0 || throw(ArgumentError(
        "boundary element length: neutral-axis depth must be positive (got $c)"))
    lw_m > 0 || throw(ArgumentError(
        "boundary element length: ℓw must be positive (got $lw)"))
    # §18.10.6.4(a) (corpus: aci-318-19, page 327): greater of c − 0.1ℓw and c/2.
    from_offset = c - 0.1 * lw
    from_half = c / 2
    return (length = max(from_offset, from_half),
            from_offset = from_offset,
            from_half = from_half)
end

"""
    compression_zone_width(hu, hw, lw, c; continuous, single_critical_section) -> NamedTuple

The minimum width `b` of the flexural compression zone.

`from_unsupported` is `hu / 16`, required over the horizontal distance
from §18.10.6.4(a). `hu` is the laterally unsupported height at the
extreme compression fiber.

`thickness_floor` is 12 in. when §18.10.6.4(c) applies, and `nothing`
otherwise. That floor applies only when `hw / lw ≥ 2`, `c / lw ≥ 3/8`,
`continuous` is true, and `single_critical_section` is true. Each gate
is reported on its own.

`required` is the greater of the limits that apply.

# Citation
ACI 318-19 §18.10.6.4(b) and §18.10.6.4(c) (corpus: aci-318-19, page 327).
`hu`: notation, laterally unsupported height at the extreme compression
fiber (corpus: aci-318-19, page 22).
"""
function compression_zone_width(hu::Length, hw::Length, lw::Length, c::Length;
                               continuous::Bool, single_critical_section::Bool)
    hu_m = ustrip(u"m", hu)
    hw_m = ustrip(u"m", hw)
    lw_m = ustrip(u"m", lw)
    c_m = ustrip(u"m", c)
    hu_m > 0 || throw(ArgumentError(
        "compression zone width: unsupported height must be positive (got $hu)"))
    hw_m > 0 || throw(ArgumentError(
        "compression zone width: wall height must be positive (got $hw)"))
    lw_m > 0 || throw(ArgumentError(
        "compression zone width: ℓw must be positive (got $lw)"))
    c_m > 0 || throw(ArgumentError(
        "compression zone width: neutral-axis depth must be positive (got $c)"))
    # §18.10.6.4(b) (corpus: aci-318-19, page 327): b ≥ hu/16.
    from_unsupported = hu / 16
    slenderness = hw_m / lw_m
    neutral_axis_ratio = c_m / lw_m
    # §18.10.6.4(c): b ≥ 12 in. only for this wall.
    tall = slenderness >= 2.0
    deep = neutral_axis_ratio >= 3 / 8
    floor_applies = tall && deep && continuous && single_critical_section
    floor = 12.0u"inch"
    required = floor_applies ? max(from_unsupported, floor) : from_unsupported
    return (required = required,
            from_unsupported = from_unsupported,
            thickness_floor = floor_applies ? floor : nothing,
            floor_applies = floor_applies,
            slenderness = slenderness,
            neutral_axis_ratio = neutral_axis_ratio,
            tall = tall,
            deep = deep)
end

"""
    boundary_drift_capacity(lw, b, c, Ve, fc, Acv, δu, hwcs) -> NamedTuple

Eq. (18.10.6.2b) and the §18.10.6.2(b)(iii) comparison.

```
δc / hwcs = (1/100) (4 − (1/50)(ℓw/b)(c/b) − Ve / (8 f′c Acv))
```

`raw` is that value. `ratio` is `raw` not taken below 0.015. `demand` is
`1.5 δu / hwcs`, without the 0.005 floor from §18.10.6.2(a): that sentence
sits with the displacement trigger, and the commentary discusses it there.
`meets` compares the floored `ratio` with `demand`.

`Ve` is the shear force in the equation. `b` is the compression-zone
width. `Acv` is the area in the shear term.

# Citation
ACI 318-19 §18.10.6.2(b)(iii) and Eq. (18.10.6.2b) (corpus: aci-318-19, page 326).
"""
function boundary_drift_capacity(lw::Length, b::Length, c::Length, Ve, fc, Acv,
                                δu::Length, hwcs::Length)
    lw_m = ustrip(u"m", lw)
    b_m = ustrip(u"m", b)
    c_m = ustrip(u"m", c)
    h_m = ustrip(u"m", hwcs)
    δu_m = ustrip(u"m", δu)
    lw_m > 0 || throw(ArgumentError("drift capacity: ℓw must be positive (got $lw)"))
    b_m > 0 || throw(ArgumentError("drift capacity: compression-zone width must be positive (got $b)"))
    c_m > 0 || throw(ArgumentError("drift capacity: neutral-axis depth must be positive (got $c)"))
    h_m > 0 || throw(ArgumentError("drift capacity: height above the critical section must be positive (got $hwcs)"))
    δu_m >= 0 || throw(ArgumentError("drift capacity: design displacement must be non-negative (got $δu)"))
    ustrip(u"N", Ve) >= 0 || throw(ArgumentError("drift capacity: Ve is taken non-negative (got $Ve)"))
    ustrip(u"Pa", fc) > 0 || throw(ArgumentError("drift capacity: f′c must be positive (got $fc)"))
    ustrip(u"m^2", Acv) > 0 || throw(ArgumentError("drift capacity: Acv must be positive (got $Acv)"))
    # Eq. (18.10.6.2b) (corpus: aci-318-19, page 326). The shear term is
    # dimensionless: force / (stress × area).
    geometry = (1 / 50) * (lw_m / b_m) * (c_m / b_m)
    shear = ustrip(u"N", Ve) / (8 * ustrip(u"Pa", fc) * ustrip(u"m^2", Acv))
    raw = (1 / 100) * (4 - geometry - shear)
    # The value need not be taken less than 0.015.
    ratio = max(raw, 0.015)
    demand = 1.5 * (δu_m / h_m)
    return (raw = raw,
            ratio = ratio,
            floored = raw < 0.015,
            geometry_term = geometry,
            shear_term = shear,
            demand = demand,
            meets = ratio >= demand)
end

"""
    stress_boundary_element(σ, fc) -> NamedTuple

§18.10.6.3 at one section. `σ` is the calculated extreme-fiber compressive
stress, taken positive, and `fc` is f′c.

`triggered` is true when `σ` exceeds `0.2 fc`. `may_discontinue` is true
when `σ` is less than `0.15 fc`. The two cuts are not the same edge:
between them the section neither starts a boundary element nor ends one
that §18.10.6.3 already required.

# Citation
ACI 318-19 §18.10.6.3 (corpus: aci-318-19, page 327).
"""
function stress_boundary_element(σ, fc)
    fc_pa = ustrip(u"Pa", fc)
    σ_pa = ustrip(u"Pa", σ)
    fc_pa > 0 || throw(ArgumentError("stress boundary element: f′c must be positive (got $fc)"))
    σ_pa >= 0 || throw(ArgumentError(
        "stress boundary element: compressive stress is taken non-negative (got $σ)"))
    # §18.10.6.3 (corpus: aci-318-19, page 327): exceeds 0.2f′c; less than 0.15f′c.
    ratio = σ_pa / fc_pa
    return (ratio = ratio,
            triggered = ratio > 0.2,
            may_discontinue = ratio < 0.15)
end

"""
    boundary_transverse_amount(Ag, Ach, fc, fyt; spiral=false) -> NamedTuple

Table 18.10.6.4(g). `Ag` is the gross area of the boundary-element section
and `Ach` is the area of the confined core, measured out-to-out of the
transverse reinforcement. For a rectangular element the commentary takes
`Ag = ℓbe · b` and `Ach = bc1 · bc2`. `fyt` is the yield strength of the
transverse reinforcement.

Rectilinear hoop, `Ash / (s bc)` is the greater of

```
0.3 (Ag/Ach − 1) f′c/fyt      (a)
0.09 f′c/fyt                  (b)
```

Spiral or circular hoop, `ρs` is the greater of

```
0.45 (Ag/Ach − 1) f′c/fyt     (c)
0.12 f′c/fyt                  (d)
```

`cover_term` is (a) or (c). `constant_term` is (b) or (d). They cross when
`Ag/Ach` is `1.3` for a rectilinear hoop and `1 + 0.12/0.45` for a spiral.
Below that, the constant term is larger. A core larger than the gross
section makes the cover term negative, and the constant term still governs.

# Citation
ACI 318-19 Table 18.10.6.4(g) and the rectangular-section definitions in
the commentary (corpus: aci-318-19, page 328).
"""
function boundary_transverse_amount(Ag, Ach, fc, fyt; spiral::Bool = false)
    ag = ustrip(u"m^2", Ag)
    ach = ustrip(u"m^2", Ach)
    fc_pa = ustrip(u"Pa", fc)
    fyt_pa = ustrip(u"Pa", fyt)
    ag > 0 || throw(ArgumentError("boundary transverse amount: Ag must be positive (got $Ag)"))
    ach > 0 || throw(ArgumentError("boundary transverse amount: Ach must be positive (got $Ach)"))
    fc_pa > 0 || throw(ArgumentError("boundary transverse amount: f′c must be positive (got $fc)"))
    fyt_pa > 0 || throw(ArgumentError("boundary transverse amount: fyt must be positive (got $fyt)"))
    # Table 18.10.6.4(g) (corpus: aci-318-19, page 328).
    area_ratio = ag / ach
    strength_ratio = fc_pa / fyt_pa
    cover_factor = spiral ? 0.45 : 0.3
    constant_factor = spiral ? 0.12 : 0.09
    cover_term = cover_factor * (area_ratio - 1) * strength_ratio
    constant_term = constant_factor * strength_ratio
    return (required = max(cover_term, constant_term),
            cover_term = cover_term,
            constant_term = constant_term,
            area_ratio = area_ratio,
            strength_ratio = strength_ratio,
            style = spiral ? :spiral : :rectilinear)
end

"""
    effective_flange_overhang(height_above_section; distance_to_adjacent_web=nothing,
                             detailed=nothing) -> NamedTuple

How far §18.10.5.2 carries an effective flange out from the face of the web,
on one side.

`from_height` is 25 percent of the total wall height above the section.
`from_adjacent` is half the distance to an adjacent wall web, or `nothing`
when no adjacent web is given. `code_overhang` is the lesser of the limits
that exist. A missing adjacent web leaves only the height limit: there is
no second web to measure the half-distance to.

`detailed`, when given, is the overhang from a more detailed analysis. The
code sentence opens with that permission, so `overhang` is then `detailed`
and `code_overhang` is still reported.

# Citation
ACI 318-19 §18.10.5.2 (corpus: aci-318-19, page 325).
"""
function effective_flange_overhang(height_above_section::Length;
                                  distance_to_adjacent_web::Union{Nothing,Length} = nothing,
                                  detailed::Union{Nothing,Length} = nothing)
    h_m = ustrip(u"m", height_above_section)
    h_m > 0 || throw(ArgumentError(
        "effective flange overhang: height above the section must be positive (got $height_above_section)"))
    # §18.10.5.2 (corpus: aci-318-19, page 325): 25 percent of the wall height
    # above the section, and half the distance to an adjacent wall web.
    from_height = 0.25 * height_above_section
    from_adjacent = nothing
    if distance_to_adjacent_web !== nothing
        d_m = ustrip(u"m", distance_to_adjacent_web)
        d_m > 0 || throw(ArgumentError(
            "effective flange overhang: distance to an adjacent web must be positive (got $distance_to_adjacent_web)"))
        from_adjacent = distance_to_adjacent_web / 2
    end
    code_overhang = from_adjacent === nothing ? from_height : min(from_adjacent, from_height)
    if detailed !== nothing
        ustrip(u"m", detailed) > 0 || throw(ArgumentError(
            "effective flange overhang: a detailed overhang must be positive (got $detailed)"))
    end
    return (overhang = detailed === nothing ? code_overhang : detailed,
            code_overhang = code_overhang,
            from_height = from_height,
            from_adjacent = from_adjacent,
            detailed = detailed !== nothing)
end

"""
    flanged_boundary_element(; in_compression, effective_flange_width=nothing) -> NamedTuple

§18.10.6.4(d) for one edge. A flanged section in compression includes the
effective flange width and extends at least 12 in. into the web. The two
lengths are not added: the flange width lies in the flange, and the 12 in.
runs into the web.

`applies` is false when this edge is not a compression flange. A compression
flange with no width is rejected.

# Citation
ACI 318-19 §18.10.6.4(d) (corpus: aci-318-19, page 327).
"""
function flanged_boundary_element(; in_compression::Bool,
                                 effective_flange_width::Union{Nothing,Length} = nothing)
    if !in_compression
        return (applies = false,
                included_width = nothing,
                web_extension = nothing)
    end
    effective_flange_width !== nothing || throw(ArgumentError(
        "flanged boundary element: a compression flange needs its effective width"))
    ustrip(u"m", effective_flange_width) > 0 || throw(ArgumentError(
        "flanged boundary element: effective flange width must be positive (got $effective_flange_width)"))
    # §18.10.6.4(d) (corpus: aci-318-19, page 327): include the effective
    # flange width in compression, and extend at least 12 in. into the web.
    return (applies = true,
            included_width = effective_flange_width,
            web_extension = 12.0u"inch")
end

"""
    boundary_transverse_spacing(thickness) -> NamedTuple

§18.10.6.4(f), as limits. No hoops are placed.

`hx` is the greatest spacing between laterally supported longitudinal bars
around the perimeter: the lesser of 14 in. and two-thirds of the boundary
element thickness. The two candidates are equal at a thickness of 21 in.

`hoop_leg` is the greatest length of a hoop leg: twice the thickness.

`overlap` is the least overlap of adjacent hoops: the lesser of 6 in. and
two-thirds of the thickness. The two candidates are equal at a thickness
of 9 in.

# Citation
ACI 318-19 §18.10.6.4(f) (corpus: aci-318-19, page 328).
"""
function boundary_transverse_spacing(thickness::Length)
    t_m = ustrip(u"m", thickness)
    t_m > 0 || throw(ArgumentError(
        "boundary transverse spacing: boundary element thickness must be positive (got $thickness)"))
    # §18.10.6.4(f) (corpus: aci-318-19, page 328).
    two_thirds = (2 / 3) * thickness
    return (hx = min(14.0u"inch", two_thirds),
            hx_from_cap = 14.0u"inch",
            hx_from_thickness = two_thirds,
            hoop_leg = 2 * thickness,
            overlap = min(6.0u"inch", two_thirds),
            overlap_from_cap = 6.0u"inch",
            overlap_from_thickness = two_thirds)
end

"""
    boundary_tie_bar_size(longitudinal_bar; bundled=false) -> NamedTuple

§25.7.2.2. The tie is at least No. 3 when it encloses No. 10 or smaller
bars, and at least No. 4 when it encloses No. 11 or larger bars or a
bundled bar. No. 10 is the smaller row. Crossties use the same size.

# Citation
ACI 318-19 §25.7.2.2 (corpus: aci-318-19, page 501).
R25.7.2.2 (same page): the provision applies to crossties as well as ties.
"""
function boundary_tie_bar_size(longitudinal_bar::Int; bundled::Bool = false)
    longitudinal_bar in rebar_sizes() || throw(ArgumentError(
        "boundary tie bar: No. $longitudinal_bar is not a bar in the catalog $(rebar_sizes())"))
    # §25.7.2.2 (corpus: aci-318-19, page 501).
    size = (bundled || longitudinal_bar >= 11) ? 4 : 3
    return (tie = size, crosstie = size, bundled = bundled)
end

"""
    boundary_hoop_arrangement(thickness, zone_length) -> NamedTuple

How the boundary transverse reinforcement is arranged.

`hx`, `hoop_leg`, and `overlap` are the §18.10.6.4(f) limits.
`overlapping_hoops` is true when the element is longer than twice its
thickness. Equality at twice the thickness is one hoop.

`crosstie_every_bar` is the accepted arrangement: a crosstie with a
seismic hook at each end crosses the thickness at every longitudinal bar
that is not at a hoop corner. §25.7.2.3(b) would allow an unsupported bar
within 6 in. clear of a supported bar. This arrangement does not use that
allowance, so `hx` is the longitudinal-bar spacing.

# Citation
ACI 318-19 §18.10.6.4(f) (corpus: aci-318-19, page 328).
ACI 318-19 §25.7.2.3 (corpus: aci-318-19, page 501).
"""
function boundary_hoop_arrangement(thickness::Length, zone_length::Length)
    ustrip(u"m", zone_length) > 0 || throw(ArgumentError(
        "boundary hoop arrangement: the element length must be positive (got $zone_length)"))
    spacing = boundary_transverse_spacing(thickness)
    # Longer than twice the thickness. Equality stays one hoop.
    # ENGINEERING JUDGMENT: one crosstie at every bar that is not a hoop
    # corner, rather than the 6 in. clear allowance of §25.7.2.3(b).
    return (hx = spacing.hx,
            hoop_leg = spacing.hoop_leg,
            overlap = spacing.overlap,
            overlapping_hoops = zone_length > 2 * thickness,
            crosstie_every_bar = true,
            code_clear_limit = 6.0u"inch")
end

"""
    coupling_beam_route(ℓn, h, Vu, λ, fc, Acw) -> NamedTuple

Which §18.10.7 reinforcement a coupling beam is required to use.

`ℓn/h ≥ 4` is a special-moment-frame beam, with the wall boundary read as
a column. The waiver of §18.6.2.1(b) and (c) is not taken: no analysis
here shows adequate lateral stability.

`ℓn/h < 2` and `Vu ≥ 4λ√f′c·Acw` requires two intersecting groups of
diagonal bars. The waiver that loss of the beam will not impair the
structure is not taken. `√f′c` uses f′c in psi. Equality of the shear
requires the diagonals. Equality of the aspect ratio at 2 does not.

Anything else is permitted to be either those diagonals or §18.6.3 through
§18.6.5. The function does not choose between them.

# Citation
ACI 318-19 §18.10.7.1 and §18.10.7.2 (corpus: aci-318-19, page 332; the
radical in §18.10.7.2 was read from the rendered page).
ACI 318-19 §18.10.7.3 (corpus: aci-318-19, page 333).
"""
function coupling_beam_route(ℓn::Length, h::Length, Vu, λ::Real, fc, Acw)
    ln_m = ustrip(u"m", ℓn)
    h_m = ustrip(u"m", h)
    ln_m > 0 || throw(ArgumentError(
        "coupling beam: clear span must be positive (got $ℓn)"))
    h_m > 0 || throw(ArgumentError(
        "coupling beam: depth must be positive (got $h)"))
    ustrip(u"N", Vu) >= 0 || throw(ArgumentError(
        "coupling beam: Vu is taken non-negative (got $Vu)"))
    ratio = ln_m / h_m
    # §18.10.7.2 (corpus: aci-318-19, page 332): 4λ√f′c·Acw. √f′c at f′c in psi.
    threshold = 4 * lambda_sqrt_fc_Acv(λ, fc, Acw)
    if ratio >= 4
        return (route = :moment_frame,
                section = "18.10.7.1",
                aspect = ratio,
                shear_threshold = threshold,
                stability_waived = false)
    end
    if ratio < 2 && ustrip(u"N", Vu) + 1e-6 >= ustrip(u"N", threshold)
        return (route = :diagonal,
                section = "18.10.7.2",
                aspect = ratio,
                shear_threshold = threshold,
                stability_waived = false)
    end
    return (route = :either,
            section = "18.10.7.3",
            aspect = ratio,
            shear_threshold = threshold,
            stability_waived = false)
end

"""
    coupling_beam_diagonal_strength(Avd, fy, α, fc, Acw) -> NamedTuple

Eq. (18.10.7.4). `Vn = 2·Avd·fy·sinα`, not taken greater than `10√f′c·Acw`.

`α` is the angle between the diagonal bars and the longitudinal axis of
the beam. `Avd` is the total area of one group of diagonal bars. `√f′c`
uses f′c in psi. The cap has no λ.

# Citation
ACI 318-19 §18.10.7.4(a), Eq. (18.10.7.4) (corpus: aci-318-19, page 333;
the radical was read from the rendered page).
"""
function coupling_beam_diagonal_strength(Avd, fy, α, fc, Acw)
    avd = ustrip(u"inch^2", Avd)
    fy_psi = ustrip(u"psi", fy)
    avd > 0 || throw(ArgumentError(
        "coupling beam strength: Avd must be positive (got $Avd)"))
    fy_psi > 0 || throw(ArgumentError(
        "coupling beam strength: fy must be positive (got $fy)"))
    α_rad = ustrip(u"rad", α)
    0 < α_rad < π / 2 || throw(ArgumentError(
        "coupling beam strength: α is between the diagonal and the beam axis (got $α)"))
    fc_psi = ustrip(u"psi", fc)
    acw = ustrip(u"inch^2", Acw)
    fc_psi > 0 || throw(ArgumentError(
        "coupling beam strength: f′c must be positive (got $fc)"))
    acw > 0 || throw(ArgumentError(
        "coupling beam strength: Acw must be positive (got $Acw)"))
    # Eq. (18.10.7.4) (corpus: aci-318-19, page 333).
    from_steel = (2 * avd * fy_psi * sin(α_rad)) * u"lbf"
    cap = (10 * sqrt(fc_psi) * acw) * u"lbf"
    return (Vn = min(from_steel, cap),
            from_steel = from_steel,
            cap = cap,
            by = from_steel < cap ? :steel : from_steel > cap ? :cap : :both)
end

"""
    gravity_frame_seismic_section(; sdc, induced_forces_calculated,
                                 induced_exceeds_strength) -> NamedTuple

§18.14 for a cast-in-place frame member that is not part of the
seismic-force-resisting system.

The section applies in Seismic Design Categories D, E, and F. When the
moments and shears induced by the design displacement are not calculated,
§18.14.3.1 requires §18.14.3.3. When they are calculated and do not exceed
the design strengths, §18.14.3.2 applies. When they exceed, §18.14.3.3
applies.

# Citation
ACI 318-19 §18.14.1.1, §18.14.3.1, §18.14.3.2, and §18.14.3.3
(corpus: aci-318-19, pages 353–354).
ASCE 7-22 §12.12.4 (corpus: asce-7-22, PDF page 195): the reinforced-concrete
frame exception points here.
"""
function gravity_frame_seismic_section(; sdc::Symbol,
                                      induced_forces_calculated::Bool,
                                      induced_exceeds_strength::Bool)
    sdc in (:A, :B, :C, :D, :E, :F) || throw(ArgumentError(
        "gravity frame seismic section: Seismic Design Category $sdc is not A through F"))
    if sdc ∉ (:D, :E, :F)
        return (applies = false, section = nothing)
    end
    # §18.14.3.1 (corpus: aci-318-19, page 353): not checked means §18.14.3.3.
    if !induced_forces_calculated || induced_exceeds_strength
        return (applies = true, section = "18.14.3.3")
    end
    return (applies = true, section = "18.14.3.2")
end

"""
    gravity_beam_transverse_limit(d, db; Pu, Ag, fc) -> NamedTuple

§18.14.3.2(a). Transverse reinforcement runs the whole beam at a spacing
not exceeding `d/2`.

When the factored axial force exceeds `Ag·f′c/10`, the reinforcement is
hoops satisfying §18.7.5.2 and the spacing also does not exceed the lesser
of `6db` of the smallest enclosed bar and 6 in. Equality of the axial force
at `Ag·f′c/10` does not require the hoops. The configuration in §18.7.5.2
is not evaluated. The same item requires the beam to satisfy §18.6.3.1,
which is not evaluated here.

# Citation
ACI 318-19 §18.14.3.2(a) (corpus: aci-318-19, page 353; checked against the
rendered page).
"""
function gravity_beam_transverse_limit(d::Length, db::Length; Pu, Ag, fc)
    d_in = ustrip(u"inch", d)
    db_in = ustrip(u"inch", db)
    d_in > 0 || throw(ArgumentError(
        "gravity beam transverse: d must be positive (got $d)"))
    db_in > 0 || throw(ArgumentError(
        "gravity beam transverse: bar diameter must be positive (got $db)"))
    ag = ustrip(u"inch^2", Ag)
    fc_psi = ustrip(u"psi", fc)
    ag > 0 || throw(ArgumentError(
        "gravity beam transverse: Ag must be positive (got $Ag)"))
    fc_psi > 0 || throw(ArgumentError(
        "gravity beam transverse: f′c must be positive (got $fc)"))
    pu = ustrip(u"lbf", Pu)
    # §18.14.3.2(a) (corpus: aci-318-19, page 353): exceeds Ag·f′c/10.
    axial_cut = (ag * fc_psi / 10) * u"lbf"
    from_depth = d / 2
    if pu <= ustrip(u"lbf", axial_cut)
        return (spacing = from_depth,
                hoops_required = false,
                from_depth = from_depth,
                from_bar = nothing,
                axial_cut = axial_cut)
    end
    from_bar = min(6 * db, 6.0u"inch")
    return (spacing = min(from_depth, from_bar),
            hoops_required = true,
            from_depth = from_depth,
            from_bar = from_bar,
            axial_cut = axial_cut)
end

"""
    gravity_slab_column_shear(drift_ratio, shear_ratio, fc; prestressed=false,
                              fpc_meets_8_6_2_1=false) -> NamedTuple

Whether §18.14.5 requires slab shear reinforcement at a two-way slab-column
connection, and the stress that reinforcement must provide.

`drift_ratio` is Δx/hsx. `shear_ratio` is vuv/(φvc) from combinations that
include E. A post-tensioned slab uses the post-tensioned line only when fpc
meets §8.6.2.1 in each direction; otherwise the nonprestressed line is used,
which §R18.14.5.1 permits.

§18.14.5.2 is applied first. At or below 0.005 (nonprestressed) or 0.01
(qualifying post-tensioned), reinforcement is not required. Above that,
reinforcement is required when the drift ratio is at least
`0.035 − shear_ratio/20`, or `0.040 − shear_ratio/20` for a qualifying
post-tensioned slab. Equality of that line requires the reinforcement.

When it is required, vs is at least `3.5√f′c` and the reinforcement extends
at least four slab thicknesses from the face of the support.

# Citation
ACI 318-19 §18.14.5.1, §18.14.5.2, and §18.14.5.3 (corpus: aci-318-19,
PDF pages 354–355).
"""
function gravity_slab_column_shear(drift_ratio::Real, shear_ratio::Real, fc;
                                   prestressed::Bool=false,
                                   fpc_meets_8_6_2_1::Bool=false)
    drift_ratio >= 0 || throw(ArgumentError(
        "slab-column shear: the drift ratio is non-negative (got $drift_ratio)"))
    shear_ratio >= 0 || throw(ArgumentError(
        "slab-column shear: vuv/(φvc) is non-negative (got $shear_ratio)"))
    fc_psi = ustrip(u"psi", fc)
    fc_psi > 0 || throw(ArgumentError(
        "slab-column shear: f′c must be positive (got $fc)"))
    # §R18.14.5.1 (corpus: aci-318-19, PDF page 355): a post-tensioned slab
    # that misses §8.6.2.1 may be designed as nonprestressed.
    post_tensioned = prestressed && fpc_meets_8_6_2_1
    exempt = post_tensioned ? 0.010 : 0.005
    intercept = post_tensioned ? 0.040 : 0.035
    # §18.14.5.1 (corpus: aci-318-19, PDF page 354).
    limit = intercept - shear_ratio / 20
    # §18.14.5.2 is checked before the line. Equality of the exemption holds.
    required = drift_ratio > exempt && drift_ratio + 1e-12 >= limit
    # §18.14.5.3 (corpus: aci-318-19, PDF page 355).
    vs = (3.5 * sqrt(fc_psi)) * u"psi"
    return (required = required,
            drift_limit = limit,
            exempt = exempt,
            vs = vs,
            extension_thicknesses = 4,
            post_tensioned = post_tensioned)
end

"""
    special_column_hoop_length(depth, clear_span) -> Length

Length ℓo of closely spaced transverse reinforcement from each joint face
of a special moment frame column. The greatest of the column depth, one-sixth
of the clear span, and 18 in.

# Citation
ACI 318-19 §18.7.5.1 (corpus: aci-318-19, PDF page 309).
"""
function special_column_hoop_length(depth::Length, clear_span::Length)
    ustrip(u"m", depth) > 0 || throw(ArgumentError(
        "column hoop length: the depth must be positive (got $depth)"))
    ustrip(u"m", clear_span) > 0 || throw(ArgumentError(
        "column hoop length: the clear span must be positive (got $clear_span)"))
    # §18.7.5.1 (corpus: aci-318-19, PDF page 309).
    return max(depth, clear_span / 6, 18.0u"inch")
end

"""
    special_column_design_shear(Mpr_top, Mpr_bottom, ℓu, Vu; beam_shear=nothing) -> NamedTuple

Design shear of a special moment frame column. The probable moments at the
two joint faces give one shear. A `beam_shear` from the probable moments of
the beams at the joint is a cap the column shear need not exceed. The result
is never taken below the factored shear from analysis.

# Citation
ACI 318-19 §18.7.6.1.1 (corpus: aci-318-19, PDF page 312).
"""
function special_column_design_shear(Mpr_top, Mpr_bottom, ℓu::Length, Vu; beam_shear=nothing)
    ustrip(u"m", ℓu) > 0 || throw(ArgumentError(
        "column design shear: the clear height must be positive"))
    ustrip(u"N*m", Mpr_top) >= 0 || throw(ArgumentError(
        "column design shear: Mpr is non-negative"))
    ustrip(u"N*m", Mpr_bottom) >= 0 || throw(ArgumentError(
        "column design shear: Mpr is non-negative"))
    ustrip(u"N", Vu) >= 0 || throw(ArgumentError(
        "column design shear: the factored shear is non-negative"))
    # §18.7.6.1.1 (corpus: aci-318-19, PDF page 312).
    from_column = (Mpr_top + Mpr_bottom) / ℓu
    from_probable = beam_shear === nothing ? from_column : min(from_column, beam_shear)
    beam_shear === nothing || ustrip(u"N", beam_shear) >= 0 || throw(ArgumentError(
        "column design shear: the beam-joint shear is non-negative"))
    return (Ve = max(from_probable, Vu),
            from_column = from_column,
            Vu = Vu)
end

"""
    transverse_spacing_so(hx) -> NamedTuple

Eq. (18.7.5.3). `hx` is the largest center-to-center spacing of
laterally supported longitudinal bars.

```
so = 4 + (14 − hx) / 3
```

with `so`, `hx`, 4, and 14 in inches. The value shall not exceed 6 in.
and need not be taken less than 4 in. `raw` is the equation before
those bounds. `capped` means the equation exceeded 6 in. `floored`
means it fell below 4 in.

# Citation
ACI 318-19 §18.7.5.3(d) and Eq. (18.7.5.3) (corpus: aci-318-19, pages 310–311).
"""
function transverse_spacing_so(hx::Length)
    hx_in = ustrip(u"inch", hx)
    hx_in > 0 || throw(ArgumentError(
        "transverse spacing so: hx must be positive (got $hx)"))
    # Eq. (18.7.5.3) (corpus: aci-318-19, page 311). Inches.
    raw = 4 + (14 - hx_in) / 3
    return (so = min(6.0, max(4.0, raw)) * u"inch",
            raw = raw * u"inch",
            capped = raw > 6.0,
            floored = raw < 4.0)
end

"""
    wall_boundary_tie_spacing(db; grade, within_critical_reach) -> NamedTuple

Table 18.10.6.5(b). `db` is the diameter of the smallest primary
flexural bar. `within_critical_reach` is the caller's statement that
the station lies within the greater of ℓw and Mu/4Vu above and below
a critical section.

Grade 60: lesser of 6db and 6 in. inside that reach, and lesser of 8db
and 8 in. elsewhere. Grade 80: lesser of 5db and 6 in. inside, and
lesser of 6db and 6 in. elsewhere. Grade 100: lesser of 4db and 6 in.
inside, and lesser of 6db and 6 in. elsewhere.

# Citation
ACI 318-19 Table 18.10.6.5(b) (corpus: aci-318-19, page 332).
"""
function wall_boundary_tie_spacing(db::Length; grade::Int, within_critical_reach::Bool)
    db_in = ustrip(u"inch", db)
    db_in > 0 || throw(ArgumentError(
        "wall boundary tie spacing: bar diameter must be positive (got $db)"))
    # Table 18.10.6.5(b) (corpus: aci-318-19, page 332).
    if grade == 60
        factor = within_critical_reach ? 6 : 8
        cap = (within_critical_reach ? 6.0 : 8.0) * u"inch"
    elseif grade == 80
        factor = within_critical_reach ? 5 : 6
        cap = 6.0u"inch"
    elseif grade == 100
        factor = within_critical_reach ? 4 : 6
        cap = 6.0u"inch"
    else
        throw(ArgumentError(
            "wall boundary tie spacing: table covers Grades 60, 80, and 100 (got $grade)"))
    end
    from_bar = factor * db
    return (spacing = min(from_bar, cap),
            from_bar = from_bar,
            from_cap = cap,
            factor = factor)
end

"""
    boundary_element_vertical_spacing(least_dimension, db, hx; grade,
                                     within_critical_reach) -> NamedTuple

§18.10.6.4(e). The vertical spacing is the least of

- one-third of the least boundary-element dimension, which replaces
  the column limit of one-fourth in §18.7.5.3(a)
- 6db for Grade 60, or 5db for Grade 80, from §18.7.5.3(b) and (c);
  Grade 100 has no bar-diameter term there, so `from_bar` is `nothing`
- `so` from Eq. (18.7.5.3)
- the Table 18.10.6.5(b) limit at this station

§18.7.5.2(a) through (d) are configuration requirements and are not
evaluated.

# Citation
ACI 318-19 §18.10.6.4(e) (corpus: aci-318-19, page 328),
§18.7.5.3 (corpus: aci-318-19, pages 310–311),
Table 18.10.6.5(b) (corpus: aci-318-19, page 332).
"""
function boundary_element_vertical_spacing(least_dimension::Length, db::Length, hx::Length;
                                          grade::Int, within_critical_reach::Bool)
    least_in = ustrip(u"inch", least_dimension)
    least_in > 0 || throw(ArgumentError(
        "boundary element vertical spacing: least dimension must be positive (got $least_dimension)"))
    # §18.10.6.4(e) (corpus: aci-318-19, page 328): one-third, not the
    # one-fourth of §18.7.5.3(a).
    from_dimension = least_dimension / 3
    # §18.7.5.3(b) and (c) (corpus: aci-318-19, page 310).
    from_bar = if grade == 60
        6 * db
    elseif grade == 80
        5 * db
    elseif grade == 100
        nothing
    else
        throw(ArgumentError(
            "boundary element vertical spacing: Grades 60, 80, and 100 (got $grade)"))
    end
    so = transverse_spacing_so(hx)
    table = wall_boundary_tie_spacing(db; grade = grade,
                                     within_critical_reach = within_critical_reach)
    required = min(from_dimension, so.so, table.spacing)
    from_bar === nothing || (required = min(required, from_bar))
    return (required = required,
            from_dimension = from_dimension,
            from_bar = from_bar,
            from_so = so.so,
            from_table = table.spacing)
end

"""
    floor_concrete_at_boundary(fc_floor, fc_wall) -> NamedTuple

§18.10.6.4(h). Concrete in the floor at the special boundary element
has a specified strength at least 0.7 times f′c of the wall. Equality
meets the limit.

# Citation
ACI 318-19 §18.10.6.4(h) (corpus: aci-318-19, page 328).
"""
function floor_concrete_at_boundary(fc_floor, fc_wall)
    floor_pa = ustrip(u"Pa", fc_floor)
    wall_pa = ustrip(u"Pa", fc_wall)
    wall_pa > 0 || throw(ArgumentError(
        "floor concrete: wall f′c must be positive (got $fc_wall)"))
    floor_pa >= 0 || throw(ArgumentError(
        "floor concrete: floor f′c is taken non-negative (got $fc_floor)"))
    # §18.10.6.4(h) (corpus: aci-318-19, page 328): at least 0.7 f′c of the wall.
    ratio = floor_pa / wall_pa
    return (ratio = ratio, meets = ratio >= 0.7)
end

"""
    web_vertical_support_spacing(spacing) -> NamedTuple

§18.10.6.4(i), the spacing sentence only. Over the §18.10.6.2(b)
distance, web vertical bars are laterally supported, and that transverse
reinforcement is spaced at most 12 in. The bar-diameter limit of
§25.7.2.2 is not evaluated.

# Citation
ACI 318-19 §18.10.6.4(i) (corpus: aci-318-19, page 328).
"""
function web_vertical_support_spacing(spacing::Length)
    s_in = ustrip(u"inch", spacing)
    s_in > 0 || throw(ArgumentError(
        "web vertical support: spacing must be positive (got $spacing)"))
    # §18.10.6.4(i) (corpus: aci-318-19, page 328): not to exceed 12 in.
    return (limit = 12.0u"inch", meets = spacing <= 12.0u"inch")
end

"""
    boundary_support_extension(ld; into_foundation=false, foundation_minimum=nothing) -> NamedTuple

§18.10.6.4(j). `ld` is the development length of the largest longitudinal
bar in the boundary element. The caller computes it with
[`boundary_bar_development`](@ref) under §18.10.2.3.

Into an ordinary support the extension is `ld`. Into a footing, mat, or
pile cap it is also at least 12 in., or `foundation_minimum` when
§18.13.2.4 requires more. `required` is the greater of the lengths that
apply. A foundation minimum on a support that is not a footing, mat, or
pile cap is rejected.

# Citation
ACI 318-19 §18.10.6.4(j) (corpus: aci-318-19, page 328).
"""
function boundary_support_extension(ld::Length; into_foundation::Bool = false,
                                   foundation_minimum::Union{Nothing,Length} = nothing)
    ld_m = ustrip(u"m", ld)
    ld_m > 0 || throw(ArgumentError(
        "boundary support extension: ℓd must be positive (got $ld)"))
    if !into_foundation && foundation_minimum !== nothing
        throw(ArgumentError(
            "boundary support extension: a foundation minimum applies to a footing, mat, or pile cap"))
    end
    from_footing = nothing
    if into_foundation
        floor = 12.0u"inch"
        if foundation_minimum !== nothing
            ustrip(u"m", foundation_minimum) > 0 || throw(ArgumentError(
                "boundary support extension: foundation minimum must be positive (got $foundation_minimum)"))
            floor = max(floor, foundation_minimum)
        end
        from_footing = floor
    end
    # §18.10.6.4(j) (corpus: aci-318-19, page 328).
    required = from_footing === nothing ? ld : max(ld, from_footing)
    return (required = required,
            from_development = ld,
            from_footing = from_footing)
end

"""
    boundary_bar_development(bar_size, fc, fy, λ=1; yielding_likely=false, ...) -> Length

§18.10.2.3. The tension development length of one longitudinal bar.

The length is §25.4.2.1, including its 12 in. minimum. Where yielding of
longitudinal reinforcement is likely because of lateral displacement,
§18.10.2.3(b) multiplies that length by 1.25. The 12 ft extension of
§18.10.2.3(a) is a bar location, not this length.

# Citation
ACI 318-19 §18.10.2.3(b) (corpus: aci-318-19, page 320).
ACI 318-19 §25.4.2.1 (corpus: aci-318-19, printed pp. 471–472).
"""
function boundary_bar_development(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real=1.0;
                                 yielding_likely::Bool=false,
                                 ψt::Real=1.0, coating::Symbol=:uncoated,
                                 epoxy_close::Bool=false,
                                 favorable_cover::Bool=false, excess::Real=1.0)
    ld = straight_development_length(bar_size, fc, fy, λ; ψt=ψt, coating=coating,
                                     epoxy_close=epoxy_close,
                                     favorable_cover=favorable_cover, excess=excess)
    # §18.10.2.3(b) (corpus: aci-318-19, page 320): 1.25 times the fy tension length.
    return yielding_likely ? 1.25 * ld : ld
end

"""
    web_end_within_six_inches(gap) -> Bool

§18.10.6.4(k). `gap` is within 6 in. of the wall end. Equality reaches.
One nanometer past 6 in. still reaches: that is binary rounding of a meter
length, not a wider limit.

# Citation
ACI 318-19 §18.10.6.4(k) (corpus: aci-318-19, page 329).
"""
function web_end_within_six_inches(gap::Length)
    gap_m = ustrip(u"m", gap)
    gap_m >= 0 || throw(ArgumentError(
        "horizontal web termination: the gap to the wall end is taken non-negative (got $gap)"))
    # §18.10.6.4(k) (corpus: aci-318-19, page 329): within 6 in.
    return gap_m <= ustrip(u"m", 6.0u"inch") + 1e-9
end

"""
    horizontal_web_termination(gap; can_develop, web_asfy_per_s, boundary_asfyt_per_s) -> NamedTuple

§18.10.6.4(k). `gap` is the distance from the end of the horizontal web
reinforcement to the end of the wall. It is within the limit at 6 in.

`straight_permitted` is true when the boundary element is long enough to
develop the horizontal bar and As·fy/s of that bar does not exceed
As·fyt/s of the boundary transverse reinforcement parallel to it.
Otherwise a standard hook or head is required. Equality of the two
force-per-length terms does not exceed.

# Citation
ACI 318-19 §18.10.6.4(k) (corpus: aci-318-19, page 329).
"""
function horizontal_web_termination(gap::Length; can_develop::Bool,
                                   web_asfy_per_s = nothing,
                                   boundary_asfyt_per_s = nothing)
    reaches = web_end_within_six_inches(gap)
    if !can_develop
        return (reaches = reaches,
                straight_permitted = false,
                hook_required = true,
                force_ratio = nothing)
    end
    (web_asfy_per_s === nothing || boundary_asfyt_per_s === nothing) && throw(ArgumentError(
        "horizontal web termination: a bar the boundary can develop needs both force-per-length terms"))
    web = ustrip(u"N/m", web_asfy_per_s)
    boundary = ustrip(u"N/m", boundary_asfyt_per_s)
    web >= 0 || throw(ArgumentError(
        "horizontal web termination: web As·fy/s is taken non-negative (got $web_asfy_per_s)"))
    boundary > 0 || throw(ArgumentError(
        "horizontal web termination: boundary As·fyt/s must be positive (got $boundary_asfyt_per_s)"))
    ratio = web / boundary
    # Does not exceed: equality still permits a straight bar.
    straight = ratio <= 1
    return (reaches = reaches,
            straight_permitted = straight,
            hook_required = !straight,
            force_ratio = ratio)
end

"""
    boundary_zone_width_minimum(b, lw, c) -> NamedTuple

§18.10.6.2(b)(ii). The compression-zone width `b` is at least

```
√(0.025 · ℓw · c)
```

The radical is drawn on the page and is not in the text layer. Meeting this
width is one of the two alternatives in (b): (i) and either (ii) or (iii).

# Citation
ACI 318-19 §18.10.6.2(b)(ii) (corpus: aci-318-19, page 326; radical read
from the rendered page).
"""
function boundary_zone_width_minimum(b::Length, lw::Length, c::Length)
    b_m = ustrip(u"m", b)
    lw_m = ustrip(u"m", lw)
    c_m = ustrip(u"m", c)
    b_m > 0 || throw(ArgumentError("zone width minimum: b must be positive (got $b)"))
    lw_m > 0 || throw(ArgumentError("zone width minimum: ℓw must be positive (got $lw)"))
    c_m > 0 || throw(ArgumentError("zone width minimum: c must be positive (got $c)"))
    # §18.10.6.2(b)(ii) (corpus: aci-318-19, page 326).
    required = sqrt(0.025 * lw_m * c_m) * u"m"
    return (required = required, meets = b >= required)
end

"""
    boundary_width_or_drift(lw, b, c, Ve, fc, Acv, δu, hwcs) -> NamedTuple

§18.10.6.2(b) once (a) has required a boundary element: (ii) or (iii).

When `b` meets (ii), `by` is `:width` and the drift capacity is not
evaluated. Otherwise (iii) is evaluated and `by` is `:drift`.

# Citation
ACI 318-19 §18.10.6.2(b) (corpus: aci-318-19, page 326).
"""
function boundary_width_or_drift(lw::Length, b::Length, c::Length, Ve, fc, Acv,
                                δu::Length, hwcs::Length)
    width = boundary_zone_width_minimum(b, lw, c)
    # (b): (i) and either (ii) or (iii). A width that meets (ii) ends it.
    if width.meets
        return (satisfied = true, by = :width, width = width, drift = nothing)
    end
    drift = boundary_drift_capacity(lw, b, c, Ve, fc, Acv, δu, hwcs)
    return (satisfied = drift.meets, by = :drift, width = width, drift = drift)
end

"""
    lambda_sqrt_fc_Acv(λ, fc, Acv) -> force

`λ√f′c·Acv`. `√f′c` is evaluated with f′c in psi, which is the unit in which
this expression is a stress, and the product with `Acv` in square inches is
a force. The radical covers f′c only. It is drawn on the §18.10.6.5(a) page
and is not in the text layer.

# Citation
ACI 318-19 §18.10.6.5(a) (corpus: aci-318-19, page 332; radical read from
the rendered page). The psi evaluation is the one already used for the
§11.5.4.3 concrete term.
"""
function lambda_sqrt_fc_Acv(λ::Real, fc, Acv)
    λ > 0 || throw(ArgumentError("λ√f′c·Acv: λ must be positive (got $λ)"))
    fc_psi = ustrip(u"psi", fc)
    acv = ustrip(u"inch^2", Acv)
    fc_psi > 0 || throw(ArgumentError("λ√f′c·Acv: f′c must be positive (got $fc)"))
    acv > 0 || throw(ArgumentError("λ√f′c·Acv: Acv must be positive (got $Acv)"))
    # §18.10.6.5(a) (corpus: aci-318-19, page 332). √f′c at f′c in psi.
    return (λ * sqrt(fc_psi) * acv) * u"lbf"
end

"""
    horizontal_edge_anchorage(Vu, threshold) -> NamedTuple

§18.10.6.5(a) at one edge with no special boundary element. A standard hook,
or a U-stirrup of the same bar, is required unless `Vu` is less than
`λ√f′c·Acv`. Equality does not exempt the hook.

# Citation
ACI 318-19 §18.10.6.5(a) (corpus: aci-318-19, page 332).
"""
function horizontal_edge_anchorage(Vu, threshold)
    vu = ustrip(u"N", Vu)
    cut = ustrip(u"N", threshold)
    vu >= 0 || throw(ArgumentError(
        "horizontal edge anchorage: Vu is taken non-negative (got $Vu)"))
    cut > 0 || throw(ArgumentError(
        "horizontal edge anchorage: λ√f′c·Acv must be positive (got $threshold)"))
    # Less than: Vu equal to the threshold still needs the hook.
    exempt = vu < cut
    return (threshold = threshold, exempt = exempt, hook_required = !exempt)
end

"""
    boundary_longitudinal_ratio(ρ, fy) -> NamedTuple

The §18.10.6.5(b) cut. `limit` is `400/fy`, with 400 in psi because `fy` is
taken in psi. `exceeds` is true when `ρ` is above that limit. Equality does
not exceed it.

# Citation
ACI 318-19 §18.10.6.5(b) (corpus: aci-318-19, page 332).
"""
function boundary_longitudinal_ratio(ρ::Real, fy)
    ρ >= 0 || throw(ArgumentError(
        "boundary longitudinal ratio: ρ is taken non-negative (got $ρ)"))
    fy_psi = ustrip(u"psi", fy)
    fy_psi > 0 || throw(ArgumentError(
        "boundary longitudinal ratio: fy must be positive (got $fy)"))
    # §18.10.6.5(b) (corpus: aci-318-19, page 332): exceeds 400/fy.
    limit = 400 / fy_psi
    return (limit = limit, exceeds = ρ > limit)
end

"""
    boundary_ratio_ties(ρ, fy, c, lw, spacing, hx, db; grade, within_critical_reach) -> NamedTuple

§18.10.6.5(b) when a special boundary element is not required.

`exceeds` follows `boundary_longitudinal_ratio`. Below the cut, no length
and no spacing are required.

Above it, transverse reinforcement satisfies §18.7.5.2(a) through (e) over
the §18.10.6.4(a) length, and its vertical spacing follows Table
18.10.6.5(b). (a) through (d) are configuration and are not evaluated.
(e) is evaluated: `hx` shall not exceed 14 in. `spacing_meets` is
`spacing` not exceeding the table.

# Citation
ACI 318-19 §18.10.6.5(b) (corpus: aci-318-19, page 332),
§18.10.6.4(a) (page 327), §18.7.5.2(e) (page 310),
Table 18.10.6.5(b) (page 332).
"""
function boundary_ratio_ties(ρ::Real, fy, c::Length, lw::Length, spacing::Length, hx::Length,
                            db::Length; grade::Int, within_critical_reach::Bool)
    cut = boundary_longitudinal_ratio(ρ, fy)
    if !cut.exceeds
        return (limit = cut.limit,
                exceeds = false,
                length = nothing,
                spacing_limit = nothing,
                spacing_meets = nothing,
                hx_limit = nothing,
                hx_meets = nothing)
    end
    reach = boundary_element_horizontal_length(c, lw)
    table = wall_boundary_tie_spacing(db; grade = grade,
                                     within_critical_reach = within_critical_reach)
    hx_in = ustrip(u"inch", hx)
    s_in = ustrip(u"inch", spacing)
    hx_in > 0 || throw(ArgumentError("boundary ratio ties: hx must be positive (got $hx)"))
    s_in > 0 || throw(ArgumentError("boundary ratio ties: spacing must be positive (got $spacing)"))
    # §18.7.5.2(e) (corpus: aci-318-19, page 310): hx shall not exceed 14 in.
    cap = 14.0u"inch"
    return (limit = cut.limit,
            exceeds = true,
            length = reach.length,
            spacing_limit = table.spacing,
            spacing_meets = spacing <= table.spacing,
            hx_limit = cap,
            hx_meets = hx <= cap)
end

"""
    boundary_hoop_spacing(Ash, bc, ratio, vertical_limit) -> NamedTuple

Spacing a hoop may use. Table 18.10.6.4(g) requires
`Ash/(s bc) ≥ ratio`, so `s ≤ Ash/(ratio · bc)`. The vertical spacing
already computed for the boundary (Table 18.10.6.5(b), `so`, the one-third
rule) is the other limit. The smaller one governs. `Ash` is the transverse
steel, including crossties, within one spacing and perpendicular to `bc`.
"""
function boundary_hoop_spacing(Ash, bc::Length, ratio::Real, vertical_limit::Length)
    (ustrip(u"m^2", Ash) > 0 && ustrip(u"m", bc) > 0 && ratio > 0) ||
        throw(ArgumentError("Ash, bc, and the confinement ratio must be positive"))
    ustrip(u"m", vertical_limit) > 0 ||
        throw(ArgumentError("the vertical spacing limit must be positive"))
    from_amount = Ash / (ratio * bc)
    return (
        spacing = min(from_amount, vertical_limit),
        from_amount = from_amount,
        from_vertical = vertical_limit,
        by = from_amount < vertical_limit ? :amount :
             from_amount > vertical_limit ? :vertical : :both,
    )
end
