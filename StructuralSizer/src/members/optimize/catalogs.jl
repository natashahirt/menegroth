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
- `catalog`: `:common`, `:all`, `:preferred`

# Examples
```julia
steel_column_catalog(:hss, :all)          # All rectangular HSS
steel_column_catalog(:w_and_hss, :preferred)  # Preferred W + all HSS
```
"""
function steel_column_catalog(section_type::Symbol, catalog::Symbol)
    if section_type === :w
        if catalog === :preferred
            return preferred_W()
        else  # :common or :all
            return all_W()
        end
    elseif section_type === :hss
        return all_HSS()
    elseif section_type === :pipe
        return all_HSSRound()
    elseif section_type === :w_and_hss
        w_sections = catalog === :preferred ? preferred_W() : all_W()
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
- `:high_capacity` — Larger sizes (18"-48") with heavy rebar
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

# Legacy single-argument version (defaults to rectangular standard)
function rc_column_catalog(catalog::Symbol)
    rc_column_catalog(:rect, catalog)
end
