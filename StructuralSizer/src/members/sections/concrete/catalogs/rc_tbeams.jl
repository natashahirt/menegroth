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
- `flange_width`: Effective flange width bf
- `flange_thickness`: Slab thickness hf
- `web_widths`: Web widths in inches (default: 10–24")
- `depths`: Total depths in inches (default: 16–36")
- `bar_sizes`: Longitudinal bar sizes (default: #5–#10)
- `n_bars_range`: Range of bar counts (default: 2:6)
- `cover`: Clear cover to stirrups (default: 1.5")
- `stirrup_size`: Stirrup bar size (default: 3)

# Returns
Vector of `RCTBeamSection`. Invalid combinations are automatically skipped.

# Example
```julia
bf = effective_flange_width(bw=12u"inch", hf=5u"inch", sw=48u"inch", ln=240u"inch")
catalog = standard_rc_tbeams(flange_width=bf, flange_thickness=5u"inch")
```
"""
function standard_rc_tbeams(;
    flange_width,
    flange_thickness::Length,
    web_widths = [10, 12, 14, 16, 18, 20, 24],
    depths = [16, 18, 20, 22, 24, 28, 30, 36],
    bar_sizes = [5, 6, 7, 8, 9, 10],
    n_bars_range = 2:6,
    cover::Length = 1.5u"inch",
    stirrup_size::Int = 3,
)
    catalog = RCTBeamSection[]
    # A function returns the flange width of one web. The caller applies
    # ACI 318-11 §8.12.2 (corpus: aci-318-11, PDF p. 119) to that web.
    flange_of = flange_width isa Function ? flange_width : (_ -> flange_width)
    hf = flange_thickness

    cover_in  = ustrip(u"inch", cover)
    d_stir_in = ustrip(u"inch", rebar(stirrup_size).diameter)
    d_agg_in  = 0.75  # 3/4" typical aggregate
    hf_in     = ustrip(u"inch", hf)

    for bw_val in web_widths
        bw_in = Float64(bw_val)
        bw = bw_in * u"inch"
        bf = flange_of(bw)
        bf isa Length || throw(ArgumentError("T-beam flange width must be a length"))
        bf_in = ustrip(u"inch", bf)
        bw_in ≤ bf_in || continue   # bw must be ≤ bf

        for h_val in depths
            h_in = Float64(h_val)
            h_in > hf_in || continue    # h must exceed flange thickness
            h_in ≥ bw_in || continue    # h ≥ bw (practical)
            h = h_in * u"inch"

            for bar_size in bar_sizes
                db_in = ustrip(u"inch", rebar(bar_size).diameter)
                max_n = _max_bars_in_width(bw_in, cover_in, d_stir_in, db_in, d_agg_in)

                for n_bars in n_bars_range
                    n_bars ≥ 2     || continue
                    n_bars ≤ max_n || continue

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
    flange_width,
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
    flange_width,
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
