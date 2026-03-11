# ==============================================================================
# Reinforced Concrete Column Section
# ==============================================================================
# Rectangular and square RC column sections per ACI 318.
# Supports tied and spiral confinement.
# ==============================================================================

# Import type aliases from Asap
using Asap: Length, Area, SecondMomentOfArea

# ==============================================================================
# Rebar Location
# ==============================================================================

"""
    RebarLocation

Position and area of a single rebar in a column cross-section.

# Fields
- `x`: Distance from left edge of section
- `y`: Distance from bottom edge of section  
- `As`: Cross-sectional area of bar
"""
struct RebarLocation{T<:Length, A<:Area}
    x::T    # Distance from left edge
    y::T    # Distance from bottom edge
    As::A   # Bar area
end

"""
    RebarLocation(x::Length, y::Length, As::Area)

Construct a `RebarLocation` with automatic unit conversion to inches (Float64).

# Arguments
- `x::Length`: Distance from left edge of section (converted to inches)
- `y::Length`: Distance from bottom edge of section (converted to inches)
- `As::Area`: Bar cross-sectional area (converted to in²)

# Returns
`RebarLocation{Float64}` with all values in inch-based units.
"""
function RebarLocation(x::Length, y::Length, As::Area)
    # Step 1: Convert to inches (ensure correct unit conversion)
    x_inch = uconvert(u"inch", x)
    y_inch = uconvert(u"inch", y)
    As_inch2 = uconvert(u"inch^2", As)
    
    # Step 2: Convert to Float64 for consistent arithmetic
    x_in = float(x_inch)
    y_in = float(y_inch)
    As_in2 = float(As_inch2)
    
    RebarLocation{typeof(x_in), typeof(As_in2)}(x_in, y_in, As_in2)
end

# ==============================================================================
# RC Column Section
# ==============================================================================

"""
    RCColumnSection <: AbstractSection

Reinforced concrete column section for rectangular/square tied or spiral columns.

# Fields
- `name`: Optional section designation (e.g., "18x18-8#9")
- `b`: Section width
- `h`: Section depth (direction of bending for uniaxial)
- `Ag`: Gross cross-sectional area
- `bars`: Vector of RebarLocation defining each bar's position and area
- `As_total`: Total area of longitudinal reinforcement
- `ρg`: Gross reinforcement ratio (As_total / Ag)
- `cover`: Clear cover to ties/spirals
- `tie_type`: Confinement type (:tied or :spiral)

# Design Notes
- For square columns: b = h
- For rectangular: h is typically the direction of primary bending
- Bars are positioned from section bottom-left corner
- ρg must satisfy ACI limits: 0.01 ≤ ρg ≤ 0.08

# Example
```julia
# Create 18"×18" column with 8-#9 bars
sec = RCColumnSection(
    b = 18u"inch", h = 18u"inch",
    bar_size = 9, n_bars = 8,
    cover = 1.5u"inch",
    tie_type = :tied
)
```
"""
struct RCColumnSection{T<:Length, A<:Area} <: AbstractSection
    name::Union{String, Nothing}
    b::T                              # Width
    h::T                              # Depth
    Ag::A                             # Gross area
    bars::Vector{RebarLocation{T, A}} # Rebar positions
    As_total::A                       # Total steel area
    ρg::Float64                       # Reinforcement ratio
    cover::T                          # Clear cover
    tie_type::Symbol                  # :tied or :spiral
end

# ==============================================================================
# Constructors
# ==============================================================================

"""
    RCColumnSection(; b, h, bar_size, n_bars, cover, tie_type, name, arrangement)

Construct an RC column section with automatic bar placement.

# Arguments
- `b`: Section width
- `h`: Section depth  
- `bar_size`: Rebar size (e.g., 9 for #9 bars)
- `n_bars`: Total number of longitudinal bars
- `cover`: Clear cover to ties (default 1.5")
- `tie_type`: :tied (default) or :spiral
- `name`: Optional section name
- `arrangement`: Bar arrangement (:perimeter, :two_layer, :corners_only)

# Returns
RCColumnSection with bars automatically placed
"""
function RCColumnSection(;
    b::Length,
    h::Length,
    bar_size::Int,
    n_bars::Int,
    cover::Length = 1.5u"inch",
    tie_type::Symbol = :tied,
    name::Union{String, Nothing} = nothing,
    arrangement::Symbol = :perimeter
)
    # Step 1: Convert ALL inputs to inches first (ensure correct unit conversion)
    b_inch = uconvert(u"inch", b)
    h_inch = uconvert(u"inch", h)
    cover_inch = uconvert(u"inch", cover)
    
    # Step 2: Convert to Float64 for consistent arithmetic
    b_in = float(b_inch)
    h_in = float(h_inch)
    cover_in = float(cover_inch)
    
    # Gross area (computed from float values, will have inch^2 units)
    Ag = b_in * h_in
    
    # Get bar properties from catalog and convert to inches
    bar = rebar(bar_size)
    As_bar_inch = uconvert(u"inch^2", bar.A)
    d_bar_inch = uconvert(u"inch", bar.diameter)
    
    # Convert to Float64
    As_bar = float(As_bar_inch)
    d_bar = float(d_bar_inch)
    
    # Distance from edge to bar center
    # cover + tie diameter (assume #4 tie ≈ 0.5") + half bar diameter
    tie_diam = 0.5u"inch"  # Already in inches, but let's be explicit
    edge_to_center = cover_in + float(tie_diam) + d_bar / 2
    
    # Generate bar positions
    bars = _generate_bar_positions(b_in, h_in, edge_to_center, n_bars, As_bar, arrangement)
    
    # Total steel area
    As_total = n_bars * As_bar
    
    # Reinforcement ratio
    ρg = ustrip(As_total / Ag)
    
    # Validate
    _validate_column_section(ρg, n_bars, tie_type)
    
    # Auto-generate name if not provided
    if isnothing(name)
        b_nom = round(Int, ustrip(u"inch", b_in))
        h_nom = round(Int, ustrip(u"inch", h_in))
        name = "$(b_nom)x$(h_nom)-$(n_bars)#$(bar_size)"
    end
    
    RCColumnSection{typeof(b_in), typeof(Ag)}(
        name, b_in, h_in, Ag, bars, As_total, ρg, cover_in, tie_type
    )
end

"""
    RCColumnSection(b, h, bars; cover, tie_type, name)

Construct an RC column section with explicit bar positions.
"""
function RCColumnSection(
    b::Length,
    h::Length,
    bars::Vector{<:RebarLocation};
    cover::Length = 1.5u"inch",
    tie_type::Symbol = :tied,
    name::Union{String, Nothing} = nothing
)
    # Step 1: Convert to inches
    b_inch = uconvert(u"inch", b)
    h_inch = uconvert(u"inch", h)
    cover_inch = uconvert(u"inch", cover)
    
    # Step 2: Convert to Float64 for consistent types
    b_in = float(b_inch)
    h_in = float(h_inch)
    cover_in = float(cover_inch)
    
    Ag = b_in * h_in
    As_total = sum(float(uconvert(u"inch^2", bar.As)) for bar in bars)
    ρg = ustrip(As_total / Ag)
    
    _validate_column_section(ρg, length(bars), tie_type)
    
    # Convert bars to consistent Float64 types
    bars_converted = [RebarLocation(
        float(uconvert(u"inch", bar.x)),
        float(uconvert(u"inch", bar.y)),
        float(uconvert(u"inch^2", bar.As))
    ) for bar in bars]
    
    RCColumnSection{typeof(b_in), typeof(Ag)}(
        name, b_in, h_in, Ag, bars_converted, As_total, ρg, cover_in, tie_type
    )
end

# ==============================================================================
# Bar Placement Helpers
# ==============================================================================

"""Generate bar positions for standard arrangements."""
function _generate_bar_positions(
    b::Length, h::Length, 
    edge_dist::Length,
    n_bars::Int, 
    As_bar::Area,
    arrangement::Symbol
)
    # Inputs should already be in inches from the calling constructor
    # Ensure Float64 for consistent arithmetic (no unit conversion needed here)
    b_f = float(uconvert(u"inch", b))
    h_f = float(uconvert(u"inch", h))
    edge_dist_f = float(uconvert(u"inch", edge_dist))
    As_f = float(uconvert(u"inch^2", As_bar))
    
    bars = RebarLocation{typeof(b_f), typeof(As_f)}[]
    
    # Corner positions (use float versions)
    x_left = edge_dist_f
    x_right = b_f - edge_dist_f
    y_bot = edge_dist_f
    y_top = h_f - edge_dist_f
    
    if arrangement == :corners_only || n_bars == 4
        # 4 bars at corners
        push!(bars, RebarLocation(x_left, y_bot, As_f))
        push!(bars, RebarLocation(x_right, y_bot, As_f))
        push!(bars, RebarLocation(x_right, y_top, As_f))
        push!(bars, RebarLocation(x_left, y_top, As_f))
        
    elseif arrangement == :two_layer
        # Bars only in top and bottom layers (typical for uniaxial bending)
        # Half the bars at top, half at bottom
        n_per_layer = n_bars ÷ 2
        if n_per_layer < 2
            error("two_layer arrangement requires at least 4 bars")
        end
        
        # Spacing along width
        if n_per_layer == 2
            # Just at corners
            x_positions = [x_left, x_right]
        else
            # Evenly distributed
            dx = (x_right - x_left) / (n_per_layer - 1)
            x_positions = [x_left + i * dx for i in 0:(n_per_layer-1)]
        end
        
        # Bottom layer
        for x in x_positions
            push!(bars, RebarLocation(x, y_bot, As_f))
        end
        # Top layer
        for x in x_positions
            push!(bars, RebarLocation(x, y_top, As_f))
        end
        
    elseif arrangement == :perimeter
        # Distribute bars around perimeter
        if n_bars == 8
            # Standard 8-bar: 3 per face (corners shared)
            # Bottom: 2 corners + 1 middle
            push!(bars, RebarLocation(x_left, y_bot, As_f))
            push!(bars, RebarLocation((x_left + x_right) / 2, y_bot, As_f))
            push!(bars, RebarLocation(x_right, y_bot, As_f))
            # Right side middle
            push!(bars, RebarLocation(x_right, (y_bot + y_top) / 2, As_f))
            # Top: 2 corners + 1 middle
            push!(bars, RebarLocation(x_right, y_top, As_f))
            push!(bars, RebarLocation((x_left + x_right) / 2, y_top, As_f))
            push!(bars, RebarLocation(x_left, y_top, As_f))
            # Left side middle
            push!(bars, RebarLocation(x_left, (y_bot + y_top) / 2, As_f))
            
        elseif n_bars == 12
            # 4 per face (corners shared)
            # Equal spacing along each face
            dx = (x_right - x_left) / 3
            dy = (y_top - y_bot) / 3
            
            # Bottom
            for i in 0:3
                push!(bars, RebarLocation(x_left + i * dx, y_bot, As_f))
            end
            # Right (excluding corners)
            for i in 1:2
                push!(bars, RebarLocation(x_right, y_bot + i * dy, As_f))
            end
            # Top (excluding right corner)
            for i in 3:-1:0
                push!(bars, RebarLocation(x_left + i * dx, y_top, As_f))
            end
            # Left (excluding corners)
            for i in 2:-1:1
                push!(bars, RebarLocation(x_left, y_bot + i * dy, As_f))
            end
            
        else
            # Generic: distribute evenly around perimeter
            # For now, fall back to corners + distribute remainder
            # Start with corners
            push!(bars, RebarLocation(x_left, y_bot, As_f))
            push!(bars, RebarLocation(x_right, y_bot, As_f))
            push!(bars, RebarLocation(x_right, y_top, As_f))
            push!(bars, RebarLocation(x_left, y_top, As_f))
            
            # Distribute remaining bars (simplified)
            remaining = n_bars - 4
            if remaining > 0
                # Add to top and bottom faces
                n_per_face = remaining ÷ 2
                dx = (x_right - x_left) / (n_per_face + 1)
                for i in 1:n_per_face
                    push!(bars, RebarLocation(x_left + i * dx, y_bot, As_f))
                    push!(bars, RebarLocation(x_left + i * dx, y_top, As_f))
                end
            end
        end
    else
        error("Unknown bar arrangement: $arrangement")
    end
    
    return bars
end

"""Validate column section against ACI requirements."""
function _validate_column_section(ρg::Float64, n_bars::Int, tie_type::Symbol)
    # ACI 10.6.1.1: 0.01 ≤ ρg ≤ 0.08
    if ρg < 0.01
        @warn "Reinforcement ratio ρg = $(round(ρg, digits=4)) < 0.01 (ACI minimum)"
    end
    if ρg > 0.08
        @warn "Reinforcement ratio ρg = $(round(ρg, digits=4)) > 0.08 (ACI maximum)"
    end
    
    # ACI 10.7.3.1: Minimum number of bars
    min_bars = tie_type == :spiral ? 6 : 4
    if n_bars < min_bars
        error("Minimum $min_bars bars required for $tie_type columns (got $n_bars)")
    end
end

# ==============================================================================
# Interface Implementation
# ==============================================================================

"""Gross cross-sectional area."""
section_area(s::RCColumnSection) = s.Ag

"""Total section depth."""
section_depth(s::RCColumnSection) = s.h

"""Section width."""
section_width(s::RCColumnSection) = s.b

"""Gross reinforcement ratio ρg = As/Ag."""
rho(s::RCColumnSection) = s.ρg

"""Check if section is square."""
is_square(s::RCColumnSection) = s.b ≈ s.h

"""Number of longitudinal bars."""
n_bars(s::RCColumnSection) = length(s.bars)

"""
    effective_depth(s::RCColumnSection; axis=:x)

Distance from compression face to centroid of tension steel.
For :x axis bending, tension steel is at bottom (y = cover).
For :y axis bending, tension steel is at left (x = cover).
"""
function effective_depth(s::RCColumnSection; axis::Symbol = :x)
    if axis == :x
        # Bending about x-axis: tension at bottom, compression at top
        # d = h - (distance to bottom steel)
        y_min = minimum(bar.y for bar in s.bars)
        return s.h - y_min
    else
        # Bending about y-axis: tension at left, compression at right
        x_min = minimum(bar.x for bar in s.bars)
        return s.b - x_min
    end
end

"""
    compression_steel_depth(s::RCColumnSection; axis=:x)

Distance from compression face to compression steel.
"""
function compression_steel_depth(s::RCColumnSection; axis::Symbol = :x)
    if axis == :x
        y_max = maximum(bar.y for bar in s.bars)
        return s.h - y_max
    else
        x_max = maximum(bar.x for bar in s.bars)
        return s.b - x_max
    end
end

"""
    moment_of_inertia(s::RCColumnSection; axis=:x)

Gross moment of inertia (Ig) for the concrete section.
"""
function moment_of_inertia(s::RCColumnSection; axis::Symbol = :x)
    if axis == :x
        return s.b * s.h^3 / 12
    else
        return s.h * s.b^3 / 12
    end
end

"""
    radius_of_gyration(s::RCColumnSection; axis=:x)

Radius of gyration for slenderness calculations.
Per ACI 6.2.5.1: r = 0.3h for rectangular sections.
"""
function radius_of_gyration(s::RCColumnSection; axis::Symbol = :x)
    if axis == :x
        return 0.3 * s.h
    else
        return 0.3 * s.b
    end
end

# ==============================================================================
# Section Scaling
# ==============================================================================

"""
    scale_column_section(section::RCColumnSection, new_b, new_c) -> RCColumnSection

Create a new RCColumnSection with updated dimensions, preserving reinforcement layout.

Used when column dimensions are increased beyond the P-M design result (e.g., for 
span minimum or punching shear requirements). The rebar configuration is preserved,
giving a conservative design (same steel in larger column = lower ρg).

# Arguments
- `section`: Original RCColumnSection from P-M design
- `new_b`: New section width
- `new_c`: New section depth  

# Returns
New RCColumnSection with updated dimensions and same reinforcement

# Example
```julia
sec = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=8, n_bars=8)
scaled = scale_column_section(sec, 20u"inch", 20u"inch")  # Same bars, bigger section
```

# Notes
For proper column design where reinforcement must be sized for demands,
use `resize_column_with_reinforcement` instead, which uses P-M interaction
analysis to determine appropriate reinforcement.
"""
function scale_column_section(
    section::RCColumnSection,
    new_b::Length,
    new_c::Length
)
    # If dimensions haven't changed, return original
    b_old = ustrip(u"inch", section.b)
    h_old = ustrip(u"inch", section.h)
    b_new = ustrip(u"inch", new_b)
    h_new = ustrip(u"inch", new_c)
    
    if abs(b_new - b_old) < 0.1 && abs(h_new - h_old) < 0.1
        return section
    end
    
    # Extract bar info from original section
    n_bars_val = length(section.bars)
    if n_bars_val == 0
        error("Cannot scale section with no bars")
    end
    
    # Find bar size from area (reverse lookup via shared catalog)
    As_bar = section.bars[1].As
    bar_size = infer_bar_size(As_bar)
    
    # Create new section with same bar configuration
    return RCColumnSection(
        b = new_b,
        h = new_c,
        bar_size = bar_size,
        n_bars = n_bars_val,
        cover = section.cover,
        tie_type = section.tie_type
    )
end
