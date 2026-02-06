# =============================================================================
# Rebar Utilities for Slab Design
# =============================================================================
#
# Common rebar property lookups and bar selection logic used across slab types.
# These complement the rebar catalog in members/sections/steel/rebar.jl but are
# focused on slab-specific needs (area selection, spacing constraints).
#
# =============================================================================

# Note: This file is included in StructuralSizer which already imports Unitful and Asap
# Area and Length type aliases are available from the parent module

# =============================================================================
# Bar Property Lookups (ASTM A615)
# =============================================================================

"""Standard rebar diameters by bar number (ASTM A615)."""
const REBAR_DIAMETERS = Dict{Int, typeof(1.0u"inch")}(
    3 => 0.375u"inch",
    4 => 0.500u"inch",
    5 => 0.625u"inch",
    6 => 0.750u"inch",
    7 => 0.875u"inch",
    8 => 1.000u"inch",
    9 => 1.128u"inch",
    10 => 1.270u"inch",
    11 => 1.410u"inch",
    14 => 1.693u"inch",
    18 => 2.257u"inch"
)

"""Standard rebar areas by bar number (ASTM A615)."""
const REBAR_AREAS = Dict{Int, typeof(1.0u"inch^2")}(
    3 => 0.11u"inch^2",
    4 => 0.20u"inch^2",
    5 => 0.31u"inch^2",
    6 => 0.44u"inch^2",
    7 => 0.60u"inch^2",
    8 => 0.79u"inch^2",
    9 => 1.00u"inch^2",
    10 => 1.27u"inch^2",
    11 => 1.56u"inch^2",
    14 => 2.25u"inch^2",
    18 => 4.00u"inch^2"
)

"""
    bar_diameter(bar_size::Int) -> Length

Get rebar diameter for a given bar size (e.g., #5 → 0.625").
Returns 0.625" (default) for unknown sizes.
"""
bar_diameter(bar_size::Int) = get(REBAR_DIAMETERS, bar_size, 0.625u"inch")

"""
    bar_area(bar_size::Int) -> Area

Get rebar area for a given bar size (e.g., #5 → 0.31 in²).
Returns 0.31 in² (default) for unknown sizes.
"""
bar_area(bar_size::Int) = get(REBAR_AREAS, bar_size, 0.31u"inch^2")

"""
    infer_bar_size(As::Area) -> Int

Infer rebar size number from bar area by matching to ASTM A615 catalog.
Returns the closest match within 5% tolerance.

# Example
```julia
infer_bar_size(0.79u"inch^2")  # → 8 (#8 bar)
infer_bar_size(1.00u"inch^2")  # → 9 (#9 bar)
```
"""
function infer_bar_size(As::Area)
    As_in2 = ustrip(u"inch^2", As)
    
    best_size = 8  # Default
    best_diff = Inf
    
    for (size, area) in REBAR_AREAS
        diff = abs(As_in2 - ustrip(u"inch^2", area))
        if diff < best_diff
            best_diff = diff
            best_size = size
        end
    end
    
    # Warn if match is poor
    expected = ustrip(u"inch^2", REBAR_AREAS[best_size])
    if best_diff / expected > 0.05
        @warn "Bar area $As_in2 in² doesn't closely match standard sizes, using #$best_size"
    end
    
    return best_size
end

# =============================================================================
# Bar Selection for Slab Strips
# =============================================================================

"""
    select_bars(As_reqd, strip_width; max_spacing=18u"inch") -> NamedTuple

Select bar size and compute spacing to provide required steel area.

Iterates through practical bar sizes (#4-#8) and selects the first that
satisfies spacing requirements. Falls back to #8 at 6" spacing if needed.

# Arguments
- `As_reqd`: Required steel area
- `strip_width`: Width of strip (column or middle strip)
- `max_spacing`: Maximum bar spacing (ACI 318 default: 18")

# Returns
Named tuple with `(bar_size, n_bars, spacing, As_provided)`

# Example
```julia
bars = select_bars(2.5u"inch^2", 60u"inch")
# → (bar_size=5, n_bars=9, spacing=6.67", As_provided=2.79 in²)
```
"""
function select_bars(As_reqd::Area, strip_width::Length; max_spacing=18u"inch")
    # Try practical bar sizes in order of preference
    for bar_size in [4, 5, 6, 7, 8]
        Ab = bar_area(bar_size)
        n_bars = ceil(Int, ustrip(u"inch^2", As_reqd) / ustrip(u"inch^2", Ab))
        n_bars = max(n_bars, 2)  # Minimum 2 bars
        spacing = strip_width / n_bars
        
        if spacing <= max_spacing
            As_provided = n_bars * Ab
            return (bar_size=bar_size, n_bars=n_bars, spacing=spacing, As_provided=As_provided)
        end
    end
    
    # Fallback: #8 bars at tight spacing
    bar_size = 8
    Ab = bar_area(bar_size)
    n_bars = ceil(Int, ustrip(u"inch", strip_width) / 6.0)  # ~6" spacing
    n_bars = max(n_bars, 2)
    As_provided = n_bars * Ab
    spacing = strip_width / n_bars
    
    return (bar_size=bar_size, n_bars=n_bars, spacing=spacing, As_provided=As_provided)
end

# =============================================================================
# Exports
# =============================================================================

export bar_diameter, bar_area, infer_bar_size, select_bars
export REBAR_DIAMETERS, REBAR_AREAS
