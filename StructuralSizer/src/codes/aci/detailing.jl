# ==============================================================================
# Bar detailing shared by slabs, beams, columns, and footings
# ==============================================================================
#
# Hooks, development, and lap splices. Nothing here runs inside a sizing optimizer.
# Slab flexure still calls the ACI 318-11 lengths in the flat-plate module.
# ==============================================================================

"""
    standard_hook(bar_size; angle=90, role=:tension)
        -> (inside_diameter, extension)

Standard hook geometry, ACI 318-19 §25.3.1 and §25.3.2 (corpus: aci-318-19,
printed pp. 469–470).

`role = :tension` is Table 25.3.1. Inside bend diameter is `6d_b` for No. 3
through No. 8, `8d_b` for No. 9 through No. 11, and `10d_b` for No. 14 and
No. 18. The straight extension is `12d_b` for a 90-degree hook and the greater
of `4d_b` and 2.5 in. for a 180-degree hook.

`role = :stirrup` is Table 25.3.2, No. 8 and smaller. Inside bend diameter is
`4d_b` through No. 5 and `6d_b` for No. 6 through No. 8. Straight extensions:
a 90-degree hook is the greater of `6d_b` and 3 in. through No. 5, and `12d_b`
for No. 6 through No. 8; a 135-degree hook is the greater of `6d_b` and 3 in.;
a 180-degree hook is the greater of `4d_b` and 2.5 in. The corpus text lists
four extension entries for the six bend rows; the 135-degree and 180-degree
extensions are each one shared cell across the two bar-size rows.

`angle` is 90, 135, or 180. Table 25.3.1 has no 135-degree hook.
"""
function standard_hook(bar_size::Int; angle::Int=90, role::Symbol=:tension)
    db = bar_diameter(bar_size)
    if role === :tension
        angle in (90, 180) || throw(ArgumentError(
            "Table 25.3.1 has 90-degree and 180-degree hooks, not $angle."))
        bend = bar_size <= 8 ? 6db : bar_size <= 11 ? 8db : 10db
        ext = angle == 90 ? 12db : max(4db, 2.5u"inch")
    elseif role === :stirrup
        bar_size <= 8 || throw(ArgumentError(
            "Table 25.3.2 stirrup hooks stop at No. 8 (got #$bar_size)."))
        angle in (90, 135, 180) || throw(ArgumentError(
            "Table 25.3.2 has 90-, 135-, and 180-degree hooks, not $angle."))
        bend = bar_size <= 5 ? 4db : 6db
        ext = if angle == 90 && bar_size >= 6
            12db
        elseif angle == 180
            max(4db, 2.5u"inch")
        else
            max(6db, 3.0u"inch")
        end
    else
        throw(ArgumentError("hook role must be :tension or :stirrup, got $role"))
    end
    return (inside_diameter = uconvert(u"m", bend), extension = uconvert(u"m", ext))
end

"""
    hook_centerline_length(bar_size; angle=90, role=:tension) -> Length

Length of one hook along the bar centerline: the circular arc plus the
straight extension from [`standard_hook`](@ref).

The arc radius is half the inside bend diameter plus half the nominal bar
diameter. That is the centerline of a round bar bent on the table's inside
diameter. It is geometry, not a code length.
"""
function hook_centerline_length(bar_size::Int; angle::Int=90, role::Symbol=:tension)
    hook = standard_hook(bar_size; angle=angle, role=role)
    db = bar_diameter(bar_size)
    radius = (hook.inside_diameter + db) / 2
    arc = deg2rad(angle) * radius
    return uconvert(u"m", arc + hook.extension)
end

"""
    BarSet(bar_size, count, centerline)

`count` identical bars, each of centerline length `centerline`. Mass uses the
ASTM A615 weight per foot in the rebar catalog, not `π/4·d_b²·ρ`, because the
catalog area is not the area of the nominal diameter.
"""
struct BarSet
    bar_size::Int
    count::Int
    centerline::typeof(1.0u"m")
end

function BarSet(bar_size::Int, count::Int, centerline)
    count >= 0 || throw(ArgumentError("bar count must be ≥ 0"))
    BarSet(bar_size, count, uconvert(u"m", centerline))
end

"""Mass of every bar in the set, from the catalog weight per unit length."""
function bar_set_mass(set::BarSet)
    w = rebar(set.bar_size).weight
    return uconvert(u"kg", set.count * w * set.centerline)
end

"""Embodied carbon of the set: mass times `ecc` (kgCO₂e per kg)."""
function bar_set_ec(set::BarSet, ecc)
    return uconvert(u"kgCO2e", bar_set_mass(set) * ecc)
end

# ==============================================================================
# Development and lap splices — ACI 318-19 §25.4 and §25.5
# ==============================================================================

"""√f′c in psi, not above 100. ACI 318-19 §25.4.1.4 (corpus: aci-318-19, printed p. 471)."""
_development_sqrt_fc(fc::Pressure) = min(sqrt(ustrip(u"psi", fc)), 100.0)

"""Table 25.4.2.5 λ: 0.75 lightweight, 1.0 normalweight. Printed p. 474."""
function _development_λ(λ::Real)
    (isapprox(λ, 0.75; atol=1e-6) || isapprox(λ, 1.0; atol=1e-6)) || throw(ArgumentError(
        "ACI 318-19 Table 25.4.2.5 λ is 0.75 for lightweight concrete and 1.0 " *
        "for normalweight (got $λ)."))
    return Float64(λ)
end

"""
Table 25.4.2.5 ψg. Grade 40 and Grade 60 are 1.0, Grade 80 is 1.15, Grade 100
is 1.3. Grade 75 is not a row in the table.

ENGINEERING JUDGMENT (project decision): Grade 75 uses ψg = 1.0. With fy = 75 ksi
in the equation, ℓd is 75/60 = 1.25 times the Grade 60 length. Any other grade
throws rather than borrowing a neighboring factor.
"""
function _grade_factor(fy::Pressure)
    fy_psi = ustrip(u"psi", fy)
    for (grade, factor) in ((40_000.0, 1.0), (60_000.0, 1.0), (75_000.0, 1.0),
                            (80_000.0, 1.15), (100_000.0, 1.3))
        abs(fy_psi - grade) <= 1.0 && return factor
    end
    throw(ArgumentError(
        "ACI 318-19 Table 25.4.2.5 has Grade 40, 60, 80, and 100; Grade 75 uses " *
        "ψg = 1.0 by project decision. No factor for " *
        "(fy = $(round(fy_psi; digits=1)) psi)."))
end

"""ψt is 1.3 for more than 12 in. of fresh concrete below the bar, otherwise 1.0."""
function _casting_factor(ψt::Real)
    (isapprox(ψt, 1.0; atol=1e-6) || isapprox(ψt, 1.3; atol=1e-6)) || throw(ArgumentError(
        "ACI 318-19 Table 25.4.2.5 ψt is 1.3 or 1.0 (got $ψt)."))
    return Float64(ψt)
end

"""
Straight-bar ψe, Table 25.4.2.5. `coating` is the rebar material's coating
([`REBAR_COATINGS`](@ref)). Uncoated or galvanized: 1.0. Epoxy or zinc and epoxy
dual-coated: 1.5 when `epoxy_close` (clear cover under 3d_b or clear spacing
under 6d_b), otherwise 1.2.
"""
function _straight_epoxy_factor(coating::Symbol, epoxy_close::Bool)
    is_epoxy_coated(coating) || return 1.0
    return epoxy_close ? 1.5 : 1.2
end

"""ψt·ψe, not above 1.7, times ψg. Table 25.4.2.5 footnote [1]."""
function _tension_modifier(fy::Pressure, ψt::Real, coating::Symbol, epoxy_close::Bool)
    ψtψe = min(_casting_factor(ψt) * _straight_epoxy_factor(coating, epoxy_close), 1.7)
    return ψtψe * _grade_factor(fy)
end

"""
§25.4.10.1 ratio (As,required)/(As,provided). It only shortens the calculated
length. The caller leaves it at 1 where §25.4.10.2 prohibits the reduction:
noncontinuous supports, development for fy, bars required to be continuous,
hooked or headed or mechanical anchorages, and the seismic cases in (e) and (f).
"""
function _excess_ratio(excess::Real)
    0 < excess <= 1 || throw(ArgumentError(
        "excess reinforcement ratio must be in (0, 1] (got $excess)."))
    return Float64(excess)
end

"""
Calculated tension development length in inches, Table 25.4.2.3, before the
12 in. floor of §25.4.2.1(b). `favorable_cover` is the first row of the table
(clear spacing and cover at least d_b with code-minimum ties, or clear spacing
at least 2d_b and cover at least d_b). Otherwise the "other cases" row.
"""
function _tension_ld_in(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real;
                         ψt::Real, coating::Symbol, epoxy_close::Bool,
                         favorable_cover::Bool, excess::Real)
    db = ustrip(u"inch", bar_diameter(bar_size))
    small = bar_size <= 6
    if favorable_cover
        lead, denom = 1.0, small ? 25.0 : 20.0
    else
        lead, denom = 3.0, small ? 50.0 : 40.0
    end
    fy_psi = ustrip(u"psi", fy)
    modifier = _tension_modifier(fy, ψt, coating, epoxy_close)
    ld = (lead * fy_psi * modifier) / (denom * _development_λ(λ) * _development_sqrt_fc(fc)) * db
    return _excess_ratio(excess) * ld
end

"""
    straight_development_length(bar_size, fc, fy, λ=1; ψt=1, coating=:uncoated,
                                 epoxy_close=false, favorable_cover=false, excess=1) -> Length

ACI 318-19 §25.4.2.1 and Table 25.4.2.3 (corpus: aci-318-19, printed pp. 471–472).
The greater of the table length and 12 in. `excess` is §25.4.10.1 and defaults
to 1, so the reduction is not applied unless the caller sets it. The product
ψt·ψe is not taken above 1.7. √f′c is not taken above 100 psi.

`ψt = 1.3` when more than 12 in. of fresh concrete is cast below the bar.
`coating` is the rebar material's coating; `epoxy_close` selects the 1.5 epoxy
row (see `_straight_epoxy_factor`).
"""
function straight_development_length(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real=1.0;
                                      ψt::Real=1.0, coating::Symbol=:uncoated,
                                      epoxy_close::Bool=false,
                                      favorable_cover::Bool=false, excess::Real=1.0)
    ld = _tension_ld_in(bar_size, fc, fy, λ; ψt=ψt, coating=coating, epoxy_close=epoxy_close,
                         favorable_cover=favorable_cover, excess=excess)
    return max(ld, 12.0) * u"inch"
end

"""
    hooked_bar_development_length(bar_size, fc, fy, λ=1; coating=:uncoated,
                                   confined=false, side_cover=false) -> Length

ACI 318-19 §25.4.3.1 and Table 25.4.3.2 (corpus: aci-318-19, printed pp. 474–475).
The greater of `(fy ψe ψr ψo ψc / (55 λ √f′c)) d_b^1.5`, `8d_b`, and 6 in.
Eq. 25.4.3.1(a) is empirical: fy and f′c in psi, d_b in inches, ℓdh in inches.

ψe is 1.2 for any epoxy coating and 1.0 otherwise; the straight-bar 1.5 factor
is not in this table. ψr is 1.0 for No. 11 and smaller when `confined` (Ath at
least 0.4 Ahs, or center-to-center spacing at least 6d_b), otherwise 1.6.
ψo is 1.0 for No. 11 and smaller when `side_cover` (column-core side cover at
least 2.5 in., or side cover at least 6d_b), otherwise 1.25. ψc is
`f′c/15000 + 0.6` below 6000 psi and 1.0 at 6000 psi and above. §25.4.10 does
not reduce hooked bars.
"""
function hooked_bar_development_length(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real=1.0;
                                        coating::Symbol=:uncoated, confined::Bool=false,
                                        side_cover::Bool=false)
    db = ustrip(u"inch", bar_diameter(bar_size))
    fy_psi = ustrip(u"psi", fy)
    fc_psi = ustrip(u"psi", fc)
    ψe = is_epoxy_coated(coating) ? 1.2 : 1.0
    ψr = bar_size <= 11 && confined ? 1.0 : 1.6
    ψo = bar_size <= 11 && side_cover ? 1.0 : 1.25
    ψc = fc_psi < 6000 ? fc_psi / 15_000 + 0.6 : 1.0
    ldh = (fy_psi * ψe * ψr * ψo * ψc) /
          (55 * _development_λ(λ) * _development_sqrt_fc(fc)) * db^1.5
    return max(ldh, 8 * db, 6.0) * u"inch"
end

"""
    compression_development_length(bar_size, fc, fy, λ=1; enclosed=false, excess=1)
        -> Length

ACI 318-19 §25.4.9 (corpus: aci-318-19, printed p. 487). The greater of
`(fy ψr / (50 λ √f′c)) d_b`, `0.0003 fy ψr d_b`, and 8 in. ψr is 0.75 when
`enclosed` (spiral, circular tie, No. 4 ties, or hoops at the spacing in
Table 25.4.9.3) and 1.0 otherwise. `excess` is §25.4.10.1 applied to the
calculated length, not below 8 in.
"""
function compression_development_length(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real=1.0;
                                         enclosed::Bool=false, excess::Real=1.0)
    db = ustrip(u"inch", bar_diameter(bar_size))
    fy_psi = ustrip(u"psi", fy)
    ψr = enclosed ? 0.75 : 1.0
    bond = fy_psi * ψr / (50 * _development_λ(λ) * _development_sqrt_fc(fc)) * db
    bearing = 0.0003 * fy_psi * ψr * db
    return max(_excess_ratio(excess) * max(bond, bearing), 8.0) * u"inch"
end

"""
    tension_lap_length(bar_size, fc, fy, λ=1; as_ratio, percent_spliced, kwargs...)
        -> Length

ACI 318-19 Table 25.5.2.1 (corpus: aci-318-19, printed p. 489). Class A,
`max(1.0 ℓd, 12 in.)`, when `as_ratio` ≥ 2 and at most 50 percent of the bars
are spliced within the lap. Otherwise Class B, `max(1.3 ℓd, 12 in.)`. `ℓd` is
§25.4.2.1(a) only: the 12 in. floor is applied to the splice, not before the
1.3 factor.

§25.5.1.1 (printed p. 488) does not allow a tension lap above No. 11.
§25.5.1.4 does not allow the §25.4.10.1 excess-reinforcement reduction in a
lap length. The remaining keywords are those of [`straight_development_length`](@ref).
"""
function tension_lap_length(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real=1.0;
                             as_ratio::Real, percent_spliced::Real,
                             ψt::Real=1.0, coating::Symbol=:uncoated,
                             epoxy_close::Bool=false, favorable_cover::Bool=false)
    bar_size <= 11 || throw(ArgumentError(
        "ACI 318-19 §25.5.1.1 does not allow a lap splice above No. 11 (got #$bar_size)."))
    as_ratio > 0 || throw(ArgumentError("As,provided/As,required must be positive."))
    0 <= percent_spliced <= 100 || throw(ArgumentError(
        "percent of As spliced must be from 0 to 100 (got $percent_spliced)."))
    ld = _tension_ld_in(bar_size, fc, fy, λ; ψt=ψt, coating=coating, epoxy_close=epoxy_close,
                         favorable_cover=favorable_cover, excess=1.0)
    factor = as_ratio >= 2 && percent_spliced <= 50 ? 1.0 : 1.3
    return max(factor * ld, 12.0) * u"inch"
end

"""
    compression_lap_length(bar_size, fc, fy; as_ratio=2, percent_spliced=100, kwargs...)
        -> Length

ACI 318-19 §25.5.5.1 (corpus: aci-318-19, printed p. 492). For fy ≤ 60 ksi,
the longer of `0.0005 fy d_b` and 12 in. For 60 ksi < fy ≤ 80 ksi, the longer
of `(0.0009 fy − 24) d_b` and 12 in. For fy > 80 ksi, the longer of
`(0.0009 fy − 24) d_b` and the Table 25.5.2.1 tension lap; that last comparison
needs `as_ratio` and `percent_spliced`. Where f′c < 3000 psi the lap is
increased by one-third.

§25.5.5.2 does not allow the splice above No. 11. A No. 14 or No. 18 bar
lapped to a No. 11 or smaller bar is §25.5.5.4 and is not this function.
"""
function compression_lap_length(bar_size::Int, fc::Pressure, fy::Pressure;
                                 as_ratio::Real=2.0, percent_spliced::Real=100.0,
                                 ψt::Real=1.0, coating::Symbol=:uncoated,
                                 epoxy_close::Bool=false, favorable_cover::Bool=false,
                                 λ::Real=1.0)
    bar_size <= 11 || throw(ArgumentError(
        "ACI 318-19 §25.5.5.2 does not allow a compression lap above No. 11 " *
        "(got #$bar_size). §25.5.5.4 covers a No. 14 or No. 18 bar lapped to a smaller bar."))
    db = ustrip(u"inch", bar_diameter(bar_size))
    fy_psi = ustrip(u"psi", fy)
    if fy_psi <= 60_000 + 0.5
        raw = max(0.0005 * fy_psi * db, 12.0)
    elseif fy_psi <= 80_000 + 0.5
        raw = max((0.0009 * fy_psi - 24) * db, 12.0)
    else
        tension = ustrip(u"inch", tension_lap_length(
            bar_size, fc, fy, λ; as_ratio=as_ratio, percent_spliced=percent_spliced,
            ψt=ψt, coating=coating, epoxy_close=epoxy_close, favorable_cover=favorable_cover))
        raw = max((0.0009 * fy_psi - 24) * db, tension)
    end
    ustrip(u"psi", fc) < 3000 && (raw *= 4 / 3)
    return raw * u"inch"
end
