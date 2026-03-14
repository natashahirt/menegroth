# ==============================================================================
# Section Catalog Builders
# ==============================================================================
# Functions to build section catalogs from symbolic options.
# These depend on section definitions in members/sections/.

"""
    steel_column_catalog(section_type, catalog) -> Vector{<:AbstractSection}

Build a steel column catalog based on section type.

# Arguments
- `section_type`: `:w`, `:hss`, `:pipe`, `:w_and_hss`
- `catalog`: `:compact_only`, `:preferred`, `:all` (legacy `:common` → `:all`)

# Examples
```julia
steel_column_catalog(:hss, :all)          # All rectangular HSS
steel_column_catalog(:w_and_hss, :preferred)  # Preferred W + all HSS
```
"""
function steel_column_catalog(section_type::Symbol, catalog::Symbol)
    # Normalize legacy :common to :all; :compact_only and :preferred both use preferred W set
    use_preferred_w = (catalog === :preferred || catalog === :compact_only)
    if section_type === :w
        return use_preferred_w ? preferred_W() : all_W()
    elseif section_type === :hss
        return all_HSS()  # No compact/preferred filter for HSS yet
    elseif section_type === :pipe
        return all_HSSRound()
    elseif section_type === :w_and_hss
        w_sections = use_preferred_w ? preferred_W() : all_W()
        hss_sections = all_HSS()
        return vcat(w_sections, hss_sections)
    else
        throw(ArgumentError("Unknown section_type=$section_type. Use :w, :hss, :pipe, or :w_and_hss"))
    end
end

"""
    rc_column_catalog(section_shape, catalog) -> Vector{<:AbstractSection}

Build an RC column catalog.

# Arguments
- `section_shape`: `:rect`, `:square`, `:rectangular`, or `:circular`
- `catalog`: `:standard`, `:low_capacity`, `:high_capacity`, `:all`
           (legacy: `:common` maps to `:low_capacity`)

# Rectangular catalog options:
- `:square` — Square columns only (b = h)
- `:rectangular` — Square + rectangular aspect ratios
- `:low_capacity` — Smaller sizes (12"-24") for light loads
- `:high_capacity` — Larger sizes (18"-72") with heavy rebar
- `:standard` — Default square columns (12"-36")
- `:all` — Comprehensive (10"-48" with all options)

# Examples
```julia
rc_column_catalog(:rect, :standard)       # Default square columns
rc_column_catalog(:rect, :rectangular)    # Include rectangular
rc_column_catalog(:rect, :high_capacity)  # High-rise / heavy loads
rc_column_catalog(:circular, :standard)   # Standard circular
rc_column_catalog(:circular, :all)        # All circular columns
```
"""
function rc_column_catalog(section_shape::Symbol, catalog::Symbol)
    if section_shape === :rect || section_shape === :square || section_shape === :rectangular
        # Map catalog symbol to function
        if catalog === :square
            return square_rc_columns()
        elseif catalog === :rectangular
            return rectangular_rc_columns()
        elseif catalog === :standard
            return square_rc_columns()  # Default to square
        elseif catalog === :low_capacity
            return low_capacity_rc_columns()
        elseif catalog === :high_capacity
            return high_capacity_rc_columns()
        elseif catalog === :all
            return all_rc_rect_columns()
        else
            throw(ArgumentError("Unknown catalog=$catalog. Use :standard, :square, :rectangular, :low_capacity, :high_capacity, or :all"))
        end
    elseif section_shape === :circular
        if catalog === :standard
            return standard_circular_columns()
        elseif catalog === :low_capacity
            return low_capacity_circular_columns()
        elseif catalog === :high_capacity
            return high_capacity_circular_columns()
        elseif catalog === :all
            return all_rc_circular_columns()
        else
            throw(ArgumentError("Unknown catalog=$catalog. Use :standard, :low_capacity, :high_capacity, or :all"))
        end
    else
        throw(ArgumentError("Unknown section_shape=$section_shape. Use :rect, :square, :rectangular, or :circular"))
    end
end

"""
    rc_column_catalog(catalog) -> Vector{<:AbstractSection}

Legacy single-argument form — delegates to `rc_column_catalog(:rect, catalog)`.
"""
function rc_column_catalog(catalog::Symbol)
    rc_column_catalog(:rect, catalog)
end

# ==============================================================================
# RC Beam Catalog Dispatcher
# ==============================================================================

"""
    rc_beam_catalog_from_bounds(; min_width_in, max_width_in, min_depth_in, max_depth_in,
                                 resolution_in, bar_sizes, n_bars_range, kwargs...) -> Vector{RCBeamSection}

Build an RC beam catalog from bounds and resolution (for MIP custom catalog).

# Arguments
- `min_width_in`, `max_width_in`: Width range in inches
- `min_depth_in`, `max_depth_in`: Depth range in inches
- `resolution_in`: Step size in inches for both width and depth (default: 2.0)
- `bar_sizes`: Bar sizes (default: [6, 7, 8, 9, 10, 11])
- `n_bars_range`: Bar count range (default: 2:8)
- `kwargs`: Passed to `standard_rc_beams` (cover, stirrup_size, etc.)

# Example
```julia
cat = rc_beam_catalog_from_bounds(;
    min_width_in = 12, max_width_in = 36,
    min_depth_in = 18, max_depth_in = 48,
    resolution_in = 2.0)
```
"""
function rc_beam_catalog_from_bounds(;
    min_width_in::Real,
    max_width_in::Real,
    min_depth_in::Real,
    max_depth_in::Real,
    resolution_in::Real = 2.0,
    bar_sizes = [6, 7, 8, 9, 10, 11],
    n_bars_range = 2:8,
    kwargs...,
)
    res = Float64(resolution_in)
    widths = collect(Float64(min_width_in):res:Float64(max_width_in))
    depths = collect(Float64(min_depth_in):res:Float64(max_depth_in))
    isempty(widths) && throw(ArgumentError("Empty width range: min=$min_width_in max=$max_width_in res=$resolution_in"))
    isempty(depths) && throw(ArgumentError("Empty depth range: min=$min_depth_in max=$max_depth_in res=$resolution_in"))
    return standard_rc_beams(;
        widths = widths,
        depths = depths,
        bar_sizes = bar_sizes,
        n_bars_range = n_bars_range,
        kwargs...,
    )
end

"""
    rc_beam_catalog(catalog) -> Vector{RCBeamSection}

Build an RC beam catalog.

# Arguments
- `catalog`: `:standard`, `:small`, `:large`, `:xlarge`, `:all`

# Examples
```julia
rc_beam_catalog(:standard)   # Default catalog (~400-600 sections)
rc_beam_catalog(:small)      # Light-load (smaller sections)
rc_beam_catalog(:large)      # Heavy-load (larger sections)
rc_beam_catalog(:xlarge)     # Vault/heavy thrust (largest sections)
rc_beam_catalog(:all)       # Comprehensive (widest range)
```
"""
function rc_beam_catalog(catalog::Symbol)
    if catalog === :standard
        return standard_rc_beams()
    elseif catalog === :small
        return small_rc_beams()
    elseif catalog === :large
        return large_rc_beams()
    elseif catalog === :xlarge
        return xlarge_rc_beams()
    elseif catalog === :all
        return all_rc_beams()
    else
        throw(ArgumentError(
            "Unknown catalog=$catalog for RC beams. " *
            "Use :standard, :small, :large, :xlarge, or :all"))
    end
end