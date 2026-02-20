# =============================================================================
# Steel Fire Protection Sizing
# =============================================================================
#
# Compute required SFRM or intumescent coating thickness for steel members.
#
# References:
#   UL Design No. X772  — SFRM on steel columns (contour, 4-sided)
#                          Equation: h = R / (1.05(W/D) + 0.61)
#   UL Design No. N643  — Intumescent on steel beams (3-sided, table lookup)
#   AISC Design Guide 19 — Fire Resistance of Structural Steel Framing
#
# Perimeter convention (from AISC shapes database):
#   PA = shape perimeter minus one flange surface (beams, 3-sided)
#   PB = full shape perimeter (columns, 4-sided)
#
# =============================================================================

# =============================================================================
# SFRM (Spray-Applied Fire Resistive Material) — UL X772
# =============================================================================

"""
    sfrm_thickness_x772(fire_rating, W_D) -> Float64

Required SFRM thickness (inches) for a given fire rating and W/D ratio.

UL Design No. X772 equation for contour-sprayed steel members:

    h = R / (1.05 × (W/D) + 0.61)

where:
- h = SFRM thickness (in.), valid range 0.25–3.875"
- R = fire resistance rating (hours, 1–4)
- W/D = weight-to-heated-perimeter ratio (lb/ft / in.)
- W/D valid range: 0.33–6.62

This equation is for 4-sided column exposure. For beams (3-sided, top flange
against deck), use the beam's PA perimeter — conservative since the equation
was calibrated for the more severe 4-sided condition.

# Arguments
- `fire_rating::Real`: Rating in hours (1, 1.5, 2, 3, or 4)
- `W_D::Real`: Weight-to-heated-perimeter ratio (lb/ft ÷ in.)

# Returns
SFRM thickness in inches (Float64). Clamped to minimum 0.25".
"""
function sfrm_thickness_x772(fire_rating::Real, W_D::Real)
    R = Float64(fire_rating)
    R <= 0 && return 0.0
    wd = Float64(W_D)
    wd <= 0 && throw(ArgumentError("W/D must be positive, got $wd"))

    h = R / (1.05 * wd + 0.61)

    # UL X772 validity: h ∈ [0.25, 3.875]
    return max(h, 0.25)
end


# =============================================================================
# Intumescent Coating — UL N643 (Carboline Thermo-Sorb E)
# =============================================================================
#
# UL N643 provides table-based thicknesses for mastic/intumescent coatings
# on W-shape beams (3-sided exposure). Thicknesses are much thinner than SFRM.
#
# The table is sorted by W/D ratio. Rather than embedding the full ~200-row
# table, we use a piecewise-linear interpolation of the key breakpoints.
#
# Unrestrained beam ratings: 1, 1.5, 2 hr
# Restrained beam ratings:   1, 1.5, 2, 3 hr
# =============================================================================

# Breakpoint tables: (W/D, thickness_in) — from UL N643 pages 2–10
# Unrestrained beams — 1 HR: all 0.074" for W/D < ~1.75, then 0.043"
const _N643_UNRESTRAINED_1HR = [
    (0.67, 0.074), (1.75, 0.043), (8.0, 0.043)
]

# Unrestrained — 1.5 HR
const _N643_UNRESTRAINED_1_5HR = [
    (0.67, 0.117), (0.72, 0.110), (0.80, 0.100), (0.90, 0.091),
    (1.00, 0.081), (1.10, 0.075), (1.20, 0.069), (1.40, 0.059),
    (1.60, 0.053), (1.75, 0.043), (8.0, 0.043)
]

# Unrestrained — 2 HR
const _N643_UNRESTRAINED_2HR = [
    (0.76, 0.253), (0.80, 0.241), (0.90, 0.219), (1.00, 0.196),
    (1.10, 0.183), (1.20, 0.166), (1.40, 0.147), (1.60, 0.127),
    (1.80, 0.104), (2.00, 0.104), (2.50, 0.088), (3.00, 0.068),
    (4.00, 0.052), (5.00, 0.043), (8.0, 0.043)
]

# Restrained — 2 HR (all 0.074" for low W/D, drops to 0.043")
const _N643_RESTRAINED_2HR = [
    (0.67, 0.102), (0.80, 0.092), (0.90, 0.086), (1.00, 0.079),
    (1.10, 0.076), (1.20, 0.068), (1.40, 0.059), (1.60, 0.053),
    (1.75, 0.043), (8.0, 0.043)
]

# Restrained — 3 HR (from page 10: 0.139 plateau, no NR entries)
const _N643_RESTRAINED_3HR = [
    (0.67, 0.139), (2.13, 0.139), (8.0, 0.139)
]

"""Piecewise-linear interpolation on a sorted (x, y) breakpoint table."""
function _interp_table(table::Vector{Tuple{Float64, Float64}}, wd::Float64)
    wd <= table[1][1] && return table[1][2]
    wd >= table[end][1] && return table[end][2]
    for i in 1:(length(table) - 1)
        x0, y0 = table[i]
        x1, y1 = table[i + 1]
        if wd <= x1
            frac = (wd - x0) / (x1 - x0)
            return y0 + frac * (y1 - y0)
        end
    end
    return table[end][2]
end

"""
    intumescent_thickness_n643(fire_rating, W_D; restrained=false) -> Float64

Required intumescent coating thickness (inches) from UL N643.

Uses piecewise-linear interpolation of the UL N643 table for Carboline
Thermo-Sorb E mastic/intumescent coating on W-shape beams.

# Arguments
- `fire_rating::Real`: Rating in hours. Unrestrained: 1, 1.5, 2.
  Restrained: 1, 1.5, 2, 3.
- `W_D::Real`: Weight-to-heated-perimeter ratio (lb/ft ÷ in.)
- `restrained::Bool`: Restrained beam condition (default `false`)

# Returns
Intumescent thickness in inches (Float64).

# Throws
`ArgumentError` if the fire rating is not available for the condition.
"""
function intumescent_thickness_n643(fire_rating::Real, W_D::Real; restrained::Bool=false)
    R = Float64(fire_rating)
    R <= 0 && return 0.0
    wd = Float64(W_D)
    wd <= 0 && throw(ArgumentError("W/D must be positive, got $wd"))

    if !restrained
        R == 1.0 && return _interp_table(_N643_UNRESTRAINED_1HR, wd)
        R == 1.5 && return _interp_table(_N643_UNRESTRAINED_1_5HR, wd)
        R == 2.0 && return _interp_table(_N643_UNRESTRAINED_2HR, wd)
        throw(ArgumentError(
            "UL N643 unrestrained beam: fire_rating must be 1, 1.5, or 2 hr (got $R)"))
    else
        R == 1.0 && return _interp_table(_N643_UNRESTRAINED_1HR, wd)   # same as unrestrained
        R == 1.5 && return _interp_table(_N643_UNRESTRAINED_1HR, wd)   # 1.5 restrained ≈ 1 hr
        R == 2.0 && return _interp_table(_N643_RESTRAINED_2HR, wd)
        R == 3.0 && return _interp_table(_N643_RESTRAINED_3HR, wd)
        throw(ArgumentError(
            "UL N643 restrained beam: fire_rating must be 1, 1.5, 2, or 3 hr (got $R)"))
    end
end


# =============================================================================
# Unified dispatch: FireProtection → SurfaceCoating
# =============================================================================

"""
    compute_surface_coating(fp, fire_rating, W_plf, perimeter_in) -> SurfaceCoating

Compute the required fire protection coating for a steel member.

# Arguments
- `fp::FireProtection`: Fire protection type (SFRM, IntumescentCoating, etc.)
- `fire_rating::Real`: Fire resistance rating in hours
- `W_plf::Real`: Section weight in lb/ft
- `perimeter_in::Real`: Heated perimeter in inches (PA for beams, PB for columns)

# Returns
`SurfaceCoating` with computed thickness, density, and name.
"""
function compute_surface_coating(fp::NoFireProtection, fire_rating::Real, W_plf::Real, perimeter_in::Real)
    return SurfaceCoating(0.0, 0.0, "None")
end

function compute_surface_coating(fp::SFRM, fire_rating::Real, W_plf::Real, perimeter_in::Real)
    fire_rating <= 0 && return SurfaceCoating(0.0, fp.density_pcf, "SFRM")
    W_D = W_plf / perimeter_in
    h = sfrm_thickness_x772(fire_rating, W_D)
    return SurfaceCoating(h, fp.density_pcf, "SFRM ($(Int(fp.density_pcf)) pcf)")
end

function compute_surface_coating(fp::IntumescentCoating, fire_rating::Real, W_plf::Real, perimeter_in::Real)
    fire_rating <= 0 && return SurfaceCoating(0.0, fp.density_pcf, "Intumescent")
    W_D = W_plf / perimeter_in
    h = intumescent_thickness_n643(fire_rating, W_D; restrained=false)
    return SurfaceCoating(h, fp.density_pcf, "Intumescent ($(Int(fp.density_pcf)) pcf)")
end

function compute_surface_coating(fp::CustomCoating, fire_rating::Real, W_plf::Real, perimeter_in::Real)
    return SurfaceCoating(fp.thickness_in, fp.density_pcf, fp.name)
end
