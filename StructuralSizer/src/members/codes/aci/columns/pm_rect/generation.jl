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
function generate_PM_diagram(section::RCColumnSection, mat; n_intermediate::Int=PM_DIAGRAM_N_INTERMEDIATE)
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

