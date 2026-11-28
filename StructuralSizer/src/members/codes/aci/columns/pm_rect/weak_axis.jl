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
function generate_PM_diagram(section::RCColumnSection, mat, ::WeakAxis; n_intermediate::Int=PM_DIAGRAM_N_INTERMEDIATE)
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
function generate_PM_diagrams_biaxial(section::RCColumnSection, mat; n_intermediate::Int=PM_DIAGRAM_N_INTERMEDIATE)
    diagram_x = generate_PM_diagram(section, mat; n_intermediate=n_intermediate)
    diagram_y = generate_PM_diagram(section, mat, WeakAxis(); n_intermediate=n_intermediate)
    return (x = diagram_x, y = diagram_y)
end

