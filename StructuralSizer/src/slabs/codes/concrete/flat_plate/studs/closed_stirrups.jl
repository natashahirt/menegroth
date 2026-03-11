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
                           λ=1.0, φ=0.75, c1=nothing, c2=nothing, qu=nothing)

Design closed stirrup reinforcement for a punching shear failure.

# Design Steps (ACI 318-11 §11.11.3):
1. Check minimum depth: d ≥ 6 in. and d ≥ 16·d_b
2. Compute vc with stirrups: min(Eq. 11-31, 11-32, 11-33), capped at 2λ√f'c
3. Compute required vs = vu/φ − vcs
4. Check Vn ≤ 6√f'c·b0·d
5. Select number of legs based on position
6. Compute spacing s = Av·fyt / (b0·vs)
7. Apply spacing limits: s ≤ d/2 radial, first line ≤ d/2 from face
8. Determine number of peripheral lines for outer section adequacy

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
- `c1`, `c2`: Column dimensions (for outer section geometry; optional)
- `qu`: Factored uniform pressure (for outer section Vu reduction; optional)

# Returns
`ClosedStirrupDesign` struct

# Reference
- ACI 318-11 §11.11.3
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
    qu::Union{Pressure, Nothing} = nothing
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
    vc_a = (2 + 4 / β) * λ * sqrt_fc               # Eq. (11-31)
    vc_b = (αs * d_in / b0_in + 2) * λ * sqrt_fc   # Eq. (11-32)
    vc_c = 4 * λ * sqrt_fc                          # Eq. (11-33)
    vcs = min(min(vc_a, vc_b, vc_c), 2.0 * λ * sqrt_fc)  # §11.11.3.1 cap

    # ─── Required steel contribution ───
    vs_reqd = max(vu_psi / φ - vcs, 0.0)

    # ─── Number of legs per peripheral line ───
    # Closed stirrups: 2 legs per stirrup, multiple stirrups per line
    # Minimum 2 legs per face → n_legs based on position
    n_legs = position == :interior ? 8 :   # 2 per face × 4 faces
             position == :edge ? 6 :       # 2 per face × 3 faces
             4                             # 2 per face × 2 faces

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

    # ─── Outer section check ───
    # Beyond the last peripheral line, check at d/2
    vc_out = punching_capacity_outer(fc, d; λ=λ)
    vc_out_psi = ustrip(u"psi", vc_out)

    n_lines_min = 3
    n_lines = n_lines_min
    stud_zone = s0 + (n_lines - 1) * s
    total_offset_in = stud_zone + d_in / 2

    if !isnothing(c1) && !isnothing(c2) && !isnothing(qu)
        c1_in = ustrip(u"inch", c1)
        c2_in_col = ustrip(u"inch", c2)

        if position == :interior
            b1_out = c1_in + 2 * total_offset_in
            b2_out = c2_in_col + 2 * total_offset_in
            b0_out = 2 * b1_out + 2 * b2_out
            A_enclosed_in2 = b1_out * b2_out
        elseif position == :edge
            b1_out = c1_in / 2 + total_offset_in
            b2_out = c2_in_col + 2 * total_offset_in
            b0_out = 2 * b1_out + b2_out
            A_enclosed_in2 = b1_out * b2_out
        else  # :corner
            b1_out = c1_in / 2 + total_offset_in
            b2_out = c2_in_col / 2 + total_offset_in
            b0_out = b1_out + b2_out
            A_enclosed_in2 = b1_out * b2_out
        end

        Vu_total_psi_in = vu_psi * b0_in * d_in
        qu_psi = ustrip(u"psi", qu)
        load_in_zone = qu_psi * A_enclosed_in2
        Vu_outer_lb = max(Vu_total_psi_in - load_in_zone, 0.0)
        vu_out_psi = Vu_outer_lb / (b0_out * d_in)
    else
        n_sides = position == :interior ? 8 :
                  position == :edge ? 6 : 4
        b0_out = b0_in + n_sides * total_offset_in
        vu_out_psi = vu_psi * b0_in / b0_out
    end

    outer_ok = φ * vc_out_psi >= vu_out_psi

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
