# ==============================================================================
# Extract Slab Reinforcement for Composite Negative Moment (AISC I3.2b)
# ==============================================================================
# Determines which slab reinforcement within b_eff runs parallel to the beam
# and can contribute to negative moment capacity.

"""
    extract_parallel_Asr(panel_result, beam_direction::Symbol, b_eff) -> (Asr, Fysr)

Extract the area of developed longitudinal reinforcement within `b_eff` that
runs **parallel** to the beam, for use in composite negative moment (I3.2b).

Prefer [`asr_at_section`](@ref). This function adds both negative locations
and both strips, and it assumes Grade 60.

Accepts any slab result type with the strip reinforcement fields used by
`FlatPlatePanelResult` (duck-typed to avoid load-order dependency).

# Arguments
- `panel_result`: Slab design result containing strip reinforcement in two directions.
  Must have fields: `column_strip_reinf`, `column_strip_width`,
  `middle_strip_reinf`, `middle_strip_width`, and optionally
  `secondary_column_strip_reinf/width`, `secondary_middle_strip_reinf/width`.
- `beam_direction`: `:x` or `:y` — the beam's spanning direction in the floor plan.
  - `:x` means the beam spans in the direction of `l1` (primary reinforcement is parallel).
  - `:y` means the beam spans in the direction of `l2` (secondary reinforcement is parallel).
- `b_eff`: Effective slab width for composite action (from `get_b_eff`).

# Returns
- `Asr`: Total area of parallel rebar within `b_eff` (negative-moment locations).
- `Fysr`: Yield strength of the rebar (assumed Grade 60 = 60 ksi if not otherwise specified).

# Notes
- Uses the **negative moment** reinforcement (`:ext_neg` or `:int_neg` locations)
  since composite negative moment occurs at supports.
- Reinforcement is scaled by `b_eff / strip_width` to get As within b_eff.
- When secondary reinforcement is not available, falls back to primary direction
  with a warning if the beam direction is `:y`.
"""
function extract_parallel_Asr(panel_result,
                               beam_direction::Symbol,
                               b_eff)
    if beam_direction === :x
        # Beam parallel to l1 → primary reinforcement (column strip + middle strip)
        return _sum_neg_Asr(panel_result.column_strip_reinf,
                            panel_result.column_strip_width,
                            panel_result.middle_strip_reinf,
                            panel_result.middle_strip_width,
                            b_eff)
    elseif beam_direction === :y
        # Beam parallel to l2 → secondary reinforcement
        if isempty(panel_result.secondary_column_strip_reinf)
            @warn "No secondary reinforcement data in panel result; " *
                  "falling back to primary. Negative moment Asr may be inaccurate."
            return _sum_neg_Asr(panel_result.column_strip_reinf,
                                panel_result.column_strip_width,
                                panel_result.middle_strip_reinf,
                                panel_result.middle_strip_width,
                                b_eff)
        end
        return _sum_neg_Asr(panel_result.secondary_column_strip_reinf,
                            panel_result.secondary_column_strip_width,
                            panel_result.secondary_middle_strip_reinf,
                            panel_result.secondary_middle_strip_width,
                            b_eff)
    else
        throw(ArgumentError("beam_direction must be :x or :y, got :$beam_direction"))
    end
end

"""
Sum the negative-moment reinforcement from column and middle strips, scaled to `b_eff`.
"""
function _sum_neg_Asr(col_reinf, col_width, mid_reinf, mid_width, b_eff)
    Asr = 0.0u"mm^2"
    Fysr = 413.685u"MPa"  # Grade 60 rebar (60 ksi ≈ 413.685 MPa)

    for r in col_reinf
        if r.location === :ext_neg || r.location === :int_neg
            scale = min(1.0, ustrip(u"m", b_eff) / ustrip(u"m", col_width))
            Asr += r.As_provided * scale
        end
    end
    for r in mid_reinf
        if r.location === :ext_neg || r.location === :int_neg
            scale = min(1.0, ustrip(u"m", b_eff) / ustrip(u"m", mid_width))
            Asr += r.As_provided * scale
        end
    end

    return (Asr=Asr, Fysr=Fysr)
end

"""
    asr_at_section(bands, location, b_left, b_right; Fysr) -> NamedTuple

Area of longitudinal slab reinforcement crossing one section inside the beam's
effective width, and the yield strength the caller supplies for that steel.

AISC 360-22 §I3.2b(c) (corpus: aisc-360-22, PDF p. 170) counts slab
reinforcement parallel to the beam, within the effective width, at the
section being checked. Commentary §I3 (PDF p. 507) defines that area as
the developed reinforcement within the effective width. This function
counts the area. It does not check development length.

`location` is one negative-moment section, `:ext_neg` or `:int_neg`.
Records at the other location are not added.

Each band is a named tuple `(y0, y1, strip_width, reinf)`:

- `reinf` is a collection of `StripReinforcement`. `As_provided` at
  `location` is spread uniformly across `strip_width`. The strip result
  stores a total and a spacing, not bar coordinates.
- `y0` and `y1` are the edges of the band that this call is describing,
  measured from the beam centerline. Either order is accepted. A band may
  be a portion of the strip; it may not be wider than `strip_width`.
- The counted area is `(As_provided / strip_width)` times the length of
  the band that lies inside `[-b_left, b_right]`.

`Fysr` is required. The strip result does not store a yield strength, and
this function does not assume Grade 60. Every bar counted in the returned
area uses this one `Fysr`.

The slab result does not store where a strip sits relative to the beam.
The band edges are the caller's placement of that steel.
"""
function asr_at_section(bands, location::Symbol, b_left, b_right; Fysr)
    location in (:ext_neg, :int_neg) || throw(ArgumentError(
        "asr_at_section location must be :ext_neg or :int_neg, got :$location."))
    bl = ustrip(u"m", uconvert(u"m", b_left))
    br = ustrip(u"m", uconvert(u"m", b_right))
    (bl < 0 || br < 0) && throw(ArgumentError(
        "b_left and b_right are widths on each side of the beam and must be ≥ 0."))
    Asr = 0.0u"m^2"
    for band in bands
        y0 = ustrip(u"m", uconvert(u"m", band.y0))
        y1 = ustrip(u"m", uconvert(u"m", band.y1))
        sw = ustrip(u"m", uconvert(u"m", band.strip_width))
        sw > 0 || throw(ArgumentError(
            "strip_width must be positive; As_provided is spread across it."))
        a = min(y0, y1)
        b = max(y0, y1)
        (b - a) <= sw + 1e-9 || throw(ArgumentError(
            "A band cannot be wider than the strip width its As_provided is spread across."))
        As_loc = _as_at_location(band.reinf, location)
        As_loc === nothing && continue
        lo = max(a, -bl)
        hi = min(b, br)
        overlap = max(0.0, hi - lo)
        Asr += As_loc * (overlap / sw)
    end
    return (Asr = uconvert(u"m^2", Asr), Fysr = Fysr)
end

"""Sum `As_provided` at one location. `nothing` when that location is absent."""
function _as_at_location(reinf, location::Symbol)
    As = 0.0u"m^2"
    found = false
    for r in reinf
        r.location === location || continue
        found = true
        As += uconvert(u"m^2", r.As_provided)
    end
    return found ? As : nothing
end

"""
    beam_direction_from_vectors(beam_vec, rebar_vec; tol=0.1) -> Bool

Determine if a rebar direction is parallel to a beam direction using the
cross product magnitude. Returns `true` if the two vectors are approximately
parallel (|cross product| < tol).

Both inputs are 2D vectors `(dx, dy)`.

# Example
```julia
beam_parallel = beam_direction_from_vectors((1.0, 0.0), (1.0, 0.0))  # true
beam_perp     = beam_direction_from_vectors((1.0, 0.0), (0.0, 1.0))  # false
beam_skewed   = beam_direction_from_vectors((1.0, 0.0), (0.7, 0.7))  # false
```
"""
function beam_direction_from_vectors(beam_vec::Tuple{Real,Real},
                                      rebar_vec::Tuple{Real,Real};
                                      tol=0.1)
    bx, by = beam_vec
    rx, ry = rebar_vec
    b_len = sqrt(bx^2 + by^2)
    r_len = sqrt(rx^2 + ry^2)
    (b_len ≈ 0 || r_len ≈ 0) && return false
    cross = abs(bx * ry - by * rx) / (b_len * r_len)
    return cross < tol
end
