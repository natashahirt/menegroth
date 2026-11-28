# =============================================================================
# Closed Stirrup Design for Punching Shear — ACI 318-11 §11.11.3
# =============================================================================
#
# Closed stirrups (bars or wires, single- or multiple-leg) are an alternative
# to headed shear studs for punching shear reinforcement.
#
# Key differences from headed studs (§11.11.5):
#   - Vc capped at 2λ√f'c (vs 3λ√f'c for studs)          §11.11.3.1
#   - Vn capped at 6√f'c·b0·d (vs 8√f'c for studs)       §11.11.3.2
#   - Minimum d ≥ 6 in. AND d ≥ 16·d_b                    §11.11.3
#   - Radial spacing ≤ d/2, tangential spacing ≤ 2d        §11.11.3.3
#   - Outer section d/2 beyond the last line ≤ φ·2λ√f'c    §11.11.7.2(b)
#   - Anchorage per §12.13 (difficult in slabs < 10 in.)
#
# Vs is computed per Eq. (11-15): Vs = Av·fyt·d / s
# where Av = total area of all legs on one peripheral line.
#
# =============================================================================

using Unitful
using Unitful: @u_str
using Asap: Length, Pressure, Force, Moment, Area

"""ACI standard bar sizes commonly used for closed stirrup punching shear reinforcement (#3, #4, #5)."""
const STIRRUP_BAR_SIZES = [3, 4, 5]

"""
    design_closed_stirrups(vu, fc, β, αs, b0, d, position, fyt, bar_size;
                           λ=1.0, φ=0.75, c1=nothing, c2=nothing, qu=nothing,
                           Vu=nothing, M_about_x=nothing, M_about_y=nothing,
                           max_extent=nothing)

Design closed stirrup reinforcement for a punching shear failure.

# Design Steps (ACI 318-11 §11.11.3):
1. Check minimum depth: d ≥ 6 in. and d ≥ 16·d_b
2. Compute vc with stirrups: min(Eq. 11-31, 11-32, 11-33), capped at 2λ√f'c
3. Compute required vs = vu/φ − vcs
4. Check Vn ≤ 6√f'c·b0·d
5. Place legs at both ends of each face, ≤ 2d apart on the first line (§11.11.3.3)
6. Compute spacing s = Av·fyt / (b0·vs)
7. Apply spacing limits: s ≤ d/2 radial, first line ≤ d/2 from face
8. Add peripheral lines until the section d/2 beyond the last line satisfies
   vu ≤ φ·2λ√f'c (§11.11.7.2(b))

# Arguments
- `vu`: Factored shear stress demand
- `fc`: Concrete compressive strength
- `β`: Column aspect ratio
- `αs`: Location factor (40/30/20)
- `b0`: Critical perimeter
- `d`: Effective depth
- `position`: Column position (:interior, :edge, :corner)
- `fyt`: Stirrup yield strength
- `bar_size`: Stirrup bar designation (3, 4, or 5)

# Keyword Arguments
- `λ`: Lightweight concrete factor (default: 1.0)
- `φ`: Strength reduction factor (default: 0.75)
- `c1`, `c2`, `qu`, `Vu`, `M_about_x`, `M_about_y`, `max_extent`: outer section
  geometry, demand, and extent limit, as in [`design_shear_studs`](@ref).

# Returns
`ClosedStirrupDesign` struct

# Reference
- ACI 318-11 §11.11.3, §11.11.7.2(b) (corpus: aci-318-11, pages 202–204, 210)
"""
function design_closed_stirrups(
    vu::Pressure,
    fc::Pressure,
    β::Float64,
    αs::Int,
    b0::Length,
    d::Length,
    position::Symbol,
    fyt::Pressure,
    bar_size::Int;
    λ::Float64 = 1.0,
    φ::Float64 = 0.75,
    c1::Union{Length, Nothing} = nothing,
    c2::Union{Length, Nothing} = nothing,
    qu::Union{Pressure, Nothing} = nothing,
    Vu::Union{Force, Nothing} = nothing,
    M_about_x::Union{Moment, Nothing} = nothing,
    M_about_y::Union{Moment, Nothing} = nothing,
    max_extent::Union{Length, Nothing} = nothing,
)
    d_in = ustrip(u"inch", d)
    b0_in = ustrip(u"inch", b0)
    vu_psi = ustrip(u"psi", vu)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    fyt_psi = ustrip(u"psi", fyt)
    fyt_unit = fyt_psi * u"psi"

    Ab = ustrip(u"inch^2", bar_area(bar_size))
    db = ustrip(u"inch", bar_diameter(bar_size))

    # ─── Check minimum depth (§11.11.3) ───
    # d ≥ 6 in. and d ≥ 16·d_b
    d_min = max(6.0, 16.0 * db)
    if d_in < d_min
        return ClosedStirrupDesign(
            required = true,
            bar_size = bar_size,
            fyt = fyt_unit,
            n_legs = 0,
            n_lines = 0,
            s0 = 0.0u"inch",
            s = 0.0u"inch",
            Av_per_line = 0.0u"inch^2",
            vs = 0.0u"psi",
            vcs = 0.0u"psi",
            vc_max = 6.0 * sqrt_fc * u"psi",
            outer_ok = false
        )
    end

    # ─── Maximum nominal shear strength (§11.11.3.2) ───
    # Vn ≤ 6√f'c·b0·d → vn_max = 6√f'c
    vc_max = 6.0 * λ * sqrt_fc

    if vu_psi > φ * vc_max
        # Demand exceeds maximum capacity with stirrups
        return ClosedStirrupDesign(
            required = true,
            bar_size = bar_size,
            fyt = fyt_unit,
            n_legs = 0,
            n_lines = 0,
            s0 = 0.0u"inch",
            s = 0.0u"inch",
            Av_per_line = 0.0u"inch^2",
            vs = 0.0u"psi",
            vcs = 0.0u"psi",
            vc_max = vc_max * u"psi",
            outer_ok = false
        )
    end

    # ─── Concrete contribution with stirrups (§11.11.3.1) ───
    # Vc ≤ 2λ√f'c (lower than studs which get 3λ√f'c)
    # ACI 318-19 Table 22.6.6.1: concrete terms carry λs (Eq. 22.5.5.1.3) and
    # √f'c ≤ 100 psi (§22.6.3.1). λs = 1 is permitted by §22.6.6.2 and not used.
    λs_v = size_effect_factor(d)
    sqrt_fc_v = _shear_sqrt_fc(fc)
    vc_a = (2 + 4 / β) * λs_v * λ * sqrt_fc_v               # Eq. (11-31)
    vc_b = (αs * d_in / b0_in + 2) * λs_v * λ * sqrt_fc_v   # Eq. (11-32)
    vc_c = 4 * λs_v * λ * sqrt_fc_v                          # Eq. (11-33)
    vcs = min(min(vc_a, vc_b, vc_c), 2.0 * λs_v * λ * sqrt_fc_v)  # Table 22.6.6.1(a)

    # ─── Required steel contribution ───
    vs_reqd = max(vu_psi / φ - vcs, 0.0)

    outer = _outer_section_inputs(vu, b0, d, position, c1, c2, Vu, M_about_x, M_about_y)

    # ─── Legs per peripheral line ───
    # Legs at both ends of each face, ≤ 2d apart parallel to the face (§11.11.3.3)
    n_legs = reinforcement_line_count(outer.c1, outer.c2, d, position)

    # Total Av per peripheral line
    Av_per_line = n_legs * Ab

    # ─── Required spacing (Eq. 11-15 rearranged) ───
    # vs = Av·fyt / (b0·s) → s = Av·fyt / (b0·vs)
    if vs_reqd > 0
        s_reqd = Av_per_line * fyt_psi / (b0_in * vs_reqd)
    else
        s_reqd = d_in / 2  # Use max allowed
    end

    # ─── Spacing limits (§11.11.3.3) ───
    # Radial spacing: s ≤ d/2 (always, unlike studs which allow 0.75d)
    s_max = d_in / 2
    s = min(s_reqd, s_max)

    # First stirrup line: ≤ d/2 from column face
    s0 = d_in / 2

    # Actual vs provided
    vs_provided = Av_per_line * fyt_psi / (b0_in * s)

    # ─── Outer section check (§11.11.7.2(b)) ───
    n_max = max_reinforcement_lines(s0 * u"inch", s * u"inch"; max_extent = max_extent)
    lines = design_outer_lines(s0 * u"inch", s * u"inch", d, fc, position, outer;
                               qu = qu, λ = λ, φ = φ, n_max = n_max)
    n_lines = lines.n
    outer_ok = lines.ok

    return ClosedStirrupDesign(
        required = true,
        bar_size = bar_size,
        fyt = fyt_unit,
        n_legs = n_legs,
        n_lines = n_lines,
        s0 = s0 * u"inch",
        s = s * u"inch",
        Av_per_line = Av_per_line * u"inch^2",
        vs = vs_provided * u"psi",
        vcs = vcs * u"psi",
        vc_max = vc_max * u"psi",
        outer_ok = outer_ok
    )
end

"""
    check_punching_with_stirrups(vu, stirrups::ClosedStirrupDesign; φ=0.75)

Check punching shear adequacy with closed stirrup reinforcement.

# Returns
NamedTuple (ok, ratio, message)
"""
function check_punching_with_stirrups(vu::Pressure, stirrups::ClosedStirrupDesign;
                                       φ::Float64 = 0.75)
    if !stirrups.required || stirrups.n_legs == 0
        return (ok=false, ratio=Inf, message="Stirrups not designed or inadequate")
    end

    vu_psi = ustrip(u"psi", vu)
    vcs_psi = ustrip(u"psi", stirrups.vcs)
    vs_psi = ustrip(u"psi", stirrups.vs)
    vc_max_psi = ustrip(u"psi", stirrups.vc_max)

    vc_total = min(vcs_psi + vs_psi, vc_max_psi)
    ratio = vu_psi / (φ * vc_total)
    ok = ratio <= 1.0 && stirrups.outer_ok

    msg = if ok
        "OK (stirrups #$(stirrups.bar_size)): vu/φvc = $(round(ratio, digits=3))"
    elseif !stirrups.outer_ok
        "NG: Outer section fails — extend stirrup zone"
    else
        "NG (stirrups): vu/φvc = $(round(ratio, digits=3)) > 1.0"
    end

    return (ok=ok, ratio=ratio, message=msg)
end
