# =============================================================================
# Directional Procedure MWFRS wind (ASCE 7-22 Chapter 27)
# =============================================================================
#
# Pure demand. Velocity pressure, Kd, G, and (GCpi) are caller inputs.
# Nothing here computes a wind speed, and nothing here is Chapter 26.
#
# `direction` is the horizontal direction the wind blows toward. It need not
# be a unit vector. Wind coming from +X is direction (-1, 0).
#
# Units
#   One consistent unit system. Pressure × length² is force. Force × length
#   is moment. `wind_minimum_horizontal_force` is the exception: its
#   pressures are the printed §27.1.5 values, selected by `system`.
#
# Not implemented, and not to be inferred here:
#   Chapter 26 velocity pressure, open-building CN (Eq. 27.3-2), roof Cp,
#   parapets (Eq. 27.3-3). Eq. 27.3-4 is `wind_flexible_eccentricity`; the
#   §26.11 gust terms are inputs, not computed here.
# =============================================================================

"""
|n̂ · d̂| at or below this value means the edge is parallel to the wind and
is a side wall.

Geometry, not an ASCE 7 factor. An edge at 45° to the wind has
|n̂ · d̂| = √2/2 and is not a side wall.
"""
const WIND_EDGE_PARALLEL_COS = 1e-8

"""
    wind_figure_2731_roof(roof::Symbol) -> Symbol

`roof` must be a roof drawn in Figure 27.3-1: `:flat`, `:gable`, `:hip`,
`:monoslope`, or `:mansard`. Any other roof throws. This slice does not
invent a roof Cp.

# Citation
ASCE 7-22 Table 27.2-1 Step 6 and Figure 27.3-1 (corpus: asce-7-22,
PDF pages 343 and 344).
"""
function wind_figure_2731_roof(roof::Symbol)
    if roof === :flat || roof === :gable || roof === :hip ||
       roof === :monoslope || roof === :mansard
        return roof
    end
    throw(ArgumentError(
        "roof $(repr(roof)) is not in Figure 27.3-1 " *
        "(flat, gable, hip, monoslope, mansard). No roof Cp is invented."))
end

"""
    wind_wall_cp(L_over_B, surface) -> Float64

External pressure coefficient Cp for an MWFRS wall.

`surface` is `:windward`, `:leeward`, or `:side`. `L_over_B` is the story's
along-wind depth divided by its across-wind width. It must be > 0.

Windward Cp is 0.8 for every L/B. Sidewall Cp is -0.7 for every L/B.
Leeward Cp is -0.5 for L/B ≤ 1, -0.3 at L/B = 2, and -0.2 for L/B ≥ 4.
Note 2 permits linear interpolation between those leeward values. They are
all the same sign. The "0–1" row is the constant -0.5, not a ramp from 0.

# Citation
ASCE 7-22 Figure 27.3-1 wall table and Note 2 (corpus: asce-7-22, PDF page 345).
"""
function wind_wall_cp(L_over_B, surface::Symbol)
    ratio = _as_finite("L/B", L_over_B)
    ratio > 0 || throw(ArgumentError("L/B must be > 0; got $ratio"))
    if surface === :windward
        # Figure 27.3-1, windward wall, all L/B, use with qz
        # (corpus: asce-7-22, PDF page 345).
        return 0.8
    elseif surface === :side
        # Figure 27.3-1, sidewall, all L/B, use with qh
        # (corpus: asce-7-22, PDF page 345).
        return -0.7
    elseif surface === :leeward
        return _leeward_wall_cp(ratio)
    end
    throw(ArgumentError(
        "surface must be :windward, :leeward, or :side; got $(repr(surface))"))
end

function _leeward_wall_cp(ratio::Float64)
    # Figure 27.3-1 leeward wall, use with qh (corpus: asce-7-22, PDF page 345):
    #   L/B = 0 to 1 → -0.5
    #   L/B = 2     → -0.3
    #   L/B ≥ 4     → -0.2
    # Note 2 (same page): linear interpolation is permitted for L/B other
    # than shown, and only between values of the same sign. Every leeward
    # entry is negative.
    if ratio <= 1
        return -0.5
    elseif ratio <= 2
        return -0.5 + (ratio - 1) / (2 - 1) * (-0.3 - (-0.5))
    elseif ratio < 4
        return -0.3 + (ratio - 2) / (4 - 2) * (-0.2 - (-0.3))
    else
        return -0.2
    end
end

