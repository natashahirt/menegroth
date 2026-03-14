# ==============================================================================
# RC Beam Section Catalog
# ==============================================================================
# Standard RC beam sections for discrete optimization.
# Follows the same interface as steel section and RC column catalogs.
#
# Uses RCBeamSection from sections/concrete/rc_beam_section.jl
# ==============================================================================

using Unitful

# ==============================================================================
# Internal Helper: Max Bars That Fit
# ==============================================================================

"""
    _max_bars_in_width(b_in, cover_in, d_stir_in, db_in, d_agg_in) -> Int

Maximum number of bars that fit in a single layer within beam width `b`.

ACI 25.2.1 minimum clear spacing = max(1", d_b, 4/3 × d_agg).
"""
function _max_bars_in_width(b_in::Float64, cover_in::Float64, d_stir_in::Float64,
                            db_in::Float64, d_agg_in::Float64)
    b_inner = b_in - 2 * (cover_in + d_stir_in)
    b_inner <= 0 && return 0
    s_clear_min = max(1.0, db_in, 4/3 * d_agg_in)
    # n bars with (n-1) gaps:  n * db + (n-1) * s_clear_min ≤ b_inner
    n = floor(Int, (b_inner + s_clear_min) / (db_in + s_clear_min))
    return max(n, 0)
end

# ==============================================================================
# Catalog Builders
# ==============================================================================

"""
    standard_rc_beams(; widths, depths, bar_sizes, n_bars_range,
                        cover, stirrup_size) -> Vector{RCBeamSection}

Generate a catalog of standard singly-reinforced RC beam sections.

# Arguments
- `widths`: Beam widths in inches (default: common sizes 10–24")
- `depths`: Total depths in inches (default: 12–36")
- `bar_sizes`: Longitudinal bar sizes (default: #5–#10)
- `n_bars_range`: Range of bar counts (default: 2:6)
- `cover`: Clear cover to stirrups (default: 1.5")
- `stirrup_size`: Stirrup bar size (default: 3 = #3)

# Returns
Vector of `RCBeamSection`. Invalid combinations (bars don't fit, h < b)
are automatically skipped.

# Example
```julia
catalog = standard_rc_beams()                    # Default: ~400-600 sections
catalog = standard_rc_beams(widths=[12, 14, 16]) # Narrower range
```
"""
function standard_rc_beams(;
    widths = [10, 12, 14, 16, 18, 20, 24],
    depths = [12, 14, 16, 18, 20, 22, 24, 28, 30, 36],
    bar_sizes = [5, 6, 7, 8, 9, 10],
    n_bars_range = 2:6,
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
)
    catalog = RCBeamSection[]

    cover_in = ustrip(u"inch", cover)
    d_stir_in = ustrip(u"inch", rebar(stirrup_size).diameter)
    d_agg_in = 0.75  # 3/4" typical aggregate

    for b_val in widths
        b = Float64(b_val) * u"inch"
        b_in = Float64(b_val)

        for h_val in depths
            h_val >= b_val || continue          # h ≥ b for beams (practical)
            h = Float64(h_val) * u"inch"

            for bar_size in bar_sizes
                db_in = ustrip(u"inch", rebar(bar_size).diameter)

                # Determine max bars that fit
                max_n = _max_bars_in_width(b_in, cover_in, d_stir_in, db_in, d_agg_in)

                for n_bars in n_bars_range
                    n_bars >= 2      || continue
                    n_bars <= max_n  || continue

                    try
                        sec = RCBeamSection(
                            b = b, h = h,
                            bar_size = bar_size,
                            n_bars = n_bars,
                            cover = cover,
                            stirrup_size = stirrup_size,
                        )
                        push!(catalog, sec)
                    catch e
                        @debug "Skipping invalid RC beam section" b h bar_size n_bars exception=(e, catch_backtrace())
                        continue
                    end
                end
            end
        end
    end

    return catalog
end

"""
    small_rc_beams(; kwargs...) -> Vector{RCBeamSection}

Compact beam catalog for light-load applications (10–18" widths, 12–24" depths).
"""
function small_rc_beams(; cover::Length = 1.5u"inch", stirrup_size::Int = 3)
    standard_rc_beams(;
        widths = [10, 12, 14, 16, 18],
        depths = [12, 14, 16, 18, 20, 22, 24],
        bar_sizes = [5, 6, 7, 8, 9],
        n_bars_range = 2:5,
        cover, stirrup_size,
    )
end

"""
    large_rc_beams(; kwargs...) -> Vector{RCBeamSection}

Extended beam catalog for heavy-load applications (12–30" widths, 18–48" depths).
"""
function large_rc_beams(; cover::Length = 1.5u"inch", stirrup_size::Int = 3)
    standard_rc_beams(;
        widths = [12, 14, 16, 18, 20, 24, 30],
        depths = [18, 20, 22, 24, 28, 30, 36, 42, 48],
        bar_sizes = [6, 7, 8, 9, 10, 11],
        n_bars_range = 2:8,
        cover, stirrup_size,
    )
end

"""
    xlarge_rc_beams(; kwargs...) -> Vector{RCBeamSection}

Extended catalog for vaults and very heavy loads (18–36" widths, 24–60" depths).
Includes larger sections than `large_rc_beams` to handle high thrust and moment demands.
"""
function xlarge_rc_beams(; cover::Length = 1.5u"inch", stirrup_size::Int = 3)
    standard_rc_beams(;
        widths = [18, 20, 24, 30, 36],
        depths = [24, 28, 30, 36, 42, 48, 54, 60],
        bar_sizes = [8, 9, 10, 11],
        n_bars_range = 4:10,
        cover, stirrup_size,
    )
end

"""
    all_rc_beams(; kwargs...) -> Vector{RCBeamSection}

Comprehensive beam catalog (10–30" widths, 10–48" depths, #4–#11 bars).
"""
function all_rc_beams(; cover::Length = 1.5u"inch", stirrup_size::Int = 3)
    standard_rc_beams(;
        widths = [10, 12, 14, 16, 18, 20, 24, 30],
        depths = [10, 12, 14, 16, 18, 20, 22, 24, 28, 30, 36, 42, 48],
        bar_sizes = [4, 5, 6, 7, 8, 9, 10, 11],
        n_bars_range = 2:8,
        cover, stirrup_size,
    )
end
