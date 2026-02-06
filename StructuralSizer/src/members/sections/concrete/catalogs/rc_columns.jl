# ==============================================================================
# RC Column Section Catalog
# ==============================================================================
# Standard RC column sections for discrete optimization.
# Follows the same interface as steel section catalogs.
#
# Uses existing Concrete type from materials/types.jl
# Presets: NWC_3000, NWC_4000, NWC_5000, NWC_6000, NWC_GGBS, NWC_PFA 
#          in materials/concrete.jl

using Unitful
using Asap: ksi

# ==============================================================================
# Standard Column Sizes
# ==============================================================================

"""
    standard_rc_columns(; 
        sizes = 12:2:36,      # inches (square) or [(b,h), ...] for rectangular
        bar_sizes = [5, 6, 7, 8, 9, 10, 11],
        n_bars_range = 4:4:20,
        cover = 1.5u"inch",
        include_rectangular = true,
        aspect_ratios = [1.5, 2.0]
    ) -> Vector{RCColumnSection}

Generate a catalog of standard RC column sections.

# Arguments
- `sizes`: Range of column sizes (inches). For square columns, use integers.
- `bar_sizes`: Available rebar sizes (#5 through #18)
- `n_bars_range`: Range of bar counts (must be ≥4 for corners)
- `cover`: Clear cover (Length with units, default 1.5")
- `include_rectangular`: If true, also generate rectangular columns
- `aspect_ratios`: b/h ratios for rectangular columns (h > b)

# Returns
Vector of RCColumnSection with varying sizes and reinforcement

# Example
```julia
catalog = standard_rc_columns()           # Default: 12"-36" square
catalog = standard_rc_columns(sizes=14:2:24, bar_sizes=[8,9,10])
catalog = standard_rc_columns(include_rectangular=true)  # Adds 1.5:1 and 2:1 ratios
```
"""
function standard_rc_columns(;
    sizes = 12:2:36,
    bar_sizes = [6, 7, 8, 9, 10, 11],
    n_bars_range = 4:4:16,
    cover::Length = 1.5u"inch",
    include_rectangular = true,
    aspect_ratios = [1.5, 2.0]
)
    catalog = RCColumnSection[]
    
    # Generate size pairs (b, h)
    size_pairs = Tuple{Float64, Float64}[]
    
    # Square columns
    for size in sizes
        push!(size_pairs, (Float64(size), Float64(size)))
    end
    
    # Rectangular columns (h > b)
    if include_rectangular
        for size in sizes
            for ratio in aspect_ratios
                h_rect = size * ratio
                if h_rect <= 48  # Practical limit
                    push!(size_pairs, (Float64(size), Float64(h_rect)))
                end
            end
        end
    end
    
    cover_val = ustrip(u"inch", cover)
    
    for (b_val, h_val) in size_pairs
        b = b_val * u"inch"
        h = h_val * u"inch"
        
        for bar_size in bar_sizes
            # Check minimum size for this bar
            bar = StructuralSizer.rebar(bar_size)
            db = ustrip(u"inch", bar.diameter)
            
            # Minimum column size should fit bars with adequate spacing
            min_cover_to_center = cover_val + db/2
            if 2 * min_cover_to_center > min(b_val, h_val) * 0.4
                continue  # Skip if bars would be too close
            end
            
            for n_bars in n_bars_range
                # Ensure reasonable reinforcement ratio (1-8% per ACI)
                As_total = n_bars * ustrip(u"inch^2", bar.A)
                Ag = b_val * h_val
                ρ = As_total / Ag
                
                if ρ < 0.01 || ρ > 0.08
                    continue  # Skip invalid ratios
                end
                
                # Cover to bar center
                cover_to_center = cover + (db/2) * u"inch"
                
                try
                    section = RCColumnSection(
                        b = b,
                        h = h,
                        cover = cover_to_center,
                        bar_size = bar_size,
                        n_bars = n_bars,
                        tie_type = :tied,
                        arrangement = :perimeter
                    )
                    push!(catalog, section)
                catch e
                    # Skip invalid combinations (e.g., bar spacing too tight)
                    continue
                end
            end
        end
    end
    
    # Sort by size then by steel area (smaller first for minimum weight)
    sort!(catalog, by = s -> (ustrip(u"inch", s.b) * ustrip(u"inch", s.h), _total_As(s)))
    
    return catalog
end

"""Calculate total steel area in section."""
function _total_As(section::RCColumnSection)
    sum(ustrip(u"inch^2", bar.As) for bar in section.bars)
end

# ==============================================================================
# Concrete Material Helpers (for unit conversion)
# ==============================================================================
# Use existing Concrete type from materials/types.jl
# All presets are defined in materials/concrete.jl

"""
    concrete_fc(mat::Concrete) -> Pressure (ksi)

Extract concrete compressive strength from Concrete material.
Returns a Unitful quantity in ksi.
"""
function concrete_fc(mat::Concrete)
    uconvert(ksi, mat.fc′)
end

"""
    concrete_fc_mpa(mat::Concrete) -> Pressure (MPa)

Extract concrete compressive strength from Concrete material.
Returns a Unitful quantity in MPa.
"""
function concrete_fc_mpa(mat::Concrete)
    uconvert(u"MPa", mat.fc′)
end

"""
    concrete_E(mat::Concrete) -> Pressure (ksi)

Extract concrete elastic modulus from Concrete material.
Returns a Unitful quantity in ksi.
"""
function concrete_E(mat::Concrete)
    uconvert(ksi, mat.E)
end

"""
    concrete_wc(mat::Concrete) -> Density (lbf/ft³)

Extract concrete unit weight from Concrete material.
Returns a Unitful quantity in lbf/ft³ (pcf).
"""
function concrete_wc(mat::Concrete)
    # ρ is density in kg/m³, convert to weight in lbf/ft³
    uconvert(u"lbf/ft^3", mat.ρ * 1u"gn")
end

# ==============================================================================
# Prebuilt Catalogs - Rectangular
# ==============================================================================
# Note: RCColumnDemand is defined in members/optimize/demands.jl
#
# Naming convention:
#   - square_rc_columns: Square columns only (b = h)
#   - rectangular_rc_columns: Includes rectangular aspect ratios (b ≠ h)
#   - low_capacity_rc_columns: Smaller sizes for light loads
#   - high_capacity_rc_columns: Larger sizes with heavy reinforcement
#   - all_rc_rect_columns: Comprehensive catalog
#
# For the unified `rc_column_catalog(shape, catalog)` function, see options.jl

"""
    square_rc_columns() -> Vector{RCColumnSection}

Square columns only (12"-36"), no rectangular aspect ratios.
Good default for typical buildings. ~200-400 sections.
"""
function square_rc_columns()
    standard_rc_columns(
        sizes = 12:2:36,
        bar_sizes = [5, 6, 7, 8, 9, 10, 11],
        n_bars_range = [4, 6, 8, 10, 12, 14, 16, 20],
        cover = 1.5u"inch",
        include_rectangular = false
    )
end

"""
    rectangular_rc_columns() -> Vector{RCColumnSection}

Square + rectangular columns (12"-36") with 1.5:1 and 2:1 aspect ratios.
Use for buildings with directional moment demands. ~500-800 sections.
"""
function rectangular_rc_columns()
    standard_rc_columns(
        sizes = 12:2:36,
        bar_sizes = [5, 6, 7, 8, 9, 10, 11],
        n_bars_range = [4, 6, 8, 10, 12, 14, 16, 20],
        cover = 1.5u"inch",
        include_rectangular = true,
        aspect_ratios = [1.5, 2.0]
    )
end

"""
    low_capacity_rc_columns() -> Vector{RCColumnSection}

Smaller columns (12"-24") for low-rise or light load applications.
Includes both square and rectangular. ~100-200 sections.
"""
function low_capacity_rc_columns()
    standard_rc_columns(
        sizes = 12:2:24,
        bar_sizes = [5, 6, 7, 8, 9],
        n_bars_range = [4, 6, 8, 10, 12],
        cover = 1.5u"inch",
        include_rectangular = true,
        aspect_ratios = [1.5]
    )
end

"""
    high_capacity_rc_columns() -> Vector{RCColumnSection}

Larger columns (18"-48") with heavy reinforcement (#8-#18).
For high-rise or heavy load applications. Includes rectangular. ~400-600 sections.
"""
function high_capacity_rc_columns()
    standard_rc_columns(
        sizes = 18:2:48,
        bar_sizes = [8, 9, 10, 11, 14, 18],
        n_bars_range = [8, 10, 12, 14, 16, 18, 20, 24, 28],
        cover = 2.0u"inch",
        include_rectangular = true,
        aspect_ratios = [1.5, 2.0, 2.5]
    )
end

"""
    all_rc_rect_columns() -> Vector{RCColumnSection}

Comprehensive catalog (10"-48") with all bar sizes and rectangular options.
Use for full optimization studies. ~1000+ sections.
"""
function all_rc_rect_columns()
    standard_rc_columns(
        sizes = 10:2:48,
        bar_sizes = [5, 6, 7, 8, 9, 10, 11, 14, 18],
        n_bars_range = [4, 6, 8, 10, 12, 14, 16, 18, 20, 24],
        cover = 1.5u"inch",
        include_rectangular = true,
        aspect_ratios = [1.25, 1.5, 2.0]
    )
end


# ==============================================================================
# Circular Column Catalog
# ==============================================================================

"""
    standard_rc_circular_columns(; 
        diameters = 12:2:36,       # inches
        bar_sizes = [6, 7, 8, 9, 10, 11],
        n_bars_range = 6:2:16,
        cover = 1.5u"inch"
    ) -> Vector{RCCircularSection}

Generate a catalog of standard circular RC column sections.

# Arguments
- `diameters`: Range of column diameters (inches)
- `bar_sizes`: Available rebar sizes
- `n_bars_range`: Range of bar counts (minimum 6 for spiral columns)
- `cover`: Clear cover (Length with units, default 1.5")

# Returns
Vector of RCCircularSection with varying sizes and reinforcement

# Example
```julia
catalog = standard_rc_circular_columns()
catalog = standard_rc_circular_columns(diameters=16:4:32, bar_sizes=[8,9,10])
```
"""
function standard_rc_circular_columns(;
    diameters = 12:2:36,
    bar_sizes = [6, 7, 8, 9, 10, 11],
    n_bars_range = 6:2:16,
    cover::Length = 1.5u"inch"
)
    catalog = RCCircularSection[]
    cover_val = ustrip(u"inch", cover)
    
    for D_val in diameters
        D = Float64(D_val) * u"inch"
        
        for bar_size in bar_sizes
            # Check minimum size for this bar
            bar = StructuralSizer.rebar(bar_size)
            db = ustrip(u"inch", bar.diameter)
            
            # Minimum diameter should fit bars with adequate spacing
            # For circular, need clearance around perimeter
            min_cover_to_center = cover_val + 0.5 + db/2  # 0.5" for spiral
            R_bars = D_val/2 - min_cover_to_center
            
            if R_bars < db
                continue  # Skip if bars would be too close to center
            end
            
            for n_bars in n_bars_range
                # Check bar spacing around circumference
                circumference = 2 * π * R_bars
                spacing = circumference / n_bars
                min_spacing = max(1.5 * db, 1.5)  # ACI minimum
                
                if spacing < min_spacing
                    continue  # Skip if bars too close together
                end
                
                # Ensure reasonable reinforcement ratio (1-8% per ACI)
                As_total = n_bars * ustrip(u"inch^2", bar.A)
                Ag = π * (D_val/2)^2
                ρ = As_total / Ag
                
                if ρ < 0.01 || ρ > 0.08
                    continue  # Skip invalid ratios
                end
                
                try
                    section = RCCircularSection(
                        D = D,
                        bar_size = bar_size,
                        n_bars = n_bars,
                        cover = cover,
                        tie_type = :spiral  # Circular columns typically use spiral
                    )
                    push!(catalog, section)
                catch e
                    # Skip invalid combinations
                    continue
                end
            end
        end
    end
    
    # Sort by diameter then by steel area (smaller first)
    sort!(catalog, by = s -> (ustrip(u"inch", s.D), _total_As_circular(s)))
    
    return catalog
end

"""Calculate total steel area in circular section."""
function _total_As_circular(section::RCCircularSection)
    sum(ustrip(u"inch^2", bar.As) for bar in section.bars)
end

# ==============================================================================
# Prebuilt Catalogs - Circular
# ==============================================================================

"""
    standard_circular_columns() -> Vector{RCCircularSection}

Standard circular columns (12"-36"). Good default. ~200-300 sections.
"""
function standard_circular_columns()
    standard_rc_circular_columns(
        diameters = 12:2:36,
        bar_sizes = [6, 7, 8, 9, 10, 11],
        n_bars_range = [6, 8, 10, 12, 14, 16],
        cover = 1.5u"inch"
    )
end

"""
    low_capacity_circular_columns() -> Vector{RCCircularSection}

Smaller circular columns (12"-24") for light loads. ~50-100 sections.
"""
function low_capacity_circular_columns()
    standard_rc_circular_columns(
        diameters = 12:2:24,
        bar_sizes = [6, 7, 8, 9],
        n_bars_range = [6, 8, 10, 12],
        cover = 1.5u"inch"
    )
end

"""
    high_capacity_circular_columns() -> Vector{RCCircularSection}

Larger circular columns (18"-60") with heavy reinforcement. ~400-600 sections.
"""
function high_capacity_circular_columns()
    standard_rc_circular_columns(
        diameters = 18:2:60,
        bar_sizes = [8, 9, 10, 11, 14, 18],
        n_bars_range = [8, 10, 12, 14, 16, 18, 20, 24, 28],
        cover = 2.0u"inch"
    )
end

"""
    all_rc_circular_columns() -> Vector{RCCircularSection}

Comprehensive circular catalog (12"-48"). ~500+ sections.
"""
function all_rc_circular_columns()
    standard_rc_circular_columns(
        diameters = 12:2:48,
        bar_sizes = [5, 6, 7, 8, 9, 10, 11, 14, 18],
        n_bars_range = [6, 8, 10, 12, 14, 16, 18, 20, 24]
    )
end

