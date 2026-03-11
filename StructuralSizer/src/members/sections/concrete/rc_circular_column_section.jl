# ==============================================================================
# Reinforced Concrete Circular Column Section
# ==============================================================================
# Circular RC column sections per ACI 318.
# Typically uses spiral reinforcement for confinement.
# ==============================================================================

using Asap: Length, Area, SecondMomentOfArea

# ==============================================================================
# RC Circular Column Section
# ==============================================================================

"""
    RCCircularSection <: AbstractSection

Reinforced concrete circular column section (spiral or tied).

# Fields
- `name`: Optional section designation (e.g., "20DIA-8#10")
- `D`: Column diameter
- `Ag`: Gross cross-sectional area (πD²/4)
- `bars`: Vector of RebarLocation defining each bar's position and area
- `As_total`: Total area of longitudinal reinforcement
- `ρg`: Gross reinforcement ratio (As_total / Ag)
- `cover`: Clear cover to spiral/ties
- `tie_type`: Confinement type (:spiral or :tied)

# Design Notes
- Bars are uniformly distributed around the circumference
- Bar positions are measured from section center (x=0, y=0 at center)
- Spiral columns typically have higher φ factors (0.75 vs 0.65)
- ρg must satisfy ACI limits: 0.01 ≤ ρg ≤ 0.08

# Example
```julia
# Create 20" diameter column with 8-#10 bars
sec = RCCircularSection(
    D = 20u"inch",
    bar_size = 10, n_bars = 8,
    cover = 1.5u"inch",
    tie_type = :spiral
)
```
"""
struct RCCircularSection{T<:Length, A<:Area} <: AbstractSection
    name::Union{String, Nothing}
    D::T                              # Diameter
    Ag::A                             # Gross area (πD²/4)
    bars::Vector{RebarLocation{T, A}} # Rebar positions (from center)
    As_total::A                       # Total steel area
    ρg::Float64                       # Reinforcement ratio
    cover::T                          # Clear cover to spiral
    tie_type::Symbol                  # :spiral or :tied
end

# ==============================================================================
# Constructors
# ==============================================================================

"""
    RCCircularSection(; D, bar_size, n_bars, cover, tie_type, name)

Construct a circular RC column section with automatic bar placement.

# Arguments
- `D`: Column diameter
- `bar_size`: Rebar size (e.g., 10 for #10 bars)
- `n_bars`: Total number of longitudinal bars (evenly spaced around circle)
- `cover`: Clear cover to spiral (default 1.5")
- `tie_type`: :spiral (default) or :tied
- `name`: Optional section name

# Returns
RCCircularSection with bars automatically placed around circumference.
"""
function RCCircularSection(;
    D::Length,
    bar_size::Int,
    n_bars::Int,
    cover::Length = 1.5u"inch",
    tie_type::Symbol = :spiral,
    name::Union{String, Nothing} = nothing
)
    # Convert to inches (Float64)
    D_inch = uconvert(u"inch", D)
    cover_inch = uconvert(u"inch", cover)
    D_in = float(D_inch)
    cover_in = float(cover_inch)
    
    # Gross area
    Ag = π * D_in^2 / 4
    
    # Get bar properties
    bar = rebar(bar_size)
    As_bar_inch = uconvert(u"inch^2", bar.A)
    d_bar_inch = uconvert(u"inch", bar.diameter)
    As_bar = float(As_bar_inch)
    d_bar = float(d_bar_inch)
    
    # Spiral diameter (assume #4 spiral ≈ 0.5")
    d_spiral = 0.5u"inch"
    d_spiral_in = float(uconvert(u"inch", d_spiral))
    
    # Radius to bar centers
    # R_bar = D/2 - cover - spiral_diameter - bar_diameter/2
    R_bar = D_in / 2 - cover_in - d_spiral_in - d_bar / 2
    
    # Generate bar positions (evenly spaced around circle)
    # Start at top (y = R_bar) and go counterclockwise
    bars = RebarLocation{typeof(D_in), typeof(Ag)}[]
    for i in 0:(n_bars - 1)
        θ = π/2 - 2π * i / n_bars  # Start at top, go counterclockwise
        x = R_bar * cos(θ)
        y = R_bar * sin(θ)
        # Convert to position from bottom-left (for consistency with rectangular)
        # Center is at (D/2, D/2) from bottom-left
        x_from_bl = D_in / 2 + x
        y_from_bl = D_in / 2 + y
        push!(bars, RebarLocation{typeof(D_in), typeof(Ag)}(x_from_bl, y_from_bl, As_bar))
    end
    
    # Total steel area
    As_total = n_bars * As_bar
    
    # Reinforcement ratio
    ρg = ustrip(As_total) / ustrip(Ag)
    
    # Validate ACI requirements
    if ρg < 0.01
        @warn "Reinforcement ratio ρg = $(round(ρg, digits=4)) is below ACI minimum of 0.01"
    elseif ρg > 0.08
        @warn "Reinforcement ratio ρg = $(round(ρg, digits=4)) exceeds ACI maximum of 0.08"
    end
    
    if n_bars < 6
        @warn "ACI requires minimum 6 bars for spiral columns"
    end
    
    # Generate name if not provided
    if isnothing(name)
        D_str = round(Int, ustrip(D_in))
        name = "$(D_str)DIA-$(n_bars)#$(bar_size)"
    end
    
    RCCircularSection{typeof(D_in), typeof(Ag)}(
        name, D_in, Ag, bars, As_total, ρg, cover_in, tie_type
    )
end

"""
    RCCircularSection(D, bars; cover, tie_type, name)

Construct a circular column with explicit bar positions.

For advanced cases where bars are not uniformly distributed.
Bar positions should be measured from bottom-left corner (consistent with rectangular).
"""
function RCCircularSection(
    D::Length,
    bars::Vector{<:RebarLocation};
    cover::Length = 1.5u"inch",
    tie_type::Symbol = :spiral,
    name::Union{String, Nothing} = nothing
)
    D_inch = uconvert(u"inch", D)
    cover_inch = uconvert(u"inch", cover)
    D_in = float(D_inch)
    cover_in = float(cover_inch)
    
    Ag = π * D_in^2 / 4
    As_total = sum(b.As for b in bars)
    ρg = ustrip(As_total) / ustrip(Ag)
    
    RCCircularSection{typeof(D_in), typeof(Ag)}(
        name, D_in, Ag, bars, As_total, ρg, cover_in, tie_type
    )
end

# ==============================================================================
# Section Interface
# ==============================================================================

"""Gross cross-sectional area."""
section_area(s::RCCircularSection) = s.Ag

"""Section depth (diameter for circular)."""
section_depth(s::RCCircularSection) = s.D

"""Section width (diameter for circular)."""
section_width(s::RCCircularSection) = s.D

"""Number of reinforcing bars."""
n_bars(s::RCCircularSection) = length(s.bars)

"""Moment of inertia about centroidal axis (same for x and y)."""
function moment_of_inertia(s::RCCircularSection, axis::Symbol=:x)
    # For a solid circle: I = πD⁴/64
    D = ustrip(s.D)
    I_val = π * D^4 / 64
    return I_val * unit(s.D)^4
end

"""Radius of gyration."""
function radius_of_gyration(s::RCCircularSection, axis::Symbol=:x)
    # r = sqrt(I/A) = D/4 for solid circle
    return s.D / 4
end

"""Torsional constant (polar moment for circle)."""
function torsional_constant(s::RCCircularSection)
    # J = πD⁴/32 for solid circle
    D = ustrip(s.D)
    J_val = π * D^4 / 32
    return J_val * unit(s.D)^4
end

"""Effective depth to extreme tension steel."""
function effective_depth(s::RCCircularSection)
    # Find maximum y-coordinate (furthest from compression face at top)
    max_y = maximum(b.y for b in s.bars)
    return max_y
end

"""Depth to compression steel (minimum y from top face)."""
function compression_steel_depth(s::RCCircularSection)
    min_y = minimum(b.y for b in s.bars)
    return min_y
end

# ==============================================================================
# Circular Geometry Helpers (for P-M calculations)
# ==============================================================================

"""
    circular_compression_zone(D, a)

Calculate properties of the Whitney stress block for a circular section.

# Arguments
- `D`: Column diameter (unitless Float64 in inches)
- `a`: Depth of rectangular stress block (inches)

# Returns
Named tuple with:
- `A_comp`: Compression zone area (in²)
- `y_bar`: Distance from SECTION CENTROID to centroid of A_comp (in) - this is the moment arm!
- `θ`: Half-angle subtended by compression zone (radians)

# Reference
StructurePoint design example formulas:
- θ = acos((D/2 - a) / (D/2))
- A_comp = D²/4 × (θ - sin(θ)cos(θ))  [θ in radians]
- ȳ = D³ sin³(θ) / (12 × A_comp) - this gives distance from CENTER to compression centroid
"""
function circular_compression_zone(D::Real, a::Real)
    R = D / 2
    
    if a <= 0
        return (A_comp = 0.0, y_bar = 0.0, θ = 0.0)
    elseif a >= D
        # Full section in compression
        A_comp = π * R^2
        y_bar = R  # Centroid at center
        θ = π
        return (A_comp = A_comp, y_bar = y_bar, θ = θ)
    end
    
    # θ = arccos((R - a) / R) - angle from center to compression zone edge
    cos_θ = (R - a) / R
    cos_θ = clamp(cos_θ, -1.0, 1.0)  # Numerical safety
    θ = acos(cos_θ)
    
    # Area of circular segment
    # A_comp = R² × (θ - sin(θ)cos(θ)) where θ is in radians
    A_comp = R^2 * (θ - sin(θ) * cos(θ))
    
    # Distance from extreme compression fiber to centroid
    # StructurePoint formula: ȳ = D³ sin³(θ) / (12 × A_comp)
    # This gives the distance from TOP (compression face) to centroid directly
    if A_comp > 1e-10
        y_bar = D^3 * sin(θ)^3 / (12 * A_comp)
    else
        y_bar = 0.0
    end
    
    return (A_comp = A_comp, y_bar = y_bar, θ = θ)
end

"""
    bar_depth_from_compression(section::RCCircularSection, bar::RebarLocation)

Calculate the depth of a bar from the extreme compression fiber.

For circular sections bending about horizontal axis (x-axis):
- Compression fiber is at top (y = D)
- Depth d = D - y_bar
"""
function bar_depth_from_compression(section::RCCircularSection, bar::RebarLocation)
    D = ustrip(section.D)
    y = ustrip(bar.y)
    return D - y  # Depth from top
end

"""
    get_bar_depths(section::RCCircularSection) -> Vector{Float64}

Get depths of all bars from the extreme compression fiber.
Returns a vector of depths in inches, sorted from smallest (nearest compression) to largest.
"""
function get_bar_depths(section::RCCircularSection)
    D = ustrip(section.D)
    depths = [D - ustrip(b.y) for b in section.bars]
    return sort(depths)
end

"""
    extreme_tension_depth(section::RCCircularSection)

Get depth to the extreme tension steel (furthest from compression face).
"""
function extreme_tension_depth(section::RCCircularSection)
    return maximum(bar_depth_from_compression(section, b) for b in section.bars)
end

# ==============================================================================
# Display
# ==============================================================================

"""Pretty-print an `RCCircularSection` showing diameter, bar count, steel area, ρg, and confinement type."""
function Base.show(io::IO, s::RCCircularSection)
    D_val = round(ustrip(s.D), digits=2)
    As_val = round(ustrip(s.As_total), digits=2)
    ρ_pct = round(s.ρg * 100, digits=2)
    n = length(s.bars)
    tie_str = s.tie_type == :spiral ? "spiral" : "tied"
    
    if !isnothing(s.name)
        print(io, "RCCircularSection($(s.name): D=$(D_val)\", $(n) bars, As=$(As_val) in², ρ=$(ρ_pct)%, $tie_str)")
    else
        print(io, "RCCircularSection(D=$(D_val)\", $(n) bars, As=$(As_val) in², ρ=$(ρ_pct)%, $tie_str)")
    end
end
