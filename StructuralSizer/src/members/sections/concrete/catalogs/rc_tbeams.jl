# ==============================================================================
# RC T-Beam Section Catalog
# ==============================================================================
# Generate T-beam sections for discrete optimization. The effective flange
# width (bf) and slab thickness (hf) are external parameters determined by
# the building geometry (beam spacing, span, slab depth).
#
# Uses RCTBeamSection from sections/concrete/rc_tbeam_section.jl
# ==============================================================================

using Unitful

# ==============================================================================
# Catalog Builders
# ==============================================================================

"""
    standard_rc_tbeams(; flange_width, flange_thickness,
                         web_widths, depths, bar_sizes, n_bars_range,
                         cover, stirrup_size) -> Vector{RCTBeamSection}

Generate a catalog of singly-reinforced RC T-beam sections.

The effective flange width `bf` and slab thickness `hf` come from the building
geometry (computed via `effective_flange_width`). The catalog varies web width,
total depth, and reinforcement.

# Arguments
- `flange_width`: Effective flange width bf, or a function `bw -> bf`. The
  ACI 318-11 §8.12.2 width depends on the web through the clear distance to
  the next web and through `bf = bw + overhangs`, so a function gives each
  candidate web its own flange.
- `flange_thickness`: Slab thickness hf
- `web_widths`: Web widths in inches (default: 10–24")
- `depths`: Total depths in inches (default: 16–36")
- `bar_sizes`: Longitudinal bar sizes (default: #5–#10)
- `n_bars_range`: Range of bar counts (default: 2:6)
- `cover`: Clear cover to stirrups (default: 1.5")
- `stirrup_size`: Stirrup bar size (default: 3)
- `min_bars`: Fewest tension bars kept (default: 2)
- `keep`: Optional predicate `(bw, h) -> Bool` on candidate web dimensions

# Returns
Vector of `RCTBeamSection`. Invalid combinations are automatically skipped.

# Example
```julia
bf = effective_flange_width(bw=12u"inch", hf=5u"inch", sw=48u"inch", ln=240u"inch")
catalog = standard_rc_tbeams(flange_width=bf, flange_thickness=5u"inch")
```
"""
function standard_rc_tbeams(;
    flange_width::Union{Length, Function},
    flange_thickness::Length,
    web_widths = [10, 12, 14, 16, 18, 20, 24],
    depths = [16, 18, 20, 22, 24, 28, 30, 36],
    bar_sizes = [5, 6, 7, 8, 9, 10],
    n_bars_range = 2:6,
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
    min_bars::Int = 2,
    keep = nothing,
)
    catalog = RCTBeamSection[]
    hf = flange_thickness

    cover_in  = ustrip(u"inch", cover)
    d_stir_in = ustrip(u"inch", rebar(stirrup_size).diameter)
    d_agg_in  = 0.75  # 3/4" typical aggregate
    hf_in     = ustrip(u"inch", hf)

    for bw_val in web_widths
        bw_in = Float64(bw_val)
        bw = bw_in * u"inch"
        bf = flange_width isa Function ? flange_width(bw) : flange_width
        bf_in = ustrip(u"inch", bf)
        # Same ulp allowance as RCTBeamSection: a flange that is the web can
        # convert a few ulps under bw. A genuinely narrower flange is skipped.
        bw_in ≤ bf_in + 1e-6 || continue

        for h_val in depths
            h_in = Float64(h_val)
            h_in > hf_in || continue    # h must exceed flange thickness
            h_in ≥ bw_in || continue    # h ≥ bw (practical)
            h = h_in * u"inch"
            keep === nothing || keep(bw, h) || continue

            for bar_size in bar_sizes
                db_in = ustrip(u"inch", rebar(bar_size).diameter)
                max_n = _max_bars_in_width(bw_in, cover_in, d_stir_in, db_in, d_agg_in)

                for n_bars in n_bars_range
                    n_bars ≥ min_bars || continue
                    n_bars ≤ max_n    || continue

                    try
                        sec = RCTBeamSection(
                            bw = bw, h = h, bf = bf, hf = hf,
                            bar_size = bar_size, n_bars = n_bars,
                            cover = cover, stirrup_size = stirrup_size,
                        )
                        push!(catalog, sec)
                    catch e
                        @debug "Skipping invalid RC T-beam section" bw h bar_size n_bars exception=(e, catch_backtrace())
                        continue
                    end
                end
            end
        end
    end

    return catalog
end

"""
    small_rc_tbeams(; flange_width, flange_thickness, kwargs...) -> Vector{RCTBeamSection}

Compact T-beam catalog for light-load applications.
"""
function small_rc_tbeams(;
    flange_width::Union{Length, Function},
    flange_thickness::Length,
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
)
    standard_rc_tbeams(;
        flange_width, flange_thickness,
        web_widths = [10, 12, 14, 16, 18],
        depths = [14, 16, 18, 20, 22, 24],
        bar_sizes = [5, 6, 7, 8, 9],
        n_bars_range = 2:5,
        cover, stirrup_size,
    )
end

"""
    large_rc_tbeams(; flange_width, flange_thickness, kwargs...) -> Vector{RCTBeamSection}

Extended T-beam catalog for heavy-load applications.
"""
function large_rc_tbeams(;
    flange_width::Union{Length, Function},
    flange_thickness::Length,
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
)
    standard_rc_tbeams(;
        flange_width, flange_thickness,
        web_widths = [12, 14, 16, 18, 20, 24, 30],
        depths = [20, 22, 24, 28, 30, 36, 42, 48],
        bar_sizes = [6, 7, 8, 9, 10, 11],
        n_bars_range = 2:8,
        cover, stirrup_size,
    )
end

"""Widest web in the built-in T-beam catalogs (`large_rc_tbeams`)."""
const MAX_CATALOG_TBEAM_WEB = 30.0u"inch"

"""Widest rib in [`joist_rc_tbeams`](@ref)."""
const MAX_JOIST_RIB_WIDTH = 8.0u"inch"

"""
    joist_center_feasible(center) -> Bool

`true` when some rib width from 4 in through [`MAX_JOIST_RIB_WIDTH`](@ref)
meets ACI 318-11 §8.13.2 and §8.13.3 at this center-to-center spacing
(corpus: aci-318-11, page 120). The clear spacing is `center − bw`, and it
must not exceed 30 in. §8.13.2's stem-depth limit is checked when the rib
is sized, not here.
"""
function joist_center_feasible(center)
    s_in = ustrip(u"inch", center)
    s_in > 0 || return false
    # §8.13.2: rib at least 4 in. §8.13.3: center − bw ≤ 30 in.
    bw_min = max(4.0, s_in - 30.0)
    bw_max = min(ustrip(u"inch", MAX_JOIST_RIB_WIDTH), s_in - 1e-6)
    return bw_min <= bw_max
end

"""
    joist_fallback_center_spacing() -> Length

Widest center-to-center spacing at which a 4 in rib still meets ACI 318-11
§8.13.3. §8.13.2 requires that width, and §8.13.3 limits the clear spacing
to 30 in (corpus: aci-318-11, page 120), so the center spacing is 34 in.
A wider joist rib has a smaller clear spacing at this center spacing.
"""
joist_fallback_center_spacing() = 4.0u"inch" + 30.0u"inch"

"""
    joist_rc_tbeams(; flange_width, flange_thickness, center_spacing, kwargs...)
        -> Vector{RCTBeamSection}

Ribs proportioned as ACI 318-11 §8.13 joist construction (corpus: aci-318-11,
PDF pages 120–121). Every section kept meets the limits that let §8.13.8 and
§11.4.6.1(c) apply:

- §8.13.2: rib width at least 4 in; stem (`h − hf`) not more than 3.5 times
  the rib width.
- §8.13.3: clear spacing `center_spacing − bw` not more than 30 in.

Cover defaults to 3/4 in, the §7.7.1(c) value for joists not exposed to weather
or ground with No. 11 bars and smaller (PDF page 97). It is measured to a #3
stirrup leg, which shortens `d` when no stirrup is placed. The web widths, stem
depths and bar choices are a sizing grid (engineering judgment), not code values.
Returns an empty vector when no web width meets §8.13.3 at this spacing.
"""
function joist_rc_tbeams(;
    flange_width::Union{Length, Function},
    flange_thickness::Length,
    center_spacing::Length,
    web_widths = [4, 5, 6, 7, 8],
    stems = [6, 8, 10, 12, 14, 16, 18, 20, 24],
    bar_sizes = [4, 5, 6, 7, 8],
    n_bars_range = 1:3,
    cover::Length = 0.75u"inch",
    stirrup_size::Int = 3,
)
    hf_in = ustrip(u"inch", flange_thickness)
    s_in = ustrip(u"inch", center_spacing)
    # ACI 318-11 §8.13.2 (width ≥ 4 in) and §8.13.3 (clear spacing ≤ 30 in).
    webs = [w for w in web_widths if w >= 4 && s_in - w <= 30.0 && s_in - w > 0]
    isempty(webs) && return RCTBeamSection[]
    depths = sort!(unique(hf_in .+ Float64.(stems)))
    # ACI 318-11 §8.13.2: stem h − hf ≤ 3.5·bw.
    keep = (bw, h) -> ustrip(u"inch", h) - hf_in <= 3.5 * ustrip(u"inch", bw) + 1e-9
    return standard_rc_tbeams(;
        flange_width, flange_thickness,
        web_widths = webs, depths, bar_sizes, n_bars_range,
        cover, stirrup_size, min_bars = 1, keep,
    )
end
