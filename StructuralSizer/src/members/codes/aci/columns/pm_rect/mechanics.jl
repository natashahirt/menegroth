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

