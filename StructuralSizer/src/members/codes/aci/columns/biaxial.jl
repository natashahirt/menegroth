# ==============================================================================
# ACI 318-11 Biaxial Bending for RC Columns
# ==============================================================================
# Reference: ACI 318-11 and StructurePoint Design Examples:
# - "Manual Design Procedure for Columns and Walls with Biaxial Bending"
# - "Biaxial Bending Interaction Diagrams for Square RC Column Design"
# - "Biaxial Bending Interaction Diagrams for Rectangular RC Column Design"

using Unitful
using Asap: to_inches

# ==============================================================================
# Bresler Reciprocal Load Method
# ==============================================================================

"""
    bresler_reciprocal_load(Pnx, Pny, P0) -> Float64

Calculate biaxial capacity using Bresler's Reciprocal Load Method.
Per ACI Commentary and PCA Notes.

Formula: 1/Pn = 1/Pnx + 1/Pny - 1/P0

# Arguments
- `Pnx`: Nominal axial capacity under Mux only (Muy = 0) (kip)
- `Pny`: Nominal axial capacity under Muy only (Mux = 0) (kip)
- `P0`: Pure axial capacity (no moment) (kip)

# Returns
- `Pn`: Biaxial nominal axial capacity (kip)

# Notes
- Best for high P/low M combinations
- Not accurate near pure bending
- Conservative for most cases
"""
function bresler_reciprocal_load(Pnx::Real, Pny::Real, P0::Real)
    if Pnx ≤ 0 || Pny ≤ 0 || P0 ≤ 0
        return 0.0
    end
    
    inv_Pn = 1/Pnx + 1/Pny - 1/P0
    
    if inv_Pn ≤ 0
        return P0  # Capacity exceeds P0, cap at P0
    end
    
    return 1 / inv_Pn
end

"""
    check_bresler_reciprocal(Pu, Pnx, Pny, P0) -> Float64

Check biaxial capacity using Bresler's Reciprocal Load Method.

# Returns
- Utilization ratio: Pu/Pn (≤ 1.0 is adequate)
"""
function check_bresler_reciprocal(Pu::Real, Pnx::Real, Pny::Real, P0::Real)
    Pn = bresler_reciprocal_load(Pnx, Pny, P0)
    return Pu > 0 ? Pu / max(Pn, 1e-6) : 0.0
end

# ==============================================================================
# Bresler Load Contour Method
# ==============================================================================

"""
    bresler_load_contour(Mux, Muy, φMnx, φMny; α=1.5) -> Float64

Check biaxial capacity using Bresler's Load Contour Method.
Per ACI Commentary and Bresler (1960).

Formula: (Mux/φMnx)^α + (Muy/φMny)^α ≤ 1.0

# Arguments
- `Mux`: Factored moment about x-axis (kip-ft)
- `Muy`: Factored moment about y-axis (kip-ft)
- `φMnx`: Factored moment capacity about x-axis at given Pu (kip-ft)
- `φMny`: Factored moment capacity about y-axis at given Pu (kip-ft)
- `α`: Load contour exponent (default 1.5)

# Returns
- Utilization ratio (≤ 1.0 is adequate)

# Notes on α
- α = 1.0: Linear (conservative)
- α = 1.15-1.55: Typical range
- α = 1.5: Common default
- α = 2.0: Circular interaction (unconservative for most cases)
"""
function bresler_load_contour(
    Mux::Real, Muy::Real, 
    φMnx::Real, φMny::Real;
    α::Real = 1.5
)
    if φMnx ≤ 0 || φMny ≤ 0
        return Inf  # No capacity
    end
    
    Mux = abs(Mux)
    Muy = abs(Muy)
    
    ratio_x = Mux / φMnx
    ratio_y = Muy / φMny
    
    return ratio_x^α + ratio_y^α
end

# ==============================================================================
# PCA Load Contour Method
# ==============================================================================

"""
    pca_load_contour(Mux, Muy, φMnox, φMnoy, Pu, φPn, φP0; β=0.65) -> Float64

Check biaxial capacity using PCA Load Contour Method.
Per Portland Cement Association Notes on ACI 318.

Formula: Mux/φMnox + β(Muy/φMnoy) ≤ 1.0  (for Mnx/Mny > b/h)
      or β(Mux/φMnox) + Muy/φMnoy ≤ 1.0  (for Mnx/Mny < b/h)

# Arguments  
- `Mux`: Factored moment about x-axis (kip-ft)
- `Muy`: Factored moment about y-axis (kip-ft)
- `φMnox`: Factored uniaxial x-moment capacity (Muy=0) at given Pu (kip-ft)
- `φMnoy`: Factored uniaxial y-moment capacity (Mux=0) at given Pu (kip-ft)
- `Pu`: Factored axial load (kip)
- `φPn`: Factored axial capacity (kip)
- `φP0`: Factored pure axial capacity (kip)
- `β`: Biaxial factor (default 0.65)

# Returns
- Utilization ratio (≤ 1.0 is adequate)

# Note
β is approximated as: β = (φPn - Pu) / (φPn - φPb)
where φPb is the balanced load. For typical columns, β ≈ 0.65.
"""
function pca_load_contour(
    Mux::Real, Muy::Real,
    φMnox::Real, φMnoy::Real,
    Pu::Real, φPn::Real, φP0::Real;
    β::Real = 0.65
)
    if φMnox ≤ 0 || φMnoy ≤ 0
        return Inf
    end
    
    Mux = abs(Mux)
    Muy = abs(Muy)
    
    ratio_x = Mux / φMnox
    ratio_y = Muy / φMnoy
    
    # Use whichever controls
    util1 = ratio_x + β * ratio_y
    util2 = β * ratio_x + ratio_y
    
    return max(util1, util2)
end

# ==============================================================================
# Unified Biaxial Check
# ==============================================================================

"""
    check_biaxial_capacity(
        diagram_x::PMInteractionDiagram,
        diagram_y::PMInteractionDiagram,
        Pu::Real, Mux::Real, Muy::Real;
        method::Symbol = :contour,
        α::Real = 1.5
    ) -> NamedTuple

Check biaxial bending capacity using P-M interaction diagrams for both axes.

# Arguments
- `diagram_x`: P-M diagram for x-axis bending
- `diagram_y`: P-M diagram for y-axis bending  
- `Pu`: Factored axial load (kip), positive = compression
- `Mux`: Factored moment about x-axis (kip-ft)
- `Muy`: Factored moment about y-axis (kip-ft)
- `method`: `:contour` (Bresler Load Contour) or `:reciprocal` (Bresler Reciprocal)
- `α`: Load contour exponent (default 1.5, used only for :contour)

# Returns
NamedTuple with:
- `adequate`: Bool - true if demand is within capacity
- `utilization`: Float64 - demand/capacity ratio
- `φMnx_at_Pu`: Factored x-moment capacity at given Pu
- `φMny_at_Pu`: Factored y-moment capacity at given Pu
- `method`: Method used for check

# Reference
StructurePoint: "Manual Design Procedure for Columns and Walls with Biaxial Bending"
"""
function check_biaxial_capacity(
    diagram_x::PMInteractionDiagram,
    diagram_y::PMInteractionDiagram,
    Pu::Real, Mux::Real, Muy::Real;
    method::Symbol = :contour,
    α::Real = 1.5
)
    # Get capacities at the given axial load from both diagrams
    φMnx = capacity_at_axial(diagram_x, Pu)
    φMny = capacity_at_axial(diagram_y, Pu)
    
    if method == :contour
        # Bresler Load Contour Method
        util = bresler_load_contour(Mux, Muy, φMnx, φMny; α=α)
        adequate = util ≤ 1.0
    elseif method == :reciprocal
        # Bresler Reciprocal Load Method
        # Need P capacities at the eccentricities
        ex = abs(Muy) / max(abs(Pu), 1e-6)  # Eccentricity from Muy
        ey = abs(Mux) / max(abs(Pu), 1e-6)  # Eccentricity from Mux
        
        # Get Pnx at eccentricity ex (moment Muy only)
        φPnx = capacity_at_moment(diagram_y, Muy)
        # Get Pny at eccentricity ey (moment Mux only)
        φPny = capacity_at_moment(diagram_x, Mux)
        # Get P0
        P0_x = get_control_point(diagram_x, :pure_compression).φPn
        P0_y = get_control_point(diagram_y, :pure_compression).φPn
        φP0 = min(P0_x, P0_y)
        
        util = check_bresler_reciprocal(Pu, φPnx, φPny, φP0)
        adequate = util ≤ 1.0
    else
        error("Unknown biaxial method: $method. Use :contour or :reciprocal")
    end
    
    return (
        adequate = adequate,
        utilization = util,
        φMnx_at_Pu = φMnx,
        φMny_at_Pu = φMny,
        method = method
    )
end

"""
    check_biaxial_simple(
        section::RCColumnSection, mat,
        Pu::Real, Mux::Real, Muy::Real;
        α::Real = 1.5
    ) -> NamedTuple

Simplified biaxial check that generates diagrams internally.
Assumes square column with same capacity in both directions.

# Arguments
- `section`: RC column section (assumed square or symmetric)
- `mat`: Material properties
- `Pu`: Factored axial load (kip)
- `Mux`: Factored moment about x-axis (kip-ft)
- `Muy`: Factored moment about y-axis (kip-ft)
- `α`: Load contour exponent (default 1.5)

# Returns
NamedTuple with utilization and capacity info

# Note
For rectangular columns with different x and y capacities,
use `check_biaxial_capacity` with separate diagrams.
"""
function check_biaxial_simple(
    section::RCColumnSection, 
    mat,
    Pu::Real, Mux::Real, Muy::Real;
    α::Real = 1.5
)
    # Generate P-M diagram (assumes same for both axes if square)
    diagram = generate_PM_diagram(section, mat; n_intermediate=10)
    
    # Get capacity at the given axial load
    φMn = capacity_at_axial(diagram, Pu)
    
    # Bresler Load Contour
    util = bresler_load_contour(Mux, Muy, φMn, φMn; α=α)
    
    return (
        adequate = util ≤ 1.0,
        utilization = util,
        φMn_at_Pu = φMn,
        method = :contour_symmetric
    )
end

"""
    check_biaxial_rectangular(
        section::RCColumnSection, mat,
        Pu::Real, Mux::Real, Muy::Real;
        method::Symbol = :contour,
        α::Real = 1.5
    ) -> NamedTuple

Full biaxial check for RECTANGULAR columns with separate x/y capacities.

This generates P-M diagrams for both axes and uses the appropriate capacity
in each direction. Required for non-square columns where b ≠ h.

# Arguments
- `section`: RC column section
- `mat`: Material properties
- `Pu`: Factored axial load (kip), positive = compression
- `Mux`: Factored moment about x-axis (kip-ft) - bends about h
- `Muy`: Factored moment about y-axis (kip-ft) - bends about b
- `method`: `:contour` (Bresler Load Contour) or `:reciprocal`
- `α`: Load contour exponent (default 1.5)

# Returns
NamedTuple with:
- `adequate`: Bool - true if demand is within capacity
- `utilization`: Float64 - demand/capacity ratio
- `φMnx_at_Pu`: Factored x-moment capacity at given Pu
- `φMny_at_Pu`: Factored y-moment capacity at given Pu
- `method`: Method used

# Reference
StructurePoint: "Biaxial Bending Interaction Diagrams for Rectangular 
Reinforced Concrete Column Design (ACI 318-11)"
"""
function check_biaxial_rectangular(
    section::RCColumnSection, 
    mat,
    Pu::Real, Mux::Real, Muy::Real;
    method::Symbol = :contour,
    α::Real = 1.5
)
    # Generate diagrams for both axes
    diagrams = generate_PM_diagrams_biaxial(section, mat; n_intermediate=15)
    
    # Use the full check with separate diagrams
    return check_biaxial_capacity(diagrams.x, diagrams.y, Pu, Mux, Muy; method=method, α=α)
end

"""
    check_biaxial_auto(
        section::RCColumnSection, mat,
        Pu::Real, Mux::Real, Muy::Real;
        method::Symbol = :contour,
        α::Real = 1.5,
        square_tolerance::Real = 0.01
    ) -> NamedTuple

Automatic biaxial check that detects square vs rectangular sections.

# Arguments
- `section`: RC column section
- `mat`: Material properties
- `Pu`: Factored axial load (kip)
- `Mux, Muy`: Factored moments (kip-ft)
- `method`: `:contour` or `:reciprocal`
- `α`: Load contour exponent (default 1.5)
- `square_tolerance`: Tolerance for b/h ratio to consider square (default 0.01)

# Returns
NamedTuple with biaxial check results

# Notes
- If b ≈ h (within tolerance): uses symmetric check (faster)
- If b ≠ h: uses full rectangular check with separate diagrams
"""
function check_biaxial_auto(
    section::RCColumnSection, 
    mat,
    Pu::Real, Mux::Real, Muy::Real;
    method::Symbol = :contour,
    α::Real = 1.5,
    square_tolerance::Real = 0.01
)
    # Check if section is approximately square
    b = to_inches(section.b)
    h = to_inches(section.h)
    aspect_ratio = b / h
    
    is_square = abs(aspect_ratio - 1.0) ≤ square_tolerance
    
    if is_square
        # Use symmetric check (faster)
        result = check_biaxial_simple(section, mat, Pu, Mux, Muy; α=α)
        return (
            adequate = result.adequate,
            utilization = result.utilization,
            φMnx_at_Pu = result.φMn_at_Pu,
            φMny_at_Pu = result.φMn_at_Pu,
            method = result.method,
            is_square = true
        )
    else
        # Use full rectangular check
        result = check_biaxial_rectangular(section, mat, Pu, Mux, Muy; method=method, α=α)
        return (
            adequate = result.adequate,
            utilization = result.utilization,
            φMnx_at_Pu = result.φMnx_at_Pu,
            φMny_at_Pu = result.φMny_at_Pu,
            method = result.method,
            is_square = false
        )
    end
end