# ==============================================================================
# ACI 318-11 Column P-M Interaction
# ==============================================================================
# Strain compatibility analysis for reinforced concrete columns
# Reference: ACI 318-11 Chapter 10
#
# Material utilities (beta1, Ec, fr, extractors) are in aci_material_utils.jl

using Unitful
using Asap: to_inches, to_sqinches

# ==============================================================================
# Control Point Types for P-M Diagrams
# ==============================================================================

"""
    ControlPointType

Enumeration of standard control points on ACI P-M interaction diagrams.
"""
@enum ControlPointType begin
    PURE_COMPRESSION       # P₀ - all compression
    MAX_COMPRESSION        # Pn,max = α×P₀
    FS_ZERO               # fs = 0, c = d
    FS_HALF_FY            # fs = 0.5fy
    BALANCED              # fs = fy, εt = εy
    TENSION_CONTROLLED    # εt = εy + 0.003
    PURE_BENDING          # Pn ≈ 0
    PURE_TENSION          # All steel in tension
    INTERMEDIATE          # Unlabeled intermediate point
end

# ==============================================================================
# Strain Compatibility Core
# ==============================================================================

"""
    calculate_steel_strain(y_bar::Real, c::Real, h::Real, εcu::Real) -> Float64

Calculate steel strain at bar location using similar triangles.

# Arguments
- `y_bar`: Distance from compression face to bar (in)
- `c`: Neutral axis depth from compression face (in)
- `h`: Total section depth (in) [unused, kept for clarity]
- `εcu`: Concrete ultimate strain (typically 0.003)

# Returns
- Steel strain (positive = tension, negative = compression)

Per ACI 318-11 strain compatibility (§10.2.2):
- Linear strain distribution assumed
- εcu = 0.003 at extreme compression fiber
"""
function calculate_steel_strain(y_bar::Real, c::Real, h::Real, εcu::Real)
    # Strain = εcu * (distance from NA) / c
    # If y_bar < c: compression (negative strain)
    # If y_bar > c: tension (positive strain)
    return εcu * (y_bar - c) / c
end

"""
    calculate_steel_stress(εs::Real, fy_ksi::Real, Es_ksi::Real) -> Float64

Calculate steel stress from strain, limited to fy.

# Arguments
- `εs`: Steel strain (positive = tension)
- `fy_ksi`: Yield strength (ksi)
- `Es_ksi`: Elastic modulus (ksi)

# Returns
- Steel stress (ksi), positive = tension
"""
function calculate_steel_stress(εs::Real, fy_ksi::Real, Es_ksi::Real)
    fs = Es_ksi * εs
    # Limit to ± fy (elastic-perfectly-plastic)
    return clamp(fs, -fy_ksi, fy_ksi)
end

"""
    calculate_PM_at_c(section::RCColumnSection, mat, c_in::Real) -> NamedTuple

Calculate nominal (Pn, Mn) capacity at a given neutral axis depth c.

# Arguments
- `section`: RCColumnSection with bar positions
- `mat`: Concrete material with fc, fy, Es, εcu properties
- `c_in`: Neutral axis depth from compression face (inches)

# Returns
NamedTuple with:
- `Pn`: Nominal axial capacity (kip), positive = compression
- `Mn`: Nominal moment capacity (kip-ft)
- `εt`: Strain in extreme tension steel (for φ calculation)
- `c`: Neutral axis depth used (in)

# Notes
Uses Whitney rectangular stress block per ACI 318-11 §10.2.7.
Sign convention: compression positive for forces, tension positive for strain.

Coordinate system:
- Compression face at TOP (y = h)
- Tension face at BOTTOM (y = 0)
- Bars stored with (x, y) from bottom-left corner
- d = distance from compression face to extreme tension steel
"""
function calculate_PM_at_c(section::RCColumnSection, mat, c_in::Real)
    # Extract material properties (uses unified extractors from aci_material_utils.jl)
    fc = fc_ksi(mat)
    fy = fy_ksi(mat)
    Es = Es_ksi(mat)
    εcu_val = εcu(mat)
    
    # Section dimensions (stored in inches)
    b = to_inches(section.b)
    h = to_inches(section.h)
    
    # Whitney stress block
    β₁ = beta1(mat)
    a = β₁ * c_in  # Stress block depth
    
    # Limit stress block to section depth
    a_eff = min(a, h)
    
    # Concrete compression force over gross area (positive)
    # Cc = 0.85 * f'c * b * a
    Cc = 0.85 * fc * b * a_eff  # kip
    
    # Concrete force location from compression face (top)
    y_Cc_from_top = a_eff / 2
    
    # Steel forces - must account for displaced concrete
    # Per ACI: for bars within compression zone, net force = As * (fs - 0.85*f'c)
    Fs_total = 0.0  # Total steel force contribution (positive = compression)
    Ms_total = 0.0  # Steel moment about section centroid
    
    centroid_from_top = h / 2  # Section centroid from compression face
    
    # Concrete stress in compression zone
    fc_stress = 0.85 * fc  # ksi
    
    for bar in section.bars
        # Bar y is from bottom → distance from TOP = h - bar.y
        y_bar_from_top = h - to_inches(bar.y)
        As_bar = to_sqinches(bar.As)
        
        # Steel strain at this bar
        εs = calculate_steel_strain(y_bar_from_top, c_in, h, εcu_val)
        
        # Steel stress (positive = tension, negative = compression)
        fs = calculate_steel_stress(εs, fy, Es)
        
        # Check if bar is within compression zone (Whitney stress block)
        in_compression_zone = y_bar_from_top < a_eff
        
        # Steel force contribution (compression positive):
        # - Pure steel force: -fs * As (fs>0 tension → negative force; fs<0 compression → positive)
        # - If bar in compression zone: Cc over-counts concrete by 0.85*f'c*As
        #   Must SUBTRACT this displaced concrete from total P
        #   Net = (-fs * As) - (0.85*f'c * As) = -As * (fs + 0.85*f'c)
        
        if in_compression_zone
            # Bar in compression zone: steel force minus displaced concrete
            Fs = -As_bar * (fs + fc_stress)
        else
            # Bar outside compression zone: just steel force
            Fs = -fs * As_bar
        end
        
        Fs_total += Fs
        
        # Moment about section centroid
        arm = centroid_from_top - y_bar_from_top  # positive if bar closer to compression face
        Ms_total += Fs * arm  # kip-in
    end
    
    # Extreme tension strain: bar furthest from compression face
    # bar.y = distance from bottom, small y = near tension face (bottom)
    y_tension_bar_from_bottom = minimum(to_inches(bar.y) for bar in section.bars)
    y_tension_from_top = h - y_tension_bar_from_bottom  # = d
    εt = calculate_steel_strain(y_tension_from_top, c_in, h, εcu_val)
    
    # Total axial force (positive = compression)
    Pn = Cc + Fs_total  # kip
    
    # Total moment about centroid (kip-in, then converted to kip-ft)
    Mc = Cc * (centroid_from_top - y_Cc_from_top)
    Mn_kipin = Mc + Ms_total
    Mn = Mn_kipin / 12.0  # → kip-ft
    
    return (Pn = Pn, Mn = abs(Mn), εt = εt, c = c_in)
end

# ==============================================================================
# Helper: Find c for a given εt
# ==============================================================================

"""
    c_from_εt(εt::Real, d::Real, εcu::Real=0.003) -> Float64

Calculate neutral axis depth c for a given extreme tension steel strain.

# Arguments
- `εt`: Target strain in extreme tension steel
- `d`: Depth to extreme tension steel from compression face (in)
- `εcu`: Concrete ultimate strain

# Returns
- Neutral axis depth c (in)

From similar triangles: εcu/c = (εcu + εt)/(d)
→ c = εcu * d / (εcu + εt)
"""
function c_from_εt(εt::Real, d::Real, εcu::Real=0.003)
    return εcu * d / (εcu + εt)
end

# ==============================================================================
# Pure Compression Capacity (P0)
# ==============================================================================

"""
    pure_compression_capacity(section::RCColumnSection, mat) -> Float64

Calculate pure axial compression capacity P0 per ACI 318-11.

P0 = 0.85 * f'c * (Ag - As) + fy * As

Note: This is the theoretical maximum. ACI §10.3.6 requires using:
- Pn,max = 0.80 * P0 for tied columns
- Pn,max = 0.85 * P0 for spiral columns
"""
function pure_compression_capacity(section::RCColumnSection, mat)
    fc = fc_ksi(mat)
    fy = fy_ksi(mat)
    
    Ag = to_sqinches(section.Ag)
    As = to_sqinches(section.As_total)
    
    P0 = 0.85 * fc * (Ag - As) + fy * As
    return P0  # kip
end

"""
    max_compression_capacity(section::RCColumnSection, mat) -> Float64

Calculate maximum permitted compression per ACI 318-11 §10.3.6.

Pn,max = α * P0, where:
- α = 0.80 for tied columns
- α = 0.85 for spiral columns
"""
function max_compression_capacity(section::RCColumnSection, mat)
    P0 = pure_compression_capacity(section, mat)
    α = section.tie_type == :spiral ? 0.85 : 0.80
    return α * P0
end

# ==============================================================================
# Strength Reduction Factor (φ)
# ==============================================================================

"""
    phi_factor(εt, tie_type; fy_ksi, Es_ksi) -> Float64

Calculate strength reduction factor φ per ACI 318-11 §9.3.2.

# Arguments
- `εt`: Net tensile strain in extreme tension steel
- `tie_type`: :tied or :spiral
- `fy_ksi`: Rebar yield strength in ksi — from user's rebar material
- `Es_ksi`: Rebar elastic modulus in ksi — from user's rebar material

# Returns
- φ factor for moment/axial design

# ACI 318-11 §9.3.2:
For Grade 60 steel (εy = 0.00207):
- εt ≤ εy: Compression controlled
  - Tied: φ = 0.65
  - Spiral: φ = 0.75
- εy < εt < (εy + 0.003): Transition zone
  - Tied: φ = 0.65 + 0.25(εt - εy)/0.003
  - Spiral: φ = 0.75 + 0.15(εt - εy)/0.003
- εt ≥ (εy + 0.003): Tension controlled
  - φ = 0.90
"""
function phi_factor(εt::Real, tie_type::Symbol=:tied; fy_ksi::Real, Es_ksi::Real)
    # Yield strain (ACI 318-11 uses modular ratio)
    εy = fy_ksi / Es_ksi
    
    # Tension-controlled limit
    εt_limit = εy + 0.003
    
    if εt ≤ εy
        # Compression controlled
        return tie_type == :spiral ? 0.75 : 0.65
    elseif εt ≥ εt_limit
        # Tension controlled
        return 0.90
    else
        # Transition zone
        if tie_type == :spiral
            return 0.75 + 0.15 * (εt - εy) / 0.003
        else
            return 0.65 + 0.25 * (εt - εy) / 0.003
        end
    end
end

"""
    calculate_phi_PM_at_c(section::RCColumnSection, mat, c_in::Real) -> NamedTuple

Calculate factored (φPn, φMn) capacity at a given neutral axis depth.

# Returns
NamedTuple with:
- `Pn`: Nominal axial capacity (kip)
- `Mn`: Nominal moment capacity (kip-ft)
- `φPn`: Factored axial capacity (kip)
- `φMn`: Factored moment capacity (kip-ft)
- `φ`: Strength reduction factor
- `εt`: Strain in extreme tension steel
- `c`: Neutral axis depth (in)
"""
function calculate_phi_PM_at_c(section::RCColumnSection, mat, c_in::Real)
    # Get nominal values
    result = calculate_PM_at_c(section, mat, c_in)
    
    # Calculate φ based on tension strain
    φ = phi_factor(result.εt, section.tie_type; fy_ksi=fy_ksi(mat), Es_ksi=Es_ksi(mat))
    
    # Factored capacities
    φPn = φ * result.Pn
    φMn = φ * result.Mn
    
    return (
        Pn = result.Pn,
        Mn = result.Mn,
        φPn = φPn,
        φMn = φMn,
        φ = φ,
        εt = result.εt,
        c = result.c
    )
end

# ==============================================================================
# P-M Interaction Diagram Generation
# ==============================================================================

"""
    PMDiagramPoint

A single point on the P-M interaction diagram.

# Fields
- `c`: Neutral axis depth (in)
- `εt`: Extreme tension steel strain
- `Pn`: Nominal axial capacity (kip)
- `Mn`: Nominal moment capacity (kip-ft)
- `φ`: Strength reduction factor
- `φPn`: Factored axial capacity (kip)
- `φMn`: Factored moment capacity (kip-ft)
- `control_type`: Type of control point (enum)
"""
struct PMDiagramPoint
    c::Float64
    εt::Float64
    Pn::Float64
    Mn::Float64
    φ::Float64
    φPn::Float64
    φMn::Float64
    control_type::ControlPointType
end

"""
    PMInteractionDiagram{S<:AbstractSection}

Complete P-M interaction diagram for any RC column section type.
Parametric on section type S for dispatch to correct geometry calculations.

# Type Aliases
- `PMDiagramRect = PMInteractionDiagram{RCColumnSection}`
- `PMDiagramCircular = PMInteractionDiagram{RCCircularSection}`

# Fields
- `section`: RC section (RCColumnSection or RCCircularSection)
- `material`: Material properties (ReinforcedConcreteMaterial, Concrete, or NamedTuple)
- `points`: Vector of PMDiagramPoint (ordered from compression to tension)
- `control_points`: Dict mapping control point symbols to indices
"""
struct PMInteractionDiagram{S<:AbstractSection, M}
    section::S
    material::M
    points::Vector{PMDiagramPoint}
    control_points::Dict{Symbol, Int}
end

"""Type alias: P-M interaction diagram for rectangular RC column sections."""
const PMDiagramRect = PMInteractionDiagram{RCColumnSection}

"""Type alias: P-M interaction diagram for circular RC column sections."""
const PMDiagramCircular = PMInteractionDiagram{RCCircularSection}

"""
    generate_PM_diagram(section::RCColumnSection, mat; n_intermediate::Int=20)

Generate a complete P-M interaction diagram per ACI 318-11.

# Arguments
- `section`: RC column section
- `mat`: Material properties (fc, fy, Es, εcu)
- `n_intermediate`: Number of intermediate points between control points (default 20)

# Returns
PMInteractionDiagram with:
- 7 standard ACI control points (StructurePoint methodology)
- Optional intermediate points for smooth curves

# Control Points (per StructurePoint Design Example)
1. Pure compression (P₀)
2. fs = 0 (c = d, zero tension strain)
3. fs = 0.5fy
4. Balanced (fs = fy)
5. Tension controlled (εt = εy + 0.003)
6. Pure bending (Pn ≈ 0)
7. Pure tension

# Reference
StructurePoint: "Interaction Diagram - Tied Reinforced Concrete Column 
Design Strength (ACI 318-11)"
"""
function generate_PM_diagram(section::RCColumnSection, mat; n_intermediate::Int=20)
    # Material properties (using unified extractors)
    fc = fc_ksi(mat)
    fy = fy_ksi(mat)
    Es = Es_ksi(mat)
    εcu_val = εcu(mat)
    εy = fy / Es
    
    # Section properties
    h = to_inches(section.h)
    d = to_inches(effective_depth(section))
    
    points = PMDiagramPoint[]
    control_indices = Dict{Symbol, Int}()
    
    # =========================================================================
    # Control Point 1: Pure Compression (P₀)
    # Very large c → entire section in compression
    # =========================================================================
    P0 = pure_compression_capacity(section, mat)
    φ_comp = section.tie_type == :spiral ? 0.75 : 0.65
    push!(points, PMDiagramPoint(
        Inf, -εy,  # Compression throughout
        P0, 0.0,
        φ_comp, φ_comp * P0, 0.0,
        PURE_COMPRESSION
    ))
    control_indices[:pure_compression] = length(points)
    
    # =========================================================================
    # Control Point 2: Maximum Allowable Compression
    # Pn,max = α × P₀ (α = 0.80 for tied, 0.85 for spiral)
    # This is a horizontal cutoff, not a computed point
    # We add it at the same moment as the very large c case
    # =========================================================================
    α = section.tie_type == :spiral ? 0.85 : 0.80
    Pn_max = α * P0
    # Find c that gives this Pn (approximately)
    c_large = 5.0 * h  # Large c for essentially pure compression
    result_large = calculate_phi_PM_at_c(section, mat, c_large)
    push!(points, PMDiagramPoint(
        c_large, result_large.εt,
        Pn_max, result_large.Mn,
        φ_comp, φ_comp * Pn_max, φ_comp * result_large.Mn,
        MAX_COMPRESSION
    ))
    control_indices[:max_compression] = length(points)
    
    # =========================================================================
    # Control Point 3: Zero Tension Strain (fs = 0, c = d)
    # Marks transition for lap splice requirements
    # =========================================================================
    c_fs0 = d
    result_fs0 = calculate_phi_PM_at_c(section, mat, c_fs0)
    push!(points, PMDiagramPoint(
        c_fs0, result_fs0.εt,
        result_fs0.Pn, result_fs0.Mn,
        result_fs0.φ, result_fs0.φPn, result_fs0.φMn,
        FS_ZERO
    ))
    control_indices[:fs_zero] = length(points)
    
    # =========================================================================
    # Control Point 4: Half Yield (fs = 0.5fy, εt = 0.5εy)
    # =========================================================================
    εt_half = 0.5 * εy
    c_half = c_from_εt(εt_half, d, εcu_val)
    result_half = calculate_phi_PM_at_c(section, mat, c_half)
    push!(points, PMDiagramPoint(
        c_half, result_half.εt,
        result_half.Pn, result_half.Mn,
        result_half.φ, result_half.φPn, result_half.φMn,
        FS_HALF_FY
    ))
    control_indices[:fs_half_fy] = length(points)
    
    # =========================================================================
    # Control Point 5: Balanced (fs = fy, εt = εy)
    # Marks compression-controlled limit
    # =========================================================================
    c_balanced = c_from_εt(εy, d, εcu_val)
    result_balanced = calculate_phi_PM_at_c(section, mat, c_balanced)
    push!(points, PMDiagramPoint(
        c_balanced, result_balanced.εt,
        result_balanced.Pn, result_balanced.Mn,
        result_balanced.φ, result_balanced.φPn, result_balanced.φMn,
        BALANCED
    ))
    control_indices[:balanced] = length(points)
    
    # =========================================================================
    # Control Point 6: Tension Controlled (εt = εy + 0.003)
    # Marks tension-controlled limit (φ = 0.90)
    # =========================================================================
    εt_tension = εy + 0.003
    c_tension = c_from_εt(εt_tension, d, εcu_val)
    result_tension = calculate_phi_PM_at_c(section, mat, c_tension)
    push!(points, PMDiagramPoint(
        c_tension, result_tension.εt,
        result_tension.Pn, result_tension.Mn,
        result_tension.φ, result_tension.φPn, result_tension.φMn,
        TENSION_CONTROLLED
    ))
    control_indices[:tension_controlled] = length(points)
    
    # =========================================================================
    # Control Point 7: Pure Bending (Pn ≈ 0)
    # Requires iteration to find c where Pn = 0
    # =========================================================================
    c_pure_m = _find_pure_bending_c(section, mat)
    result_pure_m = calculate_phi_PM_at_c(section, mat, c_pure_m)
    push!(points, PMDiagramPoint(
        c_pure_m, result_pure_m.εt,
        result_pure_m.Pn, result_pure_m.Mn,
        result_pure_m.φ, result_pure_m.φPn, result_pure_m.φMn,
        PURE_BENDING
    ))
    control_indices[:pure_bending] = length(points)
    
    # =========================================================================
    # Control Point 8: Pure Tension
    # All steel in tension at yield
    # =========================================================================
    As_total = to_sqinches(section.As_total)
    Pnt = -fy * As_total  # Tension negative
    push!(points, PMDiagramPoint(
        -Inf, Inf,  # All tension
        Pnt, 0.0,
        0.90, 0.90 * Pnt, 0.0,
        PURE_TENSION
    ))
    control_indices[:pure_tension] = length(points)
    
    # =========================================================================
    # Add intermediate points for smooth curve (optional)
    # =========================================================================
    if n_intermediate > 0
        points = _add_intermediate_points(section, mat, points, n_intermediate)
    end
    
    return PMInteractionDiagram(section, mat, points, control_indices)
end

"""
    _find_pure_bending_c(section::RCColumnSection, mat; tol=0.1) -> Float64

Find neutral axis depth c where Pn ≈ 0 (pure bending) using bisection.

Brackets between a small c (tension-dominated) and c = d (compression-dominated),
then iterates up to 50 times until |Pn| < `tol` (kip).
"""
function _find_pure_bending_c(section::RCColumnSection, mat; tol::Float64=0.1)
    h = to_inches(section.h)
    d = to_inches(effective_depth(section))
    
    # Bracket: c between small value and balanced point
    c_low = 0.5  # Small c → tension dominates
    c_high = d   # At d, compression still dominates
    
    # Check that we have a valid bracket
    result_low = calculate_PM_at_c(section, mat, c_low)
    result_high = calculate_PM_at_c(section, mat, c_high)
    
    if result_low.Pn > 0 && result_high.Pn > 0
        # Both positive, try smaller c_low
        c_low = 0.1
        result_low = calculate_PM_at_c(section, mat, c_low)
    end
    
    # Bisection
    for _ in 1:50
        c_mid = (c_low + c_high) / 2
        result_mid = calculate_PM_at_c(section, mat, c_mid)
        
        if abs(result_mid.Pn) < tol
            return c_mid
        elseif result_mid.Pn > 0
            c_high = c_mid
        else
            c_low = c_mid
        end
    end
    
    # Return best guess
    return (c_low + c_high) / 2
end

"""
    _add_intermediate_points(section, mat, control_points, n_per_segment) -> Vector{PMDiagramPoint}

Insert `n_per_segment` evenly-spaced intermediate P-M points between the largest and
smallest finite control-point c values for a smooth strong-axis interaction curve.
"""
function _add_intermediate_points(
    section::RCColumnSection, 
    mat, 
    control_points::Vector{PMDiagramPoint},
    n_per_segment::Int
)
    # Extract c values from control points (skip Inf values)
    c_values = Float64[]
    for pt in control_points
        if isfinite(pt.c) && pt.c > 0
            push!(c_values, pt.c)
        end
    end
    sort!(c_values, rev=true)  # Largest c first (compression end)
    
    # Generate intermediate c values
    all_points = PMDiagramPoint[]
    
    # Add pure compression point
    push!(all_points, control_points[1])
    push!(all_points, control_points[2])
    
    # Sweep c from large to small
    c_max = maximum(c_values)
    c_min = minimum(c_values)
    
    c_sweep = range(c_max, c_min, length=n_per_segment + 2)[2:end-1]
    
    for c in c_sweep
        result = calculate_phi_PM_at_c(section, mat, c)
        push!(all_points, PMDiagramPoint(
            c, result.εt,
            result.Pn, result.Mn,
            result.φ, result.φPn, result.φMn,
            INTERMEDIATE
        ))
    end
    
    # Add remaining control points (pure bending, pure tension)
    push!(all_points, control_points[end-1])  # Pure bending
    push!(all_points, control_points[end])    # Pure tension
    
    return all_points
end

# ==============================================================================
# Diagram Access Functions
# ==============================================================================

"""
    get_nominal_curve(diagram::PMInteractionDiagram) -> NamedTuple{(:Pn, :Mn)}

Return vectors of nominal axial (kip) and moment (kip-ft) capacities from all diagram points.
"""
function get_nominal_curve(diagram::PMInteractionDiagram)
    Pn = [pt.Pn for pt in diagram.points]
    Mn = [pt.Mn for pt in diagram.points]
    return (Pn=Pn, Mn=Mn)
end

"""
    get_factored_curve(diagram::PMInteractionDiagram) -> NamedTuple{(:φPn, :φMn)}

Return vectors of factored axial (kip) and moment (kip-ft) capacities from all diagram points.
"""
function get_factored_curve(diagram::PMInteractionDiagram)
    φPn = [pt.φPn for pt in diagram.points]
    φMn = [pt.φMn for pt in diagram.points]
    return (φPn=φPn, φMn=φMn)
end

"""
    get_control_points(diagram::PMInteractionDiagram) -> Vector{PMDiagramPoint}

Return only the named ACI control points (excludes intermediate interpolation points).
"""
function get_control_points(diagram::PMInteractionDiagram)
    return filter(pt -> pt.control_type != INTERMEDIATE, diagram.points)
end

"""
    get_control_point(diagram::PMInteractionDiagram, name::Symbol) -> PMDiagramPoint

Retrieve a named control point (e.g. `:balanced`, `:pure_bending`). Throws on unknown name.
"""
function get_control_point(diagram::PMInteractionDiagram, name::Symbol)
    idx = get(diagram.control_points, name, nothing)
    if isnothing(idx)
        error("Control point :$name not found. Available: $(keys(diagram.control_points))")
    end
    return diagram.points[idx]
end

# ==============================================================================
# Capacity Check Functions
# ==============================================================================

"""
    check_PM_capacity(diagram::PMInteractionDiagram, Pu::Real, Mu::Real) -> NamedTuple

Check if demand (Pu, Mu) is within the factored P-M capacity envelope.

# Arguments
- `diagram`: PMInteractionDiagram for the section
- `Pu`: Factored axial demand (kip), positive = compression
- `Mu`: Factored moment demand (kip-ft), absolute value

# Returns
NamedTuple with:
- `adequate`: Bool - true if demand is within capacity
- `utilization`: Float64 - demand/capacity ratio (1.0 = at limit)
- `φPn_at_Mu`: Float64 - factored axial capacity at the given moment
- `φMn_at_Pu`: Float64 - factored moment capacity at the given axial load
- `governing`: Symbol - which limit governs (:axial, :moment, :combined)

# Notes
Uses linear interpolation between diagram points.
"""
function check_PM_capacity(diagram::PMInteractionDiagram, Pu::Real, Mu::Real)
    Mu_abs = abs(Mu)  # Demand magnitude (kip-ft)

    # Get factored curve
    curve = get_factored_curve(diagram)
    φPn = curve.φPn
    φMn = curve.φMn

    # Find φMn capacity at the given Pu by interpolation
    φMn_at_Pu = _interpolate_moment_at_P(φPn, φMn, Pu)

    # Find φPn capacity at the given Mu by interpolation
    φPn_at_Mu = _interpolate_axial_at_M(φPn, φMn, Mu_abs)

    # Near-pure axial (Mu = 0 is common from symmetric framing): at this P the diagram can
    # report φMn_at_Pu = 0 even when axial capacity is ample. The old fallback (utilization = 1.5)
    # incorrectly marked every such point inadequate and broke `design_column_reinforcement`.
    axial_tol_M = 1e-6  # kip-ft
    if Mu_abs ≤ axial_tol_M && abs(φPn_at_Mu) > 0
        utilization = abs(Pu) / abs(φPn_at_Mu)
        governing = :axial
    elseif φMn_at_Pu > 0 && abs(φPn_at_Mu) > 0
        # Combined check: ratio of demand to capacity at constant P/M ratio
        utilization_M = Mu_abs / max(φMn_at_Pu, 1e-6)
        utilization_P = abs(Pu) / max(abs(φPn_at_Mu), 1e-6)
        utilization = max(utilization_M, utilization_P)

        if utilization_M > utilization_P
            governing = :moment
        elseif utilization_P > utilization_M
            governing = :axial
        else
            governing = :combined
        end
    elseif φMn_at_Pu > 0
        utilization = Mu_abs / φMn_at_Pu
        governing = :moment
    elseif abs(φPn_at_Mu) > 0
        utilization = abs(Pu) / abs(φPn_at_Mu)
        governing = :axial
    else
        utilization = 1.5  # Over capacity / indeterminate
        governing = :combined
    end

    adequate = utilization ≤ 1.0

    return (
        adequate = adequate,
        utilization = utilization,
        φMn_at_Pu = φMn_at_Pu,
        φPn_at_Mu = φPn_at_Mu,
        governing = governing
    )
end

"""
    capacity_at_axial(diagram::PMInteractionDiagram, Pu::Real) -> Float64

Get factored moment capacity φMn at a given factored axial load Pu.

# Arguments
- `diagram`: PMInteractionDiagram
- `Pu`: Factored axial demand (kip), positive = compression

# Returns
- φMn: Factored moment capacity (kip-ft) at the given Pu
"""
function capacity_at_axial(diagram::PMInteractionDiagram, Pu::Real)
    curve = get_factored_curve(diagram)
    return _interpolate_moment_at_P(curve.φPn, curve.φMn, Pu)
end

"""
    capacity_at_moment(diagram::PMInteractionDiagram, Mu::Real) -> Float64

Get factored axial capacity φPn at a given factored moment Mu.

# Arguments
- `diagram`: PMInteractionDiagram  
- `Mu`: Factored moment demand (kip-ft)

# Returns
- φPn: Factored axial capacity (kip) at the given Mu
"""
function capacity_at_moment(diagram::PMInteractionDiagram, Mu::Real)
    curve = get_factored_curve(diagram)
    return _interpolate_axial_at_M(curve.φPn, curve.φMn, abs(Mu))
end

"""
    utilization_ratio(diagram::PMInteractionDiagram, Pu::Real, Mu::Real) -> Float64

Calculate the utilization ratio for a demand point (Pu, Mu).

# Returns
- Ratio ≤ 1.0 means adequate capacity
- Ratio > 1.0 means demand exceeds capacity
"""
function utilization_ratio(diagram::PMInteractionDiagram, Pu::Real, Mu::Real)
    result = check_PM_capacity(diagram, Pu, Mu)
    return result.utilization
end

# ==============================================================================
# Interpolation Helpers
# ==============================================================================

"""
    _interpolate_moment_at_P(φPn, φMn, Pu) -> Float64

Linearly interpolate factored moment capacity φMn (kip-ft) at a given axial load Pu (kip)
along the P-M interaction curve.
"""
function _interpolate_moment_at_P(φPn::Vector, φMn::Vector, Pu::Real)
    n = length(φPn)
    
    # Handle edge cases
    if Pu ≥ maximum(φPn)
        # At or above max compression - find the φMn at max φPn
        idx = argmax(φPn)
        return φMn[idx]
    elseif Pu ≤ minimum(φPn)
        # At or below max tension
        idx = argmin(φPn)
        return φMn[idx]
    end
    
    # Find bracketing points
    # The curve goes from high P (compression) to low P (tension)
    for i in 1:(n-1)
        P1, P2 = φPn[i], φPn[i+1]
        M1, M2 = φMn[i], φMn[i+1]
        
        # Check if Pu is between these points
        if (P1 ≥ Pu ≥ P2) || (P2 ≥ Pu ≥ P1)
            # Linear interpolation
            if abs(P1 - P2) < 1e-10
                return (M1 + M2) / 2
            end
            t = (Pu - P1) / (P2 - P1)
            return M1 + t * (M2 - M1)
        end
    end
    
    # Fallback: return closest point (allocation-free)
    best_idx = 1
    best_diff = abs(φPn[1] - Pu)
    @inbounds for k in 2:length(φPn)
        d = abs(φPn[k] - Pu)
        if d < best_diff
            best_diff = d
            best_idx = k
        end
    end
    return φMn[best_idx]
end

"""
    _interpolate_axial_at_M(φPn, φMn, Mu) -> Float64

Linearly interpolate factored axial capacity φPn (kip) at a given moment Mu (kip-ft)
along the P-M interaction curve. Returns the maximum φPn when multiple intersections exist.
"""
function _interpolate_axial_at_M(φPn::Vector, φMn::Vector, Mu::Real)
    n = length(φMn)
    
    # Handle edge cases
    if Mu ≤ minimum(φMn)
        # At or below minimum moment (pure axial cases)
        # Return max compression capacity
        return maximum(φPn)
    end
    
    max_M = maximum(φMn)
    if Mu ≥ max_M
        # Beyond the envelope - interpolate along the tension side
        # Find the point with maximum moment and return its P
        idx = argmax(φMn)
        return φPn[idx]
    end
    
    # The P-M curve is not single-valued in M (moment increases then decreases)
    # Find all points where M ≈ Mu and return the max P (conservative for compression)
    matching_P = Float64[]
    for i in 1:(n-1)
        M1, M2 = φMn[i], φMn[i+1]
        P1, P2 = φPn[i], φPn[i+1]
        
        # Check if Mu is between these points
        if (M1 ≤ Mu ≤ M2) || (M2 ≤ Mu ≤ M1)
            if abs(M1 - M2) < 1e-10
                push!(matching_P, (P1 + P2) / 2)
            else
                t = (Mu - M1) / (M2 - M1)
                push!(matching_P, P1 + t * (P2 - P1))
            end
        end
    end
    
    if isempty(matching_P)
        # Fallback: return closest point (allocation-free)
        best_idx = 1
        best_diff = abs(φMn[1] - Mu)
        @inbounds for k in 2:length(φMn)
            d = abs(φMn[k] - Mu)
            if d < best_diff
                best_diff = d
                best_idx = k
            end
        end
        return φPn[best_idx]
    end
    
    # Return max P (most conservative for compression check)
    return maximum(matching_P)
end

# ==============================================================================
# Y-AXIS P-M INTERACTION (Biaxial Bending Support)
# ==============================================================================
# Reference: StructurePoint "Biaxial Bending Interaction Diagrams for Rectangular
# Reinforced Concrete Column Design (ACI 318-11)"
#
# For rectangular columns with b ≠ h:
# - X-axis bending: Moment about horizontal axis, depth = h, width = b
# - Y-axis bending: Moment about vertical axis, depth = b, width = h
#
# The y-axis diagram uses the same strain compatibility procedure but with:
# - Compression face at RIGHT side (x = b)
# - Section depth = b, width = h
# - Bar distance measured from right edge (b - bar.x)
# ==============================================================================

"""
    calculate_PM_at_c(section::RCColumnSection, mat, c_in::Real, ::WeakAxis) -> NamedTuple

Calculate nominal (Pn, Mn) capacity for WEAK-AXIS BENDING at a given neutral axis depth c.

For y-axis bending (moment about vertical axis):
- Compression face at RIGHT (x = b)
- Tension face at LEFT (x = 0)
- Section "depth" = b (width becomes depth for this bending direction)
- Section "width" = h (height becomes width for this bending direction)

# Arguments
- `section`: RCColumnSection with bar positions
- `mat`: Material properties
- `c_in`: Neutral axis depth from compression face (right side) in inches

# Returns
NamedTuple with Pn (kip), Mn (kip-ft), εt, c

# Reference
StructurePoint: "Biaxial Bending Interaction Diagrams for Rectangular RC Column Design"
"""
function calculate_PM_at_c(section::RCColumnSection, mat, c_in::Real, ::WeakAxis)
    # Extract material properties
    fc = fc_ksi(mat)
    fy = fy_ksi(mat)
    Es = Es_ksi(mat)
    εcu_val = εcu(mat)
    
    # For y-axis bending: swap roles of b and h
    # "depth" for bending = b (compression/tension in x-direction)
    # "width" for concrete area = h
    depth = to_inches(section.b)  # This is the bending depth
    width = to_inches(section.h)  # This is the compression block width
    
    # Whitney stress block
    β₁ = beta1(mat)
    a = β₁ * c_in
    a_eff = min(a, depth)
    
    # Concrete compression force: Cc = 0.85 * f'c * width * a
    # For y-axis: width = h (the dimension perpendicular to bending)
    Cc = 0.85 * fc * width * a_eff  # kip
    
    # Concrete force location from compression face (right side, x = b)
    x_Cc_from_right = a_eff / 2
    
    # Steel forces
    Fs_total = 0.0
    Ms_total = 0.0
    
    centroid_from_right = depth / 2  # Section centroid from compression face
    fc_stress = 0.85 * fc
    
    for bar in section.bars
        # Bar x is from left edge → distance from RIGHT = b - bar.x
        x_bar_from_right = depth - to_inches(bar.x)
        As_bar = to_sqinches(bar.As)
        
        # Steel strain at this bar (using x position for y-axis bending)
        εs = calculate_steel_strain(x_bar_from_right, c_in, depth, εcu_val)
        
        # Steel stress
        fs = calculate_steel_stress(εs, fy, Es)
        
        # Check if bar is within compression zone
        in_compression_zone = x_bar_from_right < a_eff
        
        # Steel force contribution
        if in_compression_zone
            Fs = -As_bar * (fs + fc_stress)
        else
            Fs = -fs * As_bar
        end
        
        Fs_total += Fs
        
        # Moment about section centroid (y-axis)
        arm = centroid_from_right - x_bar_from_right
        Ms_total += Fs * arm
    end
    
    # Extreme tension strain: bar closest to left edge (smallest x)
    x_tension_bar_from_left = minimum(to_inches(bar.x) for bar in section.bars)
    x_tension_from_right = depth - x_tension_bar_from_left  # = d for y-axis
    εt = calculate_steel_strain(x_tension_from_right, c_in, depth, εcu_val)
    
    # Total axial force
    Pn = Cc + Fs_total
    
    # Total moment about y-axis centroid (kip-in, then converted to kip-ft)
    Mc = Cc * (centroid_from_right - x_Cc_from_right)
    Mn_kipin = Mc + Ms_total
    Mn = Mn_kipin / 12.0  # → kip-ft
    
    return (Pn = Pn, Mn = abs(Mn), εt = εt, c = c_in)
end

"""
    calculate_phi_PM_at_c(section::RCColumnSection, mat, c_in::Real, ::WeakAxis) -> NamedTuple

Calculate factored (φPn, φMn) capacity for weak-axis bending at a given neutral axis depth.
"""
function calculate_phi_PM_at_c(section::RCColumnSection, mat, c_in::Real, ::WeakAxis)
    result = calculate_PM_at_c(section, mat, c_in, WeakAxis())
    φ = phi_factor(result.εt, section.tie_type; fy_ksi=fy_ksi(mat), Es_ksi=Es_ksi(mat))
    
    return (
        Pn = result.Pn,
        Mn = result.Mn,
        φPn = φ * result.Pn,
        φMn = φ * result.Mn,
        φ = φ,
        εt = result.εt,
        c = result.c
    )
end

"""
    effective_depth(section::RCColumnSection, ::WeakAxis) -> Float64

Calculate effective depth for weak-axis bending (distance from right face to leftmost bars).
"""
function effective_depth(section::RCColumnSection, ::WeakAxis)
    b = to_inches(section.b)
    x_min = minimum(to_inches(bar.x) for bar in section.bars)
    return b - x_min  # d for y-axis bending
end

"""
    _find_pure_bending_c(section::RCColumnSection, mat, ::WeakAxis; tol=0.1) -> Float64

Find c value for pure bending (Pn ≈ 0) about weak axis using bisection.
"""
function _find_pure_bending_c(section::RCColumnSection, mat, ::WeakAxis; tol::Float64=0.1)
    d = effective_depth(section, WeakAxis())
    
    c_low = 0.5
    c_high = d
    
    result_low = calculate_PM_at_c(section, mat, c_low, WeakAxis())
    result_high = calculate_PM_at_c(section, mat, c_high, WeakAxis())
    
    if result_low.Pn > 0 && result_high.Pn > 0
        c_low = 0.1
        result_low = calculate_PM_at_c(section, mat, c_low, WeakAxis())
    end
    
    for _ in 1:50
        c_mid = (c_low + c_high) / 2
        result_mid = calculate_PM_at_c(section, mat, c_mid, WeakAxis())
        
        if abs(result_mid.Pn) < tol
            return c_mid
        elseif result_mid.Pn > 0
            c_high = c_mid
        else
            c_low = c_mid
        end
    end
    
    return (c_low + c_high) / 2
end

"""
    generate_PM_diagram(section::RCColumnSection, mat, ::WeakAxis; n_intermediate::Int=20)

Generate P-M interaction diagram for weak-axis bending (Mny capacity).

This is used for biaxial bending checks where rectangular columns have different
capacities about each axis.

# Arguments
- `section`: RC column section
- `mat`: Material properties
- `n_intermediate`: Number of intermediate points

# Returns
PMInteractionDiagram for weak-axis bending

# Reference
StructurePoint: "Biaxial Bending Interaction Diagrams for Rectangular RC Column Design"
"""
function generate_PM_diagram(section::RCColumnSection, mat, ::WeakAxis; n_intermediate::Int=20)
    # Material properties
    fc = fc_ksi(mat)
    fy = fy_ksi(mat)
    Es = Es_ksi(mat)
    εcu_val = εcu(mat)
    εy = fy / Es
    
    # For weak-axis: use b as the depth, d from leftmost bars to right face
    b = to_inches(section.b)
    d = effective_depth(section, WeakAxis())
    
    points = PMDiagramPoint[]
    control_indices = Dict{Symbol, Int}()
    
    # Pure compression (same as x-axis - section squashes uniformly)
    P0 = pure_compression_capacity(section, mat)
    φ_comp = section.tie_type == :spiral ? 0.75 : 0.65
    push!(points, PMDiagramPoint(
        Inf, -εy, P0, 0.0, φ_comp, φ_comp * P0, 0.0, PURE_COMPRESSION
    ))
    control_indices[:pure_compression] = length(points)
    
    # Maximum allowable compression
    α = section.tie_type == :spiral ? 0.85 : 0.80
    Pn_max = α * P0
    c_large = 5.0 * b
    result_large = calculate_phi_PM_at_c(section, mat, c_large, WeakAxis())
    push!(points, PMDiagramPoint(
        c_large, result_large.εt, Pn_max, result_large.Mn,
        φ_comp, φ_comp * Pn_max, φ_comp * result_large.Mn, MAX_COMPRESSION
    ))
    control_indices[:max_compression] = length(points)
    
    # fs = 0 (c = d)
    c_fs0 = d
    result_fs0 = calculate_phi_PM_at_c(section, mat, c_fs0, WeakAxis())
    push!(points, PMDiagramPoint(
        c_fs0, result_fs0.εt, result_fs0.Pn, result_fs0.Mn,
        result_fs0.φ, result_fs0.φPn, result_fs0.φMn, FS_ZERO
    ))
    control_indices[:fs_zero] = length(points)
    
    # fs = 0.5fy
    εt_half = 0.5 * εy
    c_half = c_from_εt(εt_half, d, εcu_val)
    result_half = calculate_phi_PM_at_c(section, mat, c_half, WeakAxis())
    push!(points, PMDiagramPoint(
        c_half, result_half.εt, result_half.Pn, result_half.Mn,
        result_half.φ, result_half.φPn, result_half.φMn, FS_HALF_FY
    ))
    control_indices[:fs_half_fy] = length(points)
    
    # Balanced (fs = fy)
    c_balanced = c_from_εt(εy, d, εcu_val)
    result_balanced = calculate_phi_PM_at_c(section, mat, c_balanced, WeakAxis())
    push!(points, PMDiagramPoint(
        c_balanced, result_balanced.εt, result_balanced.Pn, result_balanced.Mn,
        result_balanced.φ, result_balanced.φPn, result_balanced.φMn, BALANCED
    ))
    control_indices[:balanced] = length(points)
    
    # Tension controlled (εt = εy + 0.003)
    εt_tension = εy + 0.003
    c_tension = c_from_εt(εt_tension, d, εcu_val)
    result_tension = calculate_phi_PM_at_c(section, mat, c_tension, WeakAxis())
    push!(points, PMDiagramPoint(
        c_tension, result_tension.εt, result_tension.Pn, result_tension.Mn,
        result_tension.φ, result_tension.φPn, result_tension.φMn, TENSION_CONTROLLED
    ))
    control_indices[:tension_controlled] = length(points)
    
    # Pure bending
    c_pure_m = _find_pure_bending_c(section, mat, WeakAxis())
    result_pure_m = calculate_phi_PM_at_c(section, mat, c_pure_m, WeakAxis())
    push!(points, PMDiagramPoint(
        c_pure_m, result_pure_m.εt, result_pure_m.Pn, result_pure_m.Mn,
        result_pure_m.φ, result_pure_m.φPn, result_pure_m.φMn, PURE_BENDING
    ))
    control_indices[:pure_bending] = length(points)
    
    # Pure tension
    As_total = to_sqinches(section.As_total)
    Pnt = -fy * As_total
    push!(points, PMDiagramPoint(
        -Inf, Inf, Pnt, 0.0, 0.90, 0.90 * Pnt, 0.0, PURE_TENSION
    ))
    control_indices[:pure_tension] = length(points)
    
    # Add intermediate points
    if n_intermediate > 0
        points = _add_intermediate_points(section, mat, points, n_intermediate, WeakAxis())
    end
    
    return PMInteractionDiagram(section, mat, points, control_indices)
end

"""
    _add_intermediate_points(section, mat, control_points, n_per_segment, ::WeakAxis) -> Vector{PMDiagramPoint}

Insert `n_per_segment` evenly-spaced intermediate P-M points between the largest and
smallest finite control-point c values for a smooth weak-axis interaction curve.
"""
function _add_intermediate_points(
    section::RCColumnSection, 
    mat, 
    control_points::Vector{PMDiagramPoint},
    n_per_segment::Int,
    ::WeakAxis
)
    c_values = Float64[]
    for pt in control_points
        if isfinite(pt.c) && pt.c > 0
            push!(c_values, pt.c)
        end
    end
    sort!(c_values, rev=true)
    
    all_points = PMDiagramPoint[]
    
    push!(all_points, control_points[1])
    push!(all_points, control_points[2])
    
    c_max = maximum(c_values)
    c_min = minimum(c_values)
    
    c_sweep = range(c_max, c_min, length=n_per_segment + 2)[2:end-1]
    
    for c in c_sweep
        result = calculate_phi_PM_at_c(section, mat, c, WeakAxis())
        push!(all_points, PMDiagramPoint(
            c, result.εt, result.Pn, result.Mn,
            result.φ, result.φPn, result.φMn, INTERMEDIATE
        ))
    end
    
    push!(all_points, control_points[end-1])
    push!(all_points, control_points[end])
    
    return all_points
end

"""
    generate_PM_diagrams_biaxial(section::RCColumnSection, mat; n_intermediate::Int=20)

Generate P-M interaction diagrams for BOTH axes (biaxial bending support).

# Returns
NamedTuple with:
- `x`: PMInteractionDiagram for x-axis bending (Mnx)
- `y`: PMInteractionDiagram for y-axis bending (Mny)

# Reference
StructurePoint: "Manual Design Procedure for Columns and Walls with Biaxial Bending"
"""
function generate_PM_diagrams_biaxial(section::RCColumnSection, mat; n_intermediate::Int=20)
    diagram_x = generate_PM_diagram(section, mat; n_intermediate=n_intermediate)
    diagram_y = generate_PM_diagram(section, mat, WeakAxis(); n_intermediate=n_intermediate)
    return (x = diagram_x, y = diagram_y)
end

# ==============================================================================
# Column Reinforcement Design for Fixed Dimensions
# ==============================================================================

"""
    design_column_reinforcement(
        b::Length, h::Length, 
        Pu::Real, Mu::Real, 
        mat;
        cover::Length = 1.5u"inch",
        tie_type::Symbol = :tied,
        bar_sizes = [6, 7, 8, 9, 10, 11],
        n_bars_options = [4, 6, 8, 10, 12, 14, 16, 20],
        min_rho::Float64 = 0.01,
        max_rho::Float64 = 0.08
    ) -> RCColumnSection

Design reinforcement for a column with fixed dimensions to resist given demands.

Uses P-M interaction analysis to find the minimum reinforcement that:
1. Provides adequate capacity for (Pu, Mu)
2. Satisfies ACI 318-11 ρg limits (0.01 ≤ ρg ≤ 0.08)

# Arguments
- `b`, `h`: Column dimensions (with units)
- `Pu`: Factored axial load (kip, positive = compression)
- `Mu`: Factored moment (kip-ft)
- `mat`: Concrete material
- `cover`: Clear cover (default 1.5")
- `tie_type`: :tied or :spiral
- `bar_sizes`: Available bar sizes to try (ascending order preferred)
- `n_bars_options`: Number of bars to try
- `min_rho`, `max_rho`: ACI reinforcement ratio limits

# Returns
RCColumnSection with minimum reinforcement that satisfies demands and ρg ≥ min_rho

# Notes
- Tries combinations in order of increasing steel area
- First valid combination is returned (minimum weight)
- Throws error if no valid combination found

# Example
```julia
b, h = 20u"inch", 20u"inch"
Pu, Mu = 300.0, 150.0  # kip, kip-ft
section = design_column_reinforcement(b, h, Pu, Mu, NWC_4000)
```
"""
function design_column_reinforcement(
    b::Length, h::Length, 
    Pu::Real, Mu::Real, 
    mat;
    cover::Length = 1.5u"inch",
    tie_type::Symbol = :tied,
    bar_sizes = [6, 7, 8, 9, 10, 11],
    n_bars_options::Union{Nothing, Vector{Int}} = nothing,
    min_rho::Float64 = 0.01,
    max_rho::Float64 = 0.08
)
    # Convert dimensions
    b_in = ustrip(u"inch", b)
    h_in = ustrip(u"inch", h)
    Ag = b_in * h_in
    
    # Standard bar areas (ASTM A615)
    bar_areas = Dict(
        3 => 0.11, 4 => 0.20, 5 => 0.31, 6 => 0.44,
        7 => 0.60, 8 => 0.79, 9 => 1.00, 10 => 1.27,
        11 => 1.56, 14 => 2.25, 18 => 4.00
    )
    
    # Minimum number of bars (ACI 10.7.3.1)
    min_bars = tie_type == :spiral ? 6 : 4

    # Auto-extend bar counts for large columns so ρ_min is reachable.
    # With the largest standard bar (#11, Ab=1.56 in²), n_bars_max must satisfy
    # n * 1.56 / Ag ≥ min_rho ⟹ n ≥ ceil(min_rho * Ag / 1.56).
    # Use even counts only (symmetric placement) and cap at a practical 40.
    if n_bars_options === nothing
        As_min = min_rho * Ag
        Ab_max = maximum(bar_areas[bs] for bs in bar_sizes)
        n_needed = Int(ceil(As_min / Ab_max))
        n_ceil = max(20, n_needed + mod(n_needed, 2))   # round up to even
        n_ceil = min(n_ceil, 40)                          # practical ceiling
        n_bars_options = sort(unique([4, 6, 8, 10, 12, 14, 16, 20,
                                      collect(22:2:n_ceil)...]))
    end
    
    # Generate candidates sorted by steel area (ascending = minimum weight first)
    candidates = Tuple{Int, Int, Float64}[]  # (bar_size, n_bars, As)
    
    for bar_size in bar_sizes
        Ab = bar_areas[bar_size]
        for n_bars in n_bars_options
            n_bars >= min_bars || continue
            
            As = n_bars * Ab
            ρ = As / Ag
            
            # Skip if outside ACI limits
            (min_rho ≤ ρ ≤ max_rho) || continue
            
            push!(candidates, (bar_size, n_bars, As))
        end
    end
    
    # Sort by steel area (minimum first)
    sort!(candidates, by = x -> x[3])
    
    # Try each candidate
    for (bar_size, n_bars, As) in candidates
        try
            section = RCColumnSection(
                b = b, h = h,
                bar_size = bar_size,
                n_bars = n_bars,
                cover = cover,
                tie_type = tie_type
            )
            
            # Check P-M capacity using the diagram
            diagram = generate_PM_diagram(section, mat; n_intermediate=10)
            result = check_PM_capacity(diagram, Pu, Mu)
            
            if result.adequate
                return section
            end
        catch e
            @debug "Skipping bar arrangement" n_bars bar_size exception=(e, catch_backtrace())
            continue
        end
    end
    
    # No valid combination found - try with maximum reinforcement
    # This indicates the column dimensions are too small for the demands
    error("Cannot design reinforcement for $(b_in)\"×$(h_in)\" column with Pu=$(Pu) kip, Mu=$(Mu) kip-ft. " *
          "Consider larger column dimensions.")
end

"""
    resize_column_with_reinforcement(
        section::RCColumnSection,
        new_b::Length, new_c::Length,
        Pu::Real, Mu::Real,
        mat;
        kwargs...
    ) -> RCColumnSection

Resize a column to new dimensions while properly re-designing reinforcement.

This replaces the simple `scale_column_section` approach when column dimensions
are increased (e.g., for punching shear requirements). Instead of keeping the
same bars (which would reduce ρg below 0.01), this function uses P-M analysis
to design new reinforcement appropriate for the larger section.

# Arguments
- `section`: Original RCColumnSection (used for cover and tie_type defaults)
- `new_b`, `new_c`: New column dimensions
- `Pu`, `Mu`: Design demands (kip, kip-ft)
- `mat`: Concrete material
- `kwargs`: Passed to design_column_reinforcement

# Returns
New RCColumnSection with properly designed reinforcement

# Example
```julia
# Original 16" column from P-M design
sec = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=8, n_bars=8)

# Need 20" for punching shear - properly redesign reinforcement
new_sec = resize_column_with_reinforcement(sec, 20u"inch", 20u"inch", 300.0, 150.0, NWC_4000)
```
"""
function resize_column_with_reinforcement(
    section::RCColumnSection,
    new_b::Length, new_c::Length,
    Pu::Real, Mu::Real,
    mat;
    kwargs...
)
    # Use original section's cover and tie_type
    design_column_reinforcement(
        new_b, new_c, Pu, Mu, mat;
        cover = section.cover,
        tie_type = section.tie_type,
        kwargs...
    )
end