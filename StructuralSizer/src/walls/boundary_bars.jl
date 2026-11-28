using Unitful

# Longitudinal bars added at the ends of a special wall.
#
# The distributed web ratio stays. These bars are added at each end, over the
# greater of the special-boundary length and, where §18.10.2.4 applies, 0.15ℓw.
# The area is the greater of the §18.10.2.4(a) minimum and the area the
# §22.2 check still needs. The bar is the smallest of No. 5 through No. 11
# that fits, spaced no farther than hx, with the §25.2.3 clear spacing.
# Two layers are the minimum. A thicker wall takes more layers when two would
# be farther apart than hx.

"Bar numbers tried for the added end steel, smallest first."
const BOUNDARY_END_BAR_SIZES = (5, 6, 7, 8, 9, 10, 11)

"""
    special_end_reinforcement_ratio(fc, fy) -> NamedTuple

§18.10.2.4(a). `ρ = 6√f′c / fy`, with `√f′c` and `fy` in psi. The ratio is
applied over `0.15ℓw` and the wall thickness by [`special_end_minimum_area`](@ref).

# Citation
ACI 318-19 §18.10.2.4(a) (corpus: aci-318-19, page 322).
"""
function special_end_reinforcement_ratio(fc, fy)
    fc_psi = ustrip(u"psi", fc)
    fy_psi = ustrip(u"psi", fy)
    (fc_psi > 0 && fy_psi > 0) || throw(ArgumentError(
        "end reinforcement ratio: f′c and fy must be positive"))
    return (ρ = 6 * sqrt(fc_psi) / fy_psi,)
end

"""
    special_end_minimum_area(fc, fy, lw, t) -> NamedTuple

Area of the §18.10.2.4(a) minimum at one end: `ρ · 0.15ℓw · t`.

# Citation
ACI 318-19 §18.10.2.4(a) (corpus: aci-318-19, page 322).
"""
function special_end_minimum_area(fc, fy, lw::Length, t::Length)
    (ustrip(u"m", lw) > 0 && ustrip(u"m", t) > 0) || throw(ArgumentError(
        "end reinforcement area: ℓw and the thickness must be positive"))
    ratio = special_end_reinforcement_ratio(fc, fy)
    return (ρ = ratio.ρ, area = ratio.ρ * (0.15 * lw) * t, width = 0.15 * lw)
end

"""
    special_end_zone(lw; boundary_length=nothing, code_minimum=false) -> NamedTuple

Length of the added bars in from each end. `boundary_length` is the
§18.10.6.4(a) length when an element is required. `code_minimum` adds
`0.15ℓw`. The zone is the greater of the ones that apply. Neither applies
when `zone` is `nothing`. A zone that reaches mid-length throws: the two
ends would be the same bars.

# Citation
ACI 318-19 §18.10.2.4(a) (corpus: aci-318-19, page 322): within `0.15ℓw`.
ACI 318-19 §18.10.6.4(a) (page 327): the boundary-element length.
"""
function special_end_zone(lw::Length; boundary_length::Union{Nothing,Length}=nothing,
                         code_minimum::Bool=false)
    ustrip(u"m", lw) > 0 || throw(ArgumentError("end zone: ℓw must be positive"))
    from_ratio = code_minimum ? 0.15 * lw : nothing
    if boundary_length !== nothing && ustrip(u"m", boundary_length) <= 0
        throw(ArgumentError("end zone: the boundary length must be positive"))
    end
    parts = Length[]
    boundary_length === nothing || push!(parts, boundary_length)
    from_ratio === nothing || push!(parts, from_ratio)
    zone = isempty(parts) ? nothing : maximum(parts)
    if zone !== nothing && ustrip(u"m", zone) >= ustrip(u"m", lw) / 2
        throw(ArgumentError(
            "end zone: $(zone) reaches the middle of a wall $(lw) long. " *
            "The two ends would share bars."))
    end
    return (zone = zone, from_boundary = boundary_length, from_ratio = from_ratio)
end

"""
    special_end_bar_extension(lw, Mu, Vu) -> NamedTuple

How far §18.10.2.4(b) carries the end bars past the critical section: the
greater of `ℓw` and `Mu / 3Vu`.

# Citation
ACI 318-19 §18.10.2.4(b) (corpus: aci-318-19, page 322).
"""
function special_end_bar_extension(lw::Length, Mu, Vu)
    ustrip(u"m", lw) > 0 || throw(ArgumentError("end bar extension: ℓw must be positive"))
    ustrip(u"N*m", Mu) >= 0 || throw(ArgumentError("end bar extension: Mu is taken positive"))
    ustrip(u"N", Vu) > 0 || throw(ArgumentError("end bar extension: Vu must be positive"))
    from_shear = (Mu / Vu) / 3
    return (extension = max(lw, from_shear), from_length = lw, from_shear = from_shear)
end

"""
    boundary_end_bar_layout(area, zone, thickness; cover, d_agg) -> NamedTuple

Smallest bar, No. 5 through No. 11, whose layers hold `area` inside `zone`.

Layers run through the thickness. Two is the minimum. The center spacing of
adjacent bars, along the wall and through the thickness, is at most `hx` from
[`boundary_transverse_spacing`](@ref). Clear spacing is the greatest of
1.5 in., 1.5db, and `(4/3)d_agg`. The tie is [`boundary_tie_bar_size`](@ref).

`cover` is the clear cover to the tie, the 3/4 in. [`detail_wall`](@ref) uses.
`d_agg` defaults to the 3/4 in. nominal aggregate the column sections use.
The first bar center is one cover, one tie, and half a bar in from the wall
end. The last is one tie and half a bar inside the zone.

The returned `area` is the steel actually placed at one end, which hx can
make larger than the area asked for. `inset` is the centroid of that steel,
measured from the wall end. A layout that cannot fit throws.

# Citation
ACI 318-19 §18.10.6.4(f) (corpus: aci-318-19, page 328): hx.
ACI 318-19 §25.2.3 (page 469): clear spacing in a wall boundary element.
ACI 318-19 §25.7.2.2 (page 501): tie size.
"""
function boundary_end_bar_layout(area, zone::Length, thickness::Length;
                                cover::Length=0.75u"inch",
                                d_agg::Length=DEFAULT_AGGREGATE_SIZE)
    area_in = ustrip(u"inch^2", area)
    zone_in = ustrip(u"inch", zone)
    t_in = ustrip(u"inch", thickness)
    cover_in = ustrip(u"inch", cover)
    agg_in = ustrip(u"inch", d_agg)
    (area_in > 0 && zone_in > 0 && t_in > 0 && cover_in >= 0 && agg_in > 0) ||
        throw(ArgumentError(
            "end bar layout: the area, the zone, the thickness, and the aggregate must be positive"))
    hx = boundary_transverse_spacing(thickness).hx
    hx_in = ustrip(u"inch", hx)
    for size in BOUNDARY_END_BAR_SIZES
        found = _end_bar_candidate(size, area_in, zone_in, t_in, cover_in, agg_in, hx_in, hx)
        found === nothing || return found
    end
    throw(ArgumentError(
        "end bar layout: $(area) does not fit in a $(zone) zone of a $(thickness) wall " *
        "between No. 5 and No. 11 at hx = $(hx) with the §25.2.3 clear spacing."))
end

function _end_bar_candidate(size, area_in, zone_in, t_in, cover_in, agg_in, hx_in, hx)
    db = ustrip(u"inch", rebar(size).diameter)
    Ab = ustrip(u"inch^2", rebar(size).A)
    tie = boundary_tie_bar_size(size).tie
    tie_d = ustrip(u"inch", rebar(tie).diameter)
    # §25.2.3 (corpus: aci-318-19, page 469).
    clear_min = max(1.5, 1.5 * db, (4 / 3) * agg_in)
    outer = cover_in + tie_d + db / 2
    span = t_in - 2 * outer
    span > 0 || return nothing
    layers = span <= hx_in + 1e-9 ? 2 : 1 + ceil(Int, span / hx_in - 1e-9)
    layers >= 2 || return nothing
    pitch_t = span / (layers - 1)
    (pitch_t <= hx_in + 1e-9 && pitch_t - db + 1e-9 >= clear_min) || return nothing
    inner = tie_d + db / 2
    usable = zone_in - outer - inner
    usable > 0 || return nothing
    pitch_min = db + clear_min
    n_max = 1 + floor(Int, usable / pitch_min + 1e-9)
    n_hx = usable <= hx_in + 1e-9 ? 1 : 1 + ceil(Int, usable / hx_in - 1e-9)
    n_area = max(1, ceil(Int, area_in / (layers * Ab) - 1e-9))
    n = max(n_area, n_hx)
    n <= n_max || return nothing
    spacing_in = n == 1 ? 0.0 : usable / (n - 1)
    centers = [outer + (i - 1) * spacing_in for i in 1:n]
    inset_in = sum(centers) / n
    return (
        bar = size,
        tie = tie,
        layers = layers,
        per_layer = n,
        spacing = spacing_in * u"inch",
        area = (n * layers * Ab) * u"inch^2",
        inset = inset_in * u"inch",
        hx = hx,
        clear = clear_min * u"inch",
    )
end

"""
    boundary_end_area_si(fc, fy, Es, lw, t, Ast, inset, actions, As_floor) -> Float64 or nothing

Smallest added area at each end, not below `As_floor`, at which every
`(Nu, Mu)` passes the end-bar axial-flexure check. `nothing` when the area
`0.02·ℓw·t` still fails. Areas are bare SI, and `actions` is a vector of
`(Nu, Mu)` in newtons and newton-metres. Compression is positive.

The axial ceiling is §22.4.2.1 with the web steel plus both ends. The moment
is [`wall_end_bar_capacity_si`](@ref) on a rectangle. On one flange,
`flange_at` names that end and the moment is
[`wall_flanged_c_at_axial_si`](@ref). When `tf_pos` and `tf_neg` are both
positive the section has a flange at each end
([`wall_two_flange_c_at_axial_si`](@ref)). The added bars sit at both ends.
The Cardenas closed form is not used: it has no end bars.
"""
function boundary_end_area_si(fc::Real, fy::Real, Es::Real, lw::Real, t::Real,
                             Ast::Real, inset::Real, actions, As_floor::Real;
                             flange_at::Union{Nothing, Symbol}=nothing,
                             tf::Real=0.0, bf::Real=0.0, As_flange::Real=0.0,
                             tf_pos::Real=0.0, bf_pos::Real=0.0, As_pos::Real=0.0,
                             tf_neg::Real=0.0, bf_neg::Real=0.0, As_neg::Real=0.0)
    As_floor >= 0 || throw(ArgumentError("end bar area: the floor is non-negative"))
    isempty(actions) && throw(ArgumentError("end bar area: there is no strength combination"))
    two = tf_pos > 0 && tf_neg > 0
    if two
        (tf_pos + tf_neg < lw && bf_pos + 1e-12 >= t && bf_neg + 1e-12 >= t &&
            As_pos >= 0 && As_neg >= 0) || throw(ArgumentError(
            "end bar area: the two flanges are not a section"))
    elseif flange_at !== nothing
        flange_at in (:positive, :negative) || throw(ArgumentError(
            "end bar area: the flange is at :positive or :negative (got :$flange_at)"))
        (tf > 0 && tf < lw && bf + 1e-12 >= t && As_flange >= 0) || throw(ArgumentError(
            "end bar area: the flange thickness, width, and steel area are not a section"))
    end
    function section_at(As, Nu, Mu)
        if two
            return wall_two_flange_c_at_axial_si(
                fc, fy, Es, lw, t, tf_pos, bf_pos, tf_neg, bf_neg, Ast, Nu;
                compress_positive = Mu >= 0,
                As_pos = As_pos, As_neg = As_neg, As_end = As, inset = inset)
        end
        flange_at === nothing &&
            return wall_end_bar_capacity_si(fc, fy, Es, lw, t, Ast, As, inset, Nu)
        return wall_flanged_c_at_axial_si(
            fc, fy, Es, lw, t, tf, bf, Ast, Nu;
            flange_in_compression = flange_end_compressed(flange_at, Mu),
            As_flange = As_flange, As_end = As, inset = inset)
    end
    function passes(As)
        ρ = (Ast + 2 * As) / (lw * t)
        ax = wall_pure_axial_capacity_si(fc, fy, lw, t, ρ)
        for (Nu, Mu) in actions
            Nu > 0.65 * ax.Pn_max && return false
            cap = section_at(As, Nu, Mu)
            cap.converged || return false
            abs(Mu) <= cap.φMn + 1.0 || return false
        end
        return true
    end
    passes(As_floor) && return As_floor
    hi = 0.02 * lw * t
    passes(hi) || return nothing
    lo = As_floor
    for _ in 1:40
        hi - lo <= 1e-8 && break
        mid = 0.5 * (lo + hi)
        if passes(mid)
            hi = mid
        else
            lo = mid
        end
    end
    return hi
end

"""
    check_wall_end_bar_flexure(lw, t, ρl, As_end, inset, material, Nu, Mu) -> CheckResult

Axial-flexure check of a wall with distributed `ρl` and added end bars.
Strain compatibility is the capacity. The §22.4.2.1 ceiling uses the web
steel plus both ends, with φ = 0.65.
"""
function check_wall_end_bar_flexure(lw::Length, t::Length, ρl::Real, As_end, inset,
                                   material, Nu, Mu)
    fc, fy, Es = _wall_flexure_materials(material)
    lw_m = ustrip(u"m", lw)
    t_m = ustrip(u"m", t)
    As = ustrip(u"m^2", As_end)
    inset_m = ustrip(u"m", inset)
    Nu_N = Nu isa Unitful.Quantity ? ustrip(u"N", Nu) : Float64(Nu)
    Mu_N = abs(Mu isa Unitful.Quantity ? ustrip(u"N*m", Mu) : Float64(Mu))
    Ast = ρl * lw_m * t_m
    ρ = (Ast + 2 * As) / (lw_m * t_m)
    ax = wall_pure_axial_capacity_si(fc, fy, lw_m, t_m, ρ)
    φPn = 0.65 * ax.Pn_max
    if Nu_N > φPn
        return CheckResult("in-plane axial-flexure (P-M): axial cap", false,
                           Nu_N / max(φPn, 1e-9), Nu_N, φPn, "ACI 318-19 22.4.2.1")
    end
    cap = wall_end_bar_capacity_si(fc, fy, Es, lw_m, t_m, Ast, As, inset_m, Nu_N)
    φMn = cap.converged ? max(cap.φMn, 0.0) : 0.0
    ratio = Mu_N / max(φMn, 1e-9)
    return CheckResult("in-plane axial-flexure (P-M)", Mu_N <= φMn + 1.0, ratio,
                       Mu_N, φMn, "ACI 318-19 22.2 / Table 21.2.2")
end
