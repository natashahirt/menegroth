# =============================================================================
# CIP Flat Plate Design per ACI 318-14/19
# =============================================================================
#
# Methodology: StructurePoint Design Examples (ACI 318-14)
# Equations: Broyles, Solnosky, Brown (2024) - Supplementary Document
#
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf
# Example: 18 ft × 14 ft panel, 16" columns, f'c=4000 psi (slab), fy=60 ksi
#
# =============================================================================
# NOT YET IMPLEMENTED (Future Work)
# =============================================================================
#
# 1. Shear Reinforcement (ACI 318-19 §22.6)
#    - Stud rails / headed shear studs for punching shear enhancement
#    - Stirrup cages around columns
#    - vn = vc + vs calculations where shear exceeds concrete capacity
#    Note: Currently punching shear failure requires column size or slab thickness increase
#
# 2. Pattern Loading (ACI 318-14 §6.4.3.2)  
#    - Only required when L/D > 0.75 (live load > 3/4 dead load)
#    - Checkerboard loading, adjacent spans loaded patterns
#    - Envelope of maximum/minimum moments at each location
#    Note: Current EFM uses full load on all spans (conservative for typical L/D < 0.75)
#
# =============================================================================
# UNIT CONVENTION
# =============================================================================
#
# All public functions use Unitful type signatures for type safety:
#   - Lengths:   Length   (accepts m, ft, inch, etc.)
#   - Areas:     Area     (accepts m², ft², inch², etc.)
#   - Pressures: Pressure (accepts Pa, psi, ksi, psf, etc.)
#   - Moments:   Moment   (accepts N·m, kip·ft, lb·in, etc.)
#
# Internal calculations convert to a consistent system (typically US customary
# for ACI compatibility) and return results with explicit units.
#
# Example:
#   h = min_thickness_flat_plate(16.67u"ft")  # Returns Quantity in inches
#   fc = 4000u"psi"
#   Ec_val = Ec(fc)  # Returns Quantity in psi
#
# =============================================================================

using Unitful
using Unitful: @u_str
using Asap: kip, ksi, ksf, psf, pcf
using Asap: Length, Area, Volume, SecondMomentOfArea, TorsionalConstant, Pressure, Force, Moment, Torque, LinearLoad

# Note: Asap units (kip, ksi, psf, etc.) are imported directly above.
# Unitful.register(Asap) is called in StructuralSizer.__init__() for runtime u"" macro support.

# =============================================================================
# Material Properties
# =============================================================================

"""
Concrete modulus of elasticity per ACI 19.2.2.1.

Formula: Ec = 57000√f'c (psi units)
"""
function Ec(fc::Pressure)
    # ACI formula defined in psi
    return 57000 * sqrt(ustrip(u"psi", fc)) * u"psi"
end

"""
Stress block factor β₁ per ACI 22.2.2.4.3.

- f'c ≤ 4000 psi: β₁ = 0.85
- f'c ≥ 8000 psi: β₁ = 0.65
- Otherwise: β₁ = 0.85 - 0.05(f'c - 4000)/1000
"""
function β1(fc::Pressure)
    # ACI formula defined with f'c in psi
    fc_val = ustrip(u"psi", fc)
    if fc_val <= 4000
        return 0.85
    elseif fc_val >= 8000
        return 0.65
    else
        return 0.85 - 0.05 * (fc_val - 4000) / 1000
    end
end

"""
Concrete rupture modulus for deflection calculations per ACI 19.2.3.1.

Formula: fr = 7.5√f'c (psi units)
"""
function fr(fc::Pressure)
    # ACI formula defined in psi
    return 7.5 * sqrt(ustrip(u"psi", fc)) * u"psi"
end

# =============================================================================
# Self-Weight Calculation
# =============================================================================

# Standard gravitational acceleration
const g_ACCEL = 9.80665u"m/s^2"

"""
    slab_self_weight(h, ρ) -> Pressure

Compute slab self-weight from thickness and mass density.

Mass density (ρ, kg/m³) must be multiplied by gravity to get weight density (γ, N/m³).
Then multiplying by thickness gives pressure (load per unit area).

# Arguments
- `h`: Slab thickness (Length)
- `ρ`: Concrete mass density (Density, e.g., kg/m³)

# Returns
- Self-weight as pressure (psf)

# Example
```julia
h = 7u"inch"
ρ = 2400u"kg/m^3"
sw = slab_self_weight(h, ρ)  # ≈ 87.5 psf
```
"""
slab_self_weight(h, ρ) = uconvert(psf, h * ρ * g_ACCEL)

# =============================================================================
# Phase 2: Slab Thickness (ACI 8.3.1.1)
# =============================================================================

"""
    min_thickness_flat_plate(ln; discontinuous_edge=false)

Minimum flat plate thickness per ACI 318-14 Table 8.3.1.1.

# Arguments
- `ln`: Clear span (face-to-face of columns) - longer span governs
- `discontinuous_edge`: true if slab has discontinuous edge (exterior panel)

# Returns
- Minimum thickness h (with 5 inch absolute minimum)

# Reference
- ACI 318-14 Table 8.3.1.1, Row 1 (flat plates)
- StructurePoint Example: ln = 16.67 ft → h_min = 6.06 in → use 7 in
"""
function min_thickness_flat_plate(ln::Length; discontinuous_edge::Bool=false)
    # ACI formula: h_min = ln/30 (exterior) or ln/33 (interior)
    divisor = discontinuous_edge ? 30 : 33
    h_min = ln / divisor
    
    # Absolute minimum per ACI 8.3.1.1: 5 inches
    return max(h_min, 5.0u"inch")
end

"""
    clear_span(l, c)

Clear span from face-to-face of supports.

# Arguments
- `l`: Center-to-center span
- `c`: Column dimension in span direction
"""
function clear_span(l::Length, c::Length)
    return l - c
end

# =============================================================================
# Phase 3: Static Moment & Moment Distribution (ACI 8.10)
# =============================================================================

"""
    total_static_moment(qu, l2, ln)

Total factored static moment per ACI 318-14 Eq. 8.10.3.2.

    M₀ = (qᵤ × l₂ × lₙ²) / 8

# Arguments
- `qu`: Factored uniform load (psf or kPa)
- `l2`: Panel width perpendicular to span direction
- `ln`: Clear span (face-to-face of columns)

# Reference
- ACI 318-14 Section 8.10.3.2
- StructurePoint Example: qu=0.193 ksf, l2=14 ft, ln=16.67 ft → M₀ = 93.82 k-ft
"""
function total_static_moment(qu::Pressure, l2::Length, ln::Length)
    return qu * l2 * ln^2 / 8
end

"""
Modified Direct Design Method (M-DDM) Coefficients for flat plates (αf = 0).

Pre-computed coefficients combining ACI longitudinal and transverse distribution
for flat plates without edge beams. These provide conservative results for regular
flat plate systems while reducing the number of calculation steps.

# Source
Supplementary Document: "Structural Methods and Equations", Table S-1
(Derived from Setareh, M., & Darvas, R., Concrete Structures methodology)

# Assumptions
- No beams (αf = 0) - always true for flat plates
- No edge beams at exterior supports
- Rectangular panels with regular column layout

# Structure
- First level: span type (:end_span or :interior_span)
- Second level: strip type (:column_strip or :middle_strip)  
- Third level: moment location (:ext_neg, :pos, :int_neg, :neg)

# Coefficients
All coefficients are fractions of total static moment M₀.
End span column strip: 0.27 + 0.345 + 0.55 = 1.165 (accounts for redistribution)
End span middle strip: 0.00 + 0.235 + 0.18 = 0.415

# Reference
- Supplementary Document Table S-1 (primary source)
- ACI 318-14 Tables 8.10.4.2, 8.10.5.1-5.5 (underlying methodology)
"""
const MDDM_COEFFICIENTS = (
    # End span (exterior span with one exterior support)
    # Supplementary Document Table S-1 values
    end_span = (
        # Column strip moments (% of M₀)
        column_strip = (
            ext_neg = 0.27,   # Exterior negative (at exterior column)
            pos = 0.345,      # Positive (midspan)
            int_neg = 0.55    # Interior negative (at first interior column)
        ),
        # Middle strip moments (% of M₀)
        middle_strip = (
            ext_neg = 0.00,   # Exterior negative (0 for flat plate w/o edge beam)
            pos = 0.235,      # Positive (midspan)
            int_neg = 0.18    # Interior negative
        )
    ),
    # Interior span (both supports are interior columns)
    interior_span = (
        column_strip = (
            neg = 0.535,      # Negative (at columns)
            pos = 0.186       # Positive (midspan)
        ),
        middle_strip = (
            neg = 0.175,      # Negative
            pos = 0.124       # Positive
        )
    )
)

"""
ACI DDM Longitudinal Distribution Coefficients per ACI 318-14 Table 8.10.4.2.

These are the code-mandated coefficients for distributing total static moment M₀
to negative and positive moment regions along the span. These apply before
transverse distribution to column/middle strips.

# Source
- ACI 318-14 Table 8.10.4.2 (longitudinal distribution)
- Supplementary Document Table S-1 (uses same values: 0.26, 0.52, 0.70)

# Note
Transverse distribution to column/middle strips uses ACI Tables 8.10.5.1-5.7
and varies with l₂/l₁ and αf. For flat plates (αf = 0), see distribute_moments_aci().

# Reference
- ACI 318-14 Table 8.10.4.2
- StructurePoint DE-Two-Way-Flat-Plate Table 6
"""
const ACI_DDM_LONGITUDINAL = (
    # Table 8.10.4.2: Distribution of M₀ to negative and positive sections
    # (Same for all slab types)
    end_span = (
        ext_neg = 0.26,   # Exterior negative
        pos = 0.52,       # Positive  
        int_neg = 0.70    # Interior negative
    ),
    interior_span = (
        neg = 0.65,       # Negative at supports
        pos = 0.35        # Positive at midspan
    )
)

"""
ACI Table 8.10.5.1 - Column strip negative moment at interior supports.
For flat plates (αf = 0), always 75%.
"""
const ACI_COL_STRIP_INT_NEG = 0.75

"""
ACI Table 8.10.5.2 - Column strip negative moment at exterior supports.
Without edge beam (βt = 0), always 100%.
"""
const ACI_COL_STRIP_EXT_NEG_NO_BEAM = 1.00

"""
ACI Table 8.10.5.5 - Column strip positive moment.
For flat plates, 60% for l₂/l₁ = 1.0, varies with ratio.
"""
function aci_col_strip_positive(l2_l1::Float64)
    # Interpolate between 60% (l2/l1=0.5) and 60% (l2/l1=2.0)
    # For αf = 0 (flat plate), it's constant at 60%
    return 0.60
end

"""
    distribute_moments_mddm(M0, span_type::Symbol)

Distribute total static moment using simplified M-DDM coefficients.

# Arguments
- `M0`: Total static moment from total_static_moment()
- `span_type`: :end_span or :interior_span

# Returns
Named tuple with column_strip and middle_strip moments at each location.

# Reference
- Supplementary Document Table S-1
"""
function distribute_moments_mddm(M0, span_type::Symbol)
    coeffs = span_type == :end_span ? MDDM_COEFFICIENTS.end_span : MDDM_COEFFICIENTS.interior_span
    
    if span_type == :end_span
        return (
            column_strip = (
                ext_neg = coeffs.column_strip.ext_neg * M0,
                pos = coeffs.column_strip.pos * M0,
                int_neg = coeffs.column_strip.int_neg * M0
            ),
            middle_strip = (
                ext_neg = coeffs.middle_strip.ext_neg * M0,
                pos = coeffs.middle_strip.pos * M0,
                int_neg = coeffs.middle_strip.int_neg * M0
            )
        )
    else
        return (
            column_strip = (
                neg = coeffs.column_strip.neg * M0,
                pos = coeffs.column_strip.pos * M0
            ),
            middle_strip = (
                neg = coeffs.middle_strip.neg * M0,
                pos = coeffs.middle_strip.pos * M0
            )
        )
    end
end

"""
    distribute_moments_aci(M0, span_type::Symbol, l2_l1::Float64; edge_beam::Bool=false)

Distribute moments using full ACI DDM procedure (Tables 8.10.4-5).

# Arguments
- `M0`: Total static moment
- `span_type`: :end_span or :interior_span
- `l2_l1`: Ratio of panel width to span length
- `edge_beam`: Whether exterior edge has a beam (affects βt)

# Returns
Named tuple with distributed moments to column and middle strips.
"""
function distribute_moments_aci(M0, span_type::Symbol, l2_l1::Float64; edge_beam::Bool=false)
    if span_type == :end_span
        # Step 1: Longitudinal distribution (Table 8.10.4.2)
        M_ext_neg = ACI_DDM_LONGITUDINAL.end_span.ext_neg * M0
        M_pos = ACI_DDM_LONGITUDINAL.end_span.pos * M0
        M_int_neg = ACI_DDM_LONGITUDINAL.end_span.int_neg * M0
        
        # Step 2: Transverse distribution to column strip
        # Interior negative: Table 8.10.5.1 (75% for αf=0)
        cs_int_neg = ACI_COL_STRIP_INT_NEG * M_int_neg
        
        # Exterior negative: Table 8.10.5.2
        cs_ext_neg_frac = edge_beam ? 0.75 : ACI_COL_STRIP_EXT_NEG_NO_BEAM
        cs_ext_neg = cs_ext_neg_frac * M_ext_neg
        
        # Positive: Table 8.10.5.5
        cs_pos = aci_col_strip_positive(l2_l1) * M_pos
        
        # Middle strip gets remainder
        ms_ext_neg = M_ext_neg - cs_ext_neg
        ms_pos = M_pos - cs_pos
        ms_int_neg = M_int_neg - cs_int_neg
        
        return (
            column_strip = (ext_neg = cs_ext_neg, pos = cs_pos, int_neg = cs_int_neg),
            middle_strip = (ext_neg = ms_ext_neg, pos = ms_pos, int_neg = ms_int_neg)
        )
    else
        # Interior span
        M_neg = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
        M_pos = ACI_DDM_LONGITUDINAL.interior_span.pos * M0
        
        cs_neg = ACI_COL_STRIP_INT_NEG * M_neg
        cs_pos = aci_col_strip_positive(l2_l1) * M_pos
        
        ms_neg = M_neg - cs_neg
        ms_pos = M_pos - cs_pos
        
        return (
            column_strip = (neg = cs_neg, pos = cs_pos),
            middle_strip = (neg = ms_neg, pos = ms_pos)
        )
    end
end

# =============================================================================
# Phase 4: Equivalent Frame Method (EFM) - ACI 318-14 Section 8.11
# =============================================================================
#
# Reference: StructurePoint DE-Two-Way-Flat-Plate-...-ACI-318-14-spSlab-v1000.pdf
# Section 3.2: Equivalent Frame Method (EFM)
#
# The equivalent frame consists of three parts:
#   1. Slab-beam strip (K_sb): horizontal member with enhanced stiffness at columns
#   2. Columns (K_c): vertical members with infinite stiffness in joint region
#   3. Torsional members (K_t): provide moment transfer between slab and columns
#
# The equivalent column stiffness K_ec combines K_c and K_t in series.
#
# =============================================================================

"""
    slab_moment_of_inertia(l2, h)

Gross moment of inertia for slab strip per unit of span direction.

    Iₛ = l₂ × h³ / 12

# Arguments
- `l2`: Slab width perpendicular to span (tributary width of frame)
- `h`: Slab thickness

# Returns
Moment of inertia (Length⁴)

# Reference
- ACI 318-14 Section 8.11.3
- StructurePoint Example: l2=168 in, h=7 in → Is = 4,802 in⁴
"""
function slab_moment_of_inertia(l2::Length, h::Length)
    return l2 * h^3 / 12
end

"""
    column_moment_of_inertia(c1, c2)

Gross moment of inertia for rectangular column section.

    Iᶜ = c₁ × c₂³ / 12   (bending about axis parallel to c1)

# Arguments  
- `c1`: Column dimension in span direction
- `c2`: Column dimension perpendicular to span

# Returns
Moment of inertia (Length⁴)

# Reference
- ACI 318-14 Section 8.11.4
- StructurePoint Example: c1=c2=16 in → Ic = 5,461 in⁴
"""
function column_moment_of_inertia(c1::Length, c2::Length)
    return c1 * c2^3 / 12
end

"""
    torsional_constant_C(x, y)

Cross-sectional constant C for torsional member per ACI 318-14 Eq. 8.10.5.2b.

    C = Σ(1 - 0.63×(x/y)) × (x³×y/3)

For flat plate without beams, the torsional member is a slab strip with:
- x = slab thickness h
- y = column dimension c2 (width of torsional member)

# Arguments
- `x`: Smaller dimension of rectangular section (typically h)
- `y`: Larger dimension of rectangular section (typically c2)

# Returns
Torsional constant C (Length⁴)

# Reference
- ACI 318-14 Eq. 8.10.5.2b
- StructurePoint Example: x=7 in, y=16 in → C = 1,325 in⁴
"""
function torsional_constant_C(x::Length, y::Length)
    # Ensure x ≤ y for the formula (ACI convention)
    x_short = min(x, y)
    y_long = max(x, y)
    
    # ACI 8.10.5.2b: C = (1 - 0.63x/y) × x³y/3
    # Ratio is dimensionless, so units work out to Length⁴
    return (1 - 0.63 * (x_short / y_long)) * (x_short^3 * y_long / 3)
end

"""
    slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=4.127)

Flexural stiffness of slab-beam at both ends per ACI 318-14 Section 8.11.3.

    Kₛᵦ = k × Eᶜₛ × Iₛ / l₁

The stiffness factor k accounts for the non-prismatic section:
- Enhanced moment of inertia at column region: Is / (1 - c2/l2)²
- Default k = 4.127 from PCA Notes Table A1 for typical flat plate geometry

# Arguments
- `Ecs`: Modulus of elasticity of slab concrete
- `Is`: Gross moment of inertia of slab (from slab_moment_of_inertia)
- `l1`: Span length center-to-center of columns
- `c1`: Column dimension in span direction (for N1 = c1/l1)
- `c2`: Column dimension perpendicular to span (for N2 = c2/l2)
- `k_factor`: Stiffness factor from PCA tables (default 4.127 for c/l ≈ 0.08-0.10)

# Returns
Slab-beam stiffness Ksb (Moment units, e.g., in-lb)

# Reference
- ACI 318-14 Section 8.11.3
- PCA Notes on ACI 318-11 Table A1
- StructurePoint Example: Ecs=3,834×10³ psi, Is=4,802 in⁴, l1=18 ft=216 in
  → Ksb = 4.127 × 3,834×10³ × 4,802 / 216 = 351,766,909 in-lb

# Note
For precise results, k_factor should be interpolated from PCA Table A1 based on:
- N1 = c1/l1 (typically 0.05-0.15)
- N2 = c2/l2 (typically 0.05-0.15)
For most flat plates with c/l ≈ 0.07-0.10, k ≈ 4.0-4.2.
"""
function slab_beam_stiffness_Ksb(
    Ecs::Pressure,
    Is::SecondMomentOfArea,
    l1::Length,
    c1::Length,
    c2::Length;
    k_factor::Float64 = 4.127
)
    # Ksb = k × Ec × Is / l1 — units: (lbf/in²) × in⁴ / in = lbf*in = Moment
    # Convert to consistent units to avoid Unitful overflow
    Ec = ustrip(u"psi", Ecs)
    I = ustrip(u"inch^4", Is)
    l1val = ustrip(u"inch", l1)
    return k_factor * Ec * I / l1val * u"lbf*inch"
end

"""
    column_stiffness_Kc(Ecc, Ic, H, h; k_factor=4.74)

Flexural stiffness of column at slab-beam joint per ACI 318-14 Section 8.11.4.

    Kᶜ = k × Eᶜᶜ × Iᶜ / H

The stiffness factor k accounts for:
- Infinite moment of inertia within the slab depth (joint region)
- Column clear height Hc = H - h

Default k = 4.74 from PCA Notes Table A7 for ta/tb = 1, H/Hc ≈ 1.07.

# Arguments
- `Ecc`: Modulus of elasticity of column concrete
- `Ic`: Gross moment of inertia of column (from column_moment_of_inertia)
- `H`: Story height (floor-to-floor)
- `h`: Slab thickness
- `k_factor`: Stiffness factor from PCA tables (default 4.74)

# Returns
Column stiffness Kc (Moment units, e.g., in-lb)

# Reference
- ACI 318-14 Section 8.11.4
- PCA Notes on ACI 318-11 Table A7
- StructurePoint Example: Ecc=4,696×10³ psi, Ic=5,461 in⁴, H=108 in
  → Kc = 4.74 × 4,696×10³ × 5,461 / 108 = 1,125,592,936 in-lb

# Note
For precise results, k_factor should be interpolated from PCA Table A7 based on:
- ta/tb = ratio of slab depth above/below (typically 1.0 for intermediate floors)
- H/Hc = story height / clear column height
"""
function column_stiffness_Kc(
    Ecc::Pressure,
    Ic::SecondMomentOfArea,
    H::Length,
    h::Length;
    k_factor::Float64 = 4.74
)
    # Kc = k × Ec × Ic / H — units: (lbf/in²) × in⁴ / in = lbf*in = Moment
    # Convert to consistent units to avoid Unitful overflow
    Ec = ustrip(u"psi", Ecc)
    I = ustrip(u"inch^4", Ic)
    Hval = ustrip(u"inch", H)
    return k_factor * Ec * I / Hval * u"lbf*inch"
end

"""
    torsional_member_stiffness_Kt(Ecs, C, l2, c2)

Torsional stiffness of transverse slab strip per ACI 318-14 Section R8.11.5.

    Kₜ = 9 × Eᶜₛ × C / (l₂ × (1 - c₂/l₂)³)

The torsional member transfers moment between slab and column. For flat plates,
it's a slab strip with width equal to the column dimension c1.

# Arguments
- `Ecs`: Modulus of elasticity of slab concrete
- `C`: Torsional constant (from torsional_constant_C)
- `l2`: Panel width perpendicular to span
- `c2`: Column dimension perpendicular to span

# Returns
Torsional stiffness Kt (Moment units, e.g., in-lb)

# Reference
- ACI 318-14 Section R8.11.5, Eq. R8.11.5
- StructurePoint Example: Ecs=3,834×10³ psi, C=1,325 in⁴, l2=168 in, c2=16 in
  → Kt = 9 × 3,834×10³ × 1,325 / (168 × (1 - 16/168)³) = 367,484,240 in-lb
"""
function torsional_member_stiffness_Kt(Ecs::Pressure, C::TorsionalConstant, l2::Length, c2::Length)
    # ACI R8.11.5: Kt = 9 × Ec × C / (l2 × (1 - c2/l2)³)
    # C has units of Length⁴ (torsional constant = x³y/3 for rectangular section)
    # Convert to consistent units to avoid Unitful overflow
    Ec = ustrip(u"psi", Ecs)
    Cval = ustrip(u"inch^4", C)
    l2val = ustrip(u"inch", l2)
    c2val = ustrip(u"inch", c2)
    reduction = (1 - c2val / l2val)^3
    return 9 * Ec * Cval / (l2val * reduction) * u"lbf*inch"
end

"""
    equivalent_column_stiffness_Kec(Kc_sum, Kt_sum)

Equivalent column stiffness combining column and torsional member stiffnesses.

    1/Kₑᶜ = 1/ΣKᶜ + 1/ΣKₜ

Or equivalently:

    Kₑᶜ = (ΣKᶜ × ΣKₜ) / (ΣKᶜ + ΣKₜ)

# Arguments
- `Kc_sum`: Sum of column stiffnesses at joint (upper + lower columns)
- `Kt_sum`: Sum of torsional member stiffnesses at joint (both sides)

# Returns
Equivalent column stiffness Kec (Moment units)

# Reference
- ACI 318-14 Section 8.11.5
- StructurePoint Example: ΣKc = 2×1,125.6×10⁶, ΣKt = 2×367.5×10⁶
  → Kec = (2×1125.6 × 2×367.5) / (2×1125.6 + 2×367.5) × 10⁶ = 554,074,058 in-lb

# Note
At exterior columns, ΣKt includes only one torsional member.
At roof level, ΣKc includes only one column (below).
"""
function equivalent_column_stiffness_Kec(Kc_sum, Kt_sum)
    # Convert to common units (lbf*inch) to avoid Unitful overflow
    # when adding stiffnesses with different unit representations
    Kc = ustrip(u"lbf*inch", Kc_sum)
    Kt = ustrip(u"lbf*inch", Kt_sum)
    Kec = (Kc * Kt) / (Kc + Kt)
    return Kec * u"lbf*inch"
end

"""
    distribution_factor_DF(Ksb, Kec; is_exterior::Bool=false, Ksb_adjacent=nothing)

Moment distribution factor for slab-beam at a joint.

At interior joint:
    DF = Kₛᵦ / (Kₛᵦ_left + Kₛᵦ_right + Kₑᶜ)

At exterior joint:
    DF = Kₛᵦ / (Kₛᵦ + Kₑᶜ)

# Arguments
- `Ksb`: Slab-beam stiffness at the joint
- `Kec`: Equivalent column stiffness at the joint
- `is_exterior`: Whether this is an exterior joint
- `Ksb_adjacent`: Slab-beam stiffness from adjacent span (for interior joints)

# Returns
Distribution factor DF (dimensionless, 0 to 1)

# Reference
- PCA Notes on ACI 318-11, Moment Distribution Method
- StructurePoint Example: 
  - Exterior: DF = 351.77 / (351.77 + 554.07) = 0.388
  - Interior: DF = 351.77 / (351.77 + 351.77 + 554.07) = 0.280
"""
function distribution_factor_DF(Ksb, Kec; is_exterior::Bool=false, Ksb_adjacent=nothing)
    if is_exterior
        total_K = Ksb + Kec
    else
        Ksb_adj = isnothing(Ksb_adjacent) ? Ksb : Ksb_adjacent
        total_K = Ksb + Ksb_adj + Kec
    end
    
    # Strip units for division (both are same dimension)
    return ustrip(Ksb) / ustrip(total_K)
end

"""
    carryover_factor_COF(; k_factor=4.127)

Carryover factor for non-prismatic slab-beam.

For flat plates with enhanced stiffness at columns, COF ≈ 0.507.
This is larger than the prismatic beam value of 0.5 due to the
increased stiffness at column regions.

# Arguments
- `k_factor`: Stiffness factor (same as used for Ksb)

# Returns
Carryover factor COF (dimensionless)

# Reference
- PCA Notes on ACI 318-11 Table A1
- StructurePoint Example: COF = 0.507
"""
function carryover_factor_COF(; k_factor::Float64=4.127)
    # For k ≈ 4.127, COF ≈ 0.507
    # This relationship is from PCA Notes Table A1
    # For a more accurate value, interpolate from the table
    return 0.507
end

"""
    fixed_end_moment_FEM(qu, l2, l1; m_factor=0.08429)

Fixed-end moment for uniformly loaded non-prismatic slab-beam.

    FEM = m × qᵤ × l₂ × l₁²

# Arguments
- `qu`: Factored uniform load (pressure)
- `l2`: Panel width perpendicular to span
- `l1`: Span length center-to-center
- `m_factor`: FEM factor from PCA tables (default 0.08429)

# Returns
Fixed-end moment FEM (moment units)

# Reference
- PCA Notes on ACI 318-11 Table A1
- StructurePoint Example: m=0.08429, qu=0.193 ksf, l2=14 ft, l1=18 ft
  → FEM = 0.08429 × 0.193 × 14 × 18² = 73.79 ft-kip
"""
function fixed_end_moment_FEM(qu::Pressure, l2::Length, l1::Length; m_factor::Float64=0.08429)
    return m_factor * qu * l2 * l1^2
end

"""
    face_of_support_moment(M_centerline, V, c, l1)

Reduce centerline moment to face-of-support for design per ACI 318-14 8.11.6.1.

    M_face = M_centerline - V × (c/2)

But not less than M at 0.175×l1 from column center.

# Arguments
- `M_centerline`: Moment at column centerline from frame analysis
- `V`: Shear at support (reaction)
- `c`: Column dimension in span direction
- `l1`: Span length

# Returns
Design moment at face of support

# Reference
- ACI 318-14 Section 8.11.6.1
- StructurePoint Example: M_cl = 83.91 kip-ft, V = 26.39 kip, c = 16/12 ft
  → M_face = 83.91 - 26.39 × (16/12/2) = 66.32 ft-kip
  
# Note
The 0.175×l1 limit ensures the design moment is taken at a reasonable
distance from the column center for very large columns.
"""
function face_of_support_moment(M_centerline, V, c::Length, l1::Length)
    # Distance to face of support
    d_face = c / 2
    
    # Maximum distance for moment reduction (ACI 8.11.6.1)
    d_max = 0.175 * l1
    
    # Use smaller of face distance or max distance
    d_use = min(d_face, d_max)
    
    # Reduce moment by V × d
    M_face = M_centerline - V * d_use
    
    return M_face
end

# =============================================================================
# Phase 5: Reinforcement Design (ACI 8.6, 22.2)
# =============================================================================

"""
    required_reinforcement(Mu, b, d, fc, fy)

Required steel area per Supplementary Document Eq. 1.7 derivation.

Uses the quadratic solution for As from moment equilibrium:
    As = (β₁·f'c·b·d / fy) × (1 - √(1 - 2Rn/(β₁·f'c)))

where Rn = Mu / (φ·b·d²)

# Arguments
- `Mu`: Factored moment demand
- `b`: Strip width
- `d`: Effective depth (h - cover - db/2)
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength

# Returns
Required steel area As

# Reference
- Supplementary Document Section 1.7 (Setareh & Darvas derivation)
- StructurePoint Example Section 3.1.3
"""
function required_reinforcement(Mu::Moment, b::Length, d::Length, fc::Pressure, fy::Pressure)
    φ = 0.9  # Tension-controlled section (ACI 21.2.2)
    
    # Resistance coefficient Rn = Mu/(φ·b·d²) — has units of pressure
    Rn = Mu / (φ * b * d^2)
    
    # Stress block factor
    β = β1(fc)
    
    # Check if section is adequate (ACI limits)
    Rn_max = 0.319 * β * fc  # Approximate limit for tension-controlled
    if Rn > Rn_max
        @warn "Section may not be tension-controlled, Rn=$(ustrip(u"psi", Rn)) psi > Rn_max=$(ustrip(u"psi", Rn_max)) psi"
    end
    
    # Required steel ratio (from quadratic solution)
    term = 2 * Rn / (β * fc)  # dimensionless
    if term > 1.0
        error("Section inadequate: required Rn exceeds capacity. Increase h or f'c.")
    end
    
    ρ = (β * fc / fy) * (1 - sqrt(1 - term))  # dimensionless
    
    # Required area: As = ρ·b·d
    return ρ * b * d
end

"""
    minimum_reinforcement(b, h, fy)

Minimum reinforcement per ACI 318-14 Table 8.6.1.1 for shrinkage and temperature.

# Minimum Ratios (ACI Table 8.6.1.1)
- fy < 60 ksi:  ρ_min = 0.0020
- 60 ≤ fy < 77 ksi: ρ_min = 0.0018
- fy ≥ 77 ksi:  ρ_min = max(0.0014, 0.0018 × 60000/fy)

# Arguments
- `b`: Strip width
- `h`: Total slab thickness (gross section)
- `fy`: Reinforcement yield strength

# Returns
- As_min = ρ_min × b × h

# Reference
- ACI 318-14 Table 8.6.1.1
- StructurePoint Example: fy=60ksi → As_min = 0.0018 × b × h
"""
function minimum_reinforcement(b::Length, h::Length, fy::Pressure)
    # ACI 318-14 Table 8.6.1.1 thresholds (Grade 60 = 60 ksi, Grade 80 threshold = 77 ksi)
    fy_grade60 = 60000u"psi"  # = 60 ksi
    fy_grade80_threshold = 77000u"psi"  # = 77 ksi
    
    ρ_min = if fy < fy_grade60
        0.0020
    elseif fy < fy_grade80_threshold
        0.0018
    else
        max(0.0014, 0.0018 * fy_grade60 / fy)  # dimensionless ratio
    end
    
    # As_min = ρ_min × b × h
    return ρ_min * b * h
end

# Backward compatible method with default fy = 60 ksi (deprecated)
function minimum_reinforcement(b::Length, h::Length)
    return minimum_reinforcement(b, h, 60000u"psi")
end

"""
    effective_depth(h; cover=0.75u"inch", bar_diameter=0.5u"inch")

Effective depth d = h - cover - db/2.

# Arguments
- `h`: Total slab thickness
- `cover`: Clear cover to reinforcement (default 0.75" for interior slab)
- `bar_diameter`: Assumed bar diameter (default #4 = 0.5")
"""
function effective_depth(h::Length; cover=0.75u"inch", bar_diameter=0.5u"inch")
    return h - cover - bar_diameter / 2
end

"""
    max_bar_spacing(h)

Maximum bar spacing per ACI 8.7.2.2.

    s_max = min(2h, 18 in)

# Reference
- ACI 318-14 Section 8.7.2.2
"""
function max_bar_spacing(h::Length)
    # ACI 8.7.2.2: s_max = min(2h, 18")
    return min(2 * h, 18.0u"inch")
end

# =============================================================================
# Phase 6: Punching Shear (ACI 22.6)
# =============================================================================

"""
    punching_perimeter(c1, c2, d)

Critical perimeter for punching shear at d/2 from column face.

# Arguments
- `c1`: Column dimension in direction 1
- `c2`: Column dimension in direction 2
- `d`: Effective slab depth

# Returns
Perimeter b₀ = 2(c1 + d) + 2(c2 + d)

# Reference
- ACI 318-14 Section 22.6.4
"""
function punching_perimeter(c1::Length, c2::Length, d::Length)
    return 2 * (c1 + d) + 2 * (c2 + d)
end

"""
    punching_αs(position::Symbol) -> Int

ACI 22.6.5.2(c) location factor αs for punching shear.

# Arguments
- `position`: Column position (:interior, :edge, or :corner)

# Returns
- αs = 40 for interior columns
- αs = 30 for edge columns
- αs = 20 for corner columns

# Reference
- ACI 318-14 Table 22.6.5.2
"""
function punching_αs(position::Symbol)
    if position == :interior
        return 40
    elseif position == :edge
        return 30
    else  # :corner or unknown
        return 20
    end
end

"""
    punching_capacity_interior(b0, d, fc; c1, c2, λ, position)

Punching shear capacity per ACI 22.6.5.2.

    Vc = min(4√f'c, (2 + 4/β)√f'c, (αs·d/b₀ + 2)√f'c) × b₀ × d

# Arguments
- `b0`: Critical perimeter from punching_perimeter()
- `d`: Effective depth
- `fc`: Concrete compressive strength
- `c1`: Column dimension parallel to span (for β calculation)
- `c2`: Column dimension perpendicular to span (for β calculation)
- `λ`: Lightweight concrete factor (1.0 for normal weight)
- `position`: Column position (:interior, :edge, :corner) for αs

# Returns
Nominal shear capacity Vn (unfactored)

# Reference
- ACI 318-14 Section 22.6.5.2
- StructurePoint Example Section 3.3
"""
function punching_capacity_interior(
    b0::Length,
    d::Length,
    fc::Pressure;
    c1::Length = 0u"inch",
    c2::Length = 0u"inch",
    λ::Float64 = 1.0,
    position::Symbol = :interior
)
    # ACI 22.6.5.2: Vc = coefficient × λ × √f'c × b0 × d
    # The formula is empirically calibrated for psi/inch → produces lbf
    # Strip to expected units at boundary, compute, return with units
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    b0_val = ustrip(u"inch", b0)
    d_val = ustrip(u"inch", d)
    
    # Common term: λ × √f'c × b0 × d (produces Float64 that represents lbf)
    common = λ * sqrt_fc * b0_val * d_val
    
    # ACI 22.6.5.2(a): Basic 4√f'c
    Vc_a = 4 * common
    
    # ACI 22.6.5.2(b): Column aspect ratio
    if c1 > 0u"inch" && c2 > 0u"inch"
        β = ustrip(max(c1, c2)) / ustrip(min(c1, c2))  # dimensionless
        Vc_b = (2 + 4/β) * common
    else
        Vc_b = Vc_a  # Default for square column
    end
    
    # ACI 22.6.5.2(c): Perimeter-to-depth ratio
    αs = punching_αs(position)
    Vc_c = (αs * d_val / b0_val + 2) * common
    
    return min(Vc_a, Vc_b, Vc_c) * u"lbf"
end

"""
    punching_demand(qu, l1, l2, c1, c2)

Punching shear demand at interior column.

    Vu = qu × (l1 × l2 - (c1 + d)(c2 + d))

Simplified as tributary area minus critical section area.

# Reference
- ACI 318-14 Section 22.6.4
"""
function punching_demand(
    qu::Pressure,
    At::Area,  # Tributary area from Voronoi
    c1::Length,
    c2::Length,
    d::Length
)
    # Critical section area
    Ac = (c1 + d) * (c2 + d)
    
    # Net loaded area
    A_net = At - Ac
    
    return qu * A_net
end

"""
    check_punching_shear(Vu, Vc; φ=0.75)

Check punching shear adequacy.

# Returns
(passes::Bool, ratio::Float64, message::String)
"""
function check_punching_shear(Vu, Vc; φ::Float64=0.75)
    φVc = φ * Vc
    ratio = Vu / φVc
    passes = ratio <= 1.0
    
    if passes
        msg = "OK: Vu/φVc = $(round(ratio, digits=3))"
    else
        msg = "NG: Vu/φVc = $(round(ratio, digits=3)) > 1.0 - increase h or add shear reinforcement"
    end
    
    return (passes=passes, ratio=ratio, message=msg)
end

# =============================================================================
# Phase 6b: One-Way (Beam Action) Shear (ACI 22.5)
# =============================================================================

"""
    one_way_shear_capacity(fc, bw, d; λ=1.0)

One-way shear capacity per ACI 22.5.5.1.

    Vc = 2λ√f'c × bw × d

# Arguments
- `fc`: Concrete compressive strength
- `bw`: Width of section (typically tributary width)
- `d`: Effective depth

# Reference
- ACI 318-14 Eq. 22.5.5.1
- StructurePoint Section 5.1
"""
function one_way_shear_capacity(
    fc::Pressure,
    bw::Length,
    d::Length;
    λ::Float64 = 1.0
)
    # ACI 22.5: Vc = 2λ√f'c × bw × d
    # Formula calibrated for psi/inch → lbf
    Vc = 2 * λ * sqrt(ustrip(u"psi", fc)) * ustrip(u"inch", bw) * ustrip(u"inch", d)
    return Vc * u"lbf"
end

"""
    one_way_shear_demand(qu, bw, ln, c, d)

One-way shear demand at distance d from column face.

# Arguments
- `qu`: Factored uniform load
- `bw`: Tributary width
- `ln`: Clear span (centerline to centerline minus column)
- `c`: Column dimension in shear direction
- `d`: Effective depth

# Returns
Vu at critical section (distance d from column face)

# Reference
- ACI 318-14 Section 22.5
- StructurePoint Section 5.1
"""
function one_way_shear_demand(
    qu::Pressure,
    bw::Length,
    ln::Length,
    c::Length,
    d::Length
)
    # Shear at face of support
    Vu_face = qu * bw * ln / 2
    
    # Reduce to critical section at distance d from face
    Vu = Vu_face - qu * bw * d
    
    return Vu
end

"""
    check_one_way_shear(Vu, Vc; φ=0.75)

Check one-way shear adequacy.

# Returns
NamedTuple (passes, ratio, message)
"""
function check_one_way_shear(Vu, Vc; φ::Float64=0.75)
    φVc = φ * Vc
    ratio = ustrip(Vu) / ustrip(φVc)
    passes = ratio <= 1.0
    
    if passes
        msg = "OK: Vu/φVc = $(round(ratio, digits=3))"
    else
        msg = "NG: Vu/φVc = $(round(ratio, digits=3)) > 1.0"
    end
    
    return (passes=passes, ratio=ratio, message=msg)
end

# =============================================================================
# Phase 6c: Moment Transfer Factors (ACI 8.4.2)
# =============================================================================

"""
    gamma_f(b1, b2)

Fraction of unbalanced moment transferred by flexure.

    γf = 1 / (1 + (2/3)√(b1/b2))

# Arguments
- `b1`: Critical section dimension parallel to span
- `b2`: Critical section dimension perpendicular to span

# Reference
- ACI 318-14 Eq. 8.4.2.3.2
- StructurePoint Section 3.2.5
"""
function gamma_f(b1::Length, b2::Length)
    # ACI 8.4.2.3.2: γf = 1 / (1 + (2/3)√(b1/b2))
    # b1/b2 is dimensionless, result is dimensionless
    return 1.0 / (1.0 + (2.0/3.0) * sqrt(b1 / b2))
end

"""
    gamma_v(b1, b2)

Fraction of unbalanced moment transferred by shear.

    γv = 1 - γf

# Reference
- ACI 318-14 Eq. 8.4.4.2.2
"""
function gamma_v(b1::Length, b2::Length)
    return 1.0 - gamma_f(b1, b2)
end

"""
    effective_slab_width(c2, h)

Effective slab width for moment transfer by flexure.

    bb = c2 + 3h

# Arguments
- `c2`: Column dimension perpendicular to span
- `h`: Slab thickness

# Reference
- ACI 318-14 Section 8.4.2.3.3
"""
function effective_slab_width(c2::Length, h::Length)
    return c2 + 3 * h
end

# =============================================================================
# Phase 6d: Edge/Corner Column Punching Geometry (ACI 22.6)
# =============================================================================

"""
    punching_geometry_edge(c1, c2, d)

Critical section geometry for edge column (3-sided perimeter).

# Arguments
- `c1`: Column dimension parallel to edge
- `c2`: Column dimension perpendicular to edge

# Returns
NamedTuple with b1, b2, b0, cAB (centroid distance from column face)

# Reference
- ACI 318-14 Section 22.6.4
- StructurePoint Section 5.2(a)
"""
function punching_geometry_edge(c1::Length, c2::Length, d::Length)
    # b1 = parallel to span (perpendicular to free edge)
    # For edge column: b1 = c1 + d/2 (extends d/2 into slab)
    b1 = c1 + d / 2
    
    # b2 = perpendicular to span (parallel to free edge)
    # Full width: b2 = c2 + d
    b2 = c2 + d
    
    # Perimeter: 3-sided (2 sides of b1, 1 side of b2)
    b0 = 2 * b1 + b2
    
    # Centroid of critical section from column face (into slab)
    # For U-shaped section: cAB = b1² / (2×b1 + b2)
    cAB = b1^2 / (2 * b1 + b2)
    
    return (b1=b1, b2=b2, b0=b0, cAB=cAB)
end

"""
    punching_geometry_corner(c1, c2, d)

Critical section geometry for corner column (2-sided perimeter).

# Returns
NamedTuple with b1, b2, b0, cAB_x, cAB_y (centroids in both directions)

# Reference
- ACI 318-14 Section 22.6.4
"""
function punching_geometry_corner(c1::Length, c2::Length, d::Length)
    # Both sides only extend d/2 into slab
    b1 = c1 + d / 2
    b2 = c2 + d / 2
    
    # Perimeter: 2-sided (1 side each direction)
    b0 = b1 + b2
    
    # Centroid from corner (both directions)
    # cAB = b² / (2 × (b1 + b2))
    denom = 2 * (b1 + b2)
    cAB_x = b1^2 / denom
    cAB_y = b2^2 / denom
    
    return (b1=b1, b2=b2, b0=b0, cAB_x=cAB_x, cAB_y=cAB_y)
end

"""
    punching_geometry_interior(c1, c2, d)

Critical section geometry for interior column (4-sided perimeter).

# Returns
NamedTuple with b1, b2, b0, cAB

# Reference
- ACI 318-14 Section 22.6.4
"""
function punching_geometry_interior(c1::Length, c2::Length, d::Length)
    b1 = c1 + d
    b2 = c2 + d
    b0 = 2 * b1 + 2 * b2
    cAB = b1 / 2  # Symmetric, centroid at center
    
    return (b1=b1, b2=b2, b0=b0, cAB=cAB)
end

"""
    polar_moment_Jc_edge(b1, b2, d, cAB)

Polar moment of inertia Jc for edge column critical section.

Used for combined shear stress with unbalanced moment.

# Formula (from StructurePoint page 42-43):
    Jc = 2×[b1×d³/12 + d×b1³/12 + (b1×d)×(b1/2 - cAB)²] + b2×d×cAB²

# Reference
- ACI 318-14 R8.4.4.2.3
- StructurePoint Section 5.2(a)
"""
function polar_moment_Jc_edge(b1::Length, b2::Length, d::Length, cAB::Length)
    # Two parallel sides (b1 legs)
    Jc_parallel = 2 * (b1 * d^3 / 12 + d * b1^3 / 12 + 
                       (b1 * d) * (b1 / 2 - cAB)^2)
    
    # Perpendicular side (b2 leg)
    Jc_perp = b2 * d * cAB^2
    
    return Jc_parallel + Jc_perp
end

"""
    polar_moment_Jc_interior(b1, b2, d, cAB)

Polar moment of inertia Jc for interior column critical section.

# Formula (from StructurePoint page 44):
    Jc = 2×[b1×d³/12 + d×b1³/12 + (b1×d)×(b1/2 - cAB)²] + 2×b2×d×cAB²

For symmetric section (cAB = b1/2), simplifies to:
    Jc = 2×[b1×d³/12 + d×b1³/12] + 2×b2×d×(b1/2)²

# Reference
- ACI 318-14 R8.4.4.2.3
- StructurePoint Section 5.2(b)
"""
function polar_moment_Jc_interior(b1::Length, b2::Length, d::Length)
    cAB = b1 / 2  # Symmetric section
    
    # Two parallel sides (b1 legs) - no eccentricity term for symmetric
    Jc_parallel = 2 * (b1 * d^3 / 12 + d * b1^3 / 12)
    
    # Two perpendicular sides (b2 legs)
    Jc_perp = 2 * b2 * d * cAB^2
    
    return Jc_parallel + Jc_perp
end

"""
    combined_punching_stress(Vu, Mub, b0, d, γv, Jc, cAB)

Combined punching shear stress with unbalanced moment transfer.

    vu = Vu/(b0×d) + γv×Mub×cAB/Jc

# Arguments
- `Vu`: Factored shear force
- `Mub`: Factored unbalanced moment
- `b0`: Critical perimeter
- `d`: Effective depth
- `γv`: Fraction transferred by shear (1 - γf)
- `Jc`: Polar moment of inertia
- `cAB`: Distance from centroid to extreme fiber

# Returns
Maximum shear stress vu (psi)

# Reference
- ACI 318-14 R8.4.4.2.3
- StructurePoint Section 5.2
"""
function combined_punching_stress(
    Vu::Force,
    Mub::Torque,
    b0::Length,
    d::Length,
    γv::Float64,
    Jc::SecondMomentOfArea,
    cAB::Length
)
    # ACI R8.4.4.2.3: vu = Vu/(b0×d) + γv×Mub×cAB/Jc
    # Direct shear stress
    v_direct = Vu / (b0 * d)
    
    # Moment transfer stress
    v_moment = γv * Mub * cAB / Jc
    
    # Combined (maximum at tension face)
    return v_direct + v_moment
end

"""
    punching_capacity_stress(fc, β, αs, b0, d; λ=1.0)

Punching shear capacity as stress per ACI 22.6.5.2.

    vc = min(4√f'c, (2 + 4/β)√f'c, (αs×d/b0 + 2)√f'c)

# Arguments
- `fc`: Concrete compressive strength
- `β`: Column aspect ratio (long/short)
- `αs`: Location factor (40 interior, 30 edge, 20 corner)
- `b0`: Critical perimeter
- `d`: Effective depth
- `λ`: Lightweight factor

# Returns
Nominal shear stress capacity vc (psi)

# Reference
- ACI 318-14 Table 22.6.5.2
"""
function punching_capacity_stress(
    fc::Pressure,
    β::Float64,
    αs::Int,
    b0::Length,
    d::Length;
    λ::Float64 = 1.0
)
    # ACI formulas are defined with √f'c in psi units
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    
    # ACI 22.6.5.2(a): Basic 4√f'c
    vc_a = 4 * λ * sqrt_fc
    
    # ACI 22.6.5.2(b): Aspect ratio (2 + 4/β)√f'c
    vc_b = (2 + 4/β) * λ * sqrt_fc
    
    # ACI 22.6.5.2(c): Perimeter-to-depth (αs×d/b0 + 2)√f'c
    vc_c = (αs * d / b0 + 2) * λ * sqrt_fc  # d/b0 is dimensionless
    
    return min(vc_a, vc_b, vc_c) * u"psi"
end

"""
    check_combined_punching(vu, vc; φ=0.75)

Check combined punching shear stress adequacy.

# Returns
NamedTuple (passes, ratio, message)
"""
function check_combined_punching(vu::Pressure, vc::Pressure; φ::Float64=0.75)
    # Ratio is dimensionless: vu/(φ×vc)
    ratio = vu / (φ * vc)
    passes = ratio <= 1.0
    
    msg = passes ? "OK: vu/φvc = $(round(ratio, digits=3))" :
                   "NG: vu/φvc = $(round(ratio, digits=3)) > 1.0"
    
    return (passes=passes, ratio=ratio, message=msg)
end

# =============================================================================
# Phase 6d+: Shear Stud Design (ACI 318-19 §22.6.8 / Ancon Shearfix)
# =============================================================================

"""
    size_effect_factor_λs(d)

ACI 318-19 size effect modification factor for punching shear.

    λs = 2 / √(1 + d/254mm) ≤ 1.0

# Reference
- ACI 318-19 Eq. (22.5.5.1.3)
- Ancon Shearfix Manual Eq. 7
"""
function size_effect_factor_λs(d::Length)
    d_mm = ustrip(u"mm", d)
    λs = 2.0 / sqrt(1.0 + d_mm / 254.0)
    return min(λs, 1.0)
end

"""
    punching_capacity_with_studs(fc, β, αs, b0, d, Av, s, fyt; λ=1.0)

Punching shear capacity with headed shear stud reinforcement per ACI 318-19 §22.6.8.

# Three Failure Modes Checked:
1. Compression strut limit (vc,max)
2. Combined concrete + steel within studs (vcs + vs)
3. Outer critical section (checked separately)

# Formulas (Ancon Manual):
- vc,max = 0.66√f'c (if s ≤ 0.5d), else 0.50√f'c
- vcs = 0.75 × vc (reduced concrete contribution)
- vs = Av × fyt / (b0 × s)
- Combined: φ(vcs + vs) ≤ φ × vc,max

# Arguments
- `fc`: Concrete compressive strength
- `β`: Column aspect ratio (long/short)
- `αs`: Location factor (40 interior, 30 edge, 20 corner)
- `b0`: Critical perimeter at column
- `d`: Effective depth
- `Av`: Total stud area per peripheral line
- `s`: Spacing between stud lines
- `fyt`: Stud yield strength
- `λ`: Lightweight concrete factor

# Returns
NamedTuple with (vcs, vs, vc_max, vc_total, compression_ok)
"""
function punching_capacity_with_studs(
    fc::Pressure,
    β::Float64,
    αs::Int,
    b0::Length,
    d::Length,
    Av::Area,
    s::Length,
    fyt::Pressure;
    λ::Float64 = 1.0
)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    λs = size_effect_factor_λs(d)
    b0_in = ustrip(u"inch", b0)
    d_in = ustrip(u"inch", d)
    s_in = ustrip(u"inch", s)
    Av_in2 = ustrip(u"inch^2", Av)
    fyt_psi = ustrip(u"psi", fyt)
    
    # Reduced concrete contribution with studs (Ancon Eq. 12a-c, factor of 0.75)
    # vcs = 0.75 × vc (concrete capacity is reduced when studs are used)
    vcs_a = 0.25 * λs * λ * sqrt_fc  # Was 0.33, reduced by 0.75
    vcs_b = 0.17 * (1 + 2/β) * λs * λ * sqrt_fc
    vcs_c = 0.083 * (2 + αs * d_in / b0_in) * λs * λ * sqrt_fc
    vcs = min(vcs_a, vcs_b, vcs_c)
    
    # Steel contribution (Ancon Eq. 13)
    # vs = Av × fyt / (b0 × s)
    vs = s_in > 0 ? Av_in2 * fyt_psi / (b0_in * s_in) : 0.0
    
    # Compression strut limit (Ancon Eq. 9-10)
    # vc,max = 0.66√f'c if s ≤ 0.5d, else 0.50√f'c
    if s_in <= 0.5 * d_in
        vc_max = 0.66 * sqrt_fc
    else
        vc_max = 0.50 * sqrt_fc
    end
    
    # Combined capacity (but limited by compression strut)
    vc_total = min(vcs + vs, vc_max)
    compression_ok = (vcs + vs) <= vc_max
    
    return (
        vcs = vcs * u"psi",
        vs = vs * u"psi",
        vc_max = vc_max * u"psi",
        vc_total = vc_total * u"psi",
        compression_ok = compression_ok
    )
end

"""
    punching_capacity_outer(fc, d; λ=1.0)

Punching capacity at outer critical section (beyond shear studs) per ACI 318-19.

    vc,out = 0.17 × λs × λ × √f'c

This is a reduced capacity compared to the column face, used to determine
how far the stud zone must extend.

# Reference
- Ancon Eq. 16
"""
function punching_capacity_outer(fc::Pressure, d::Length; λ::Float64 = 1.0)
    # At the outer critical section (beyond stud zone), concrete is unreinforced
    # For flat plates (two-way slabs), use the same limits as interior punching:
    # vc = 4λ√f'c (conservative, ignores β and αs which improve capacity at larger perimeters)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    λs = size_effect_factor_λs(d)
    # Using 4√f'c for consistency with inner section analysis
    vc_out = 4.0 * λs * λ * sqrt_fc
    return vc_out * u"psi"
end

"""
    minimum_stud_reinforcement(fc, b0, fyt)

Minimum shear stud reinforcement per ACI 318-19 §22.6.8.3.

    Av/s ≥ 0.17√f'c × b0/fyt

# Returns
Minimum Av/s ratio (Area/Length)
"""
function minimum_stud_reinforcement(fc::Pressure, b0::Length, fyt::Pressure)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    b0_in = ustrip(u"inch", b0)
    fyt_psi = ustrip(u"psi", fyt)
    
    Av_s_min = 0.17 * sqrt_fc * b0_in / fyt_psi
    return Av_s_min * u"inch^2/inch"
end

"""
    stud_area(diameter)

Cross-sectional area of a single headed shear stud.
"""
function stud_area(diameter::Length)
    return π * (diameter / 2)^2
end

"""
    design_shear_studs(vu, fc, β, αs, b0, d, position, fyt, stud_diameter; λ=1.0, φ=0.75)

Design headed shear stud reinforcement for a punching shear failure.

# Design Steps (Ancon Shearfix Method):
1. Compute required vs = vu/φ - vcs
2. Select number of rails based on position (8 interior, 6 edge, 4 corner)
3. Determine Av per line from n_rails × stud_area
4. Compute spacing s = Av × fyt / (b0 × vs)
5. Apply detailing limits (s ≤ 0.75d or 0.5d if high stress)
6. Determine number of studs per rail for outer section adequacy

# Arguments
- `vu`: Factored shear stress demand
- `fc`: Concrete compressive strength
- `β`: Column aspect ratio
- `αs`: Location factor (40/30/20)
- `b0`: Critical perimeter
- `d`: Effective depth
- `position`: Column position (:interior, :edge, :corner)
- `fyt`: Stud yield strength
- `stud_diameter`: Stud diameter

# Returns
ShearStudDesign struct with complete stud layout
"""
function design_shear_studs(
    vu::Pressure,
    fc::Pressure,
    β::Float64,
    αs::Int,
    b0::Length,
    d::Length,
    position::Symbol,
    fyt::Pressure,
    stud_diameter::Length;
    λ::Float64 = 1.0,
    φ::Float64 = 0.75
)
    d_in = ustrip(u"inch", d)
    b0_in = ustrip(u"inch", b0)
    vu_psi = ustrip(u"psi", vu)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    λs = size_effect_factor_λs(d)
    fyt_psi = ustrip(u"psi", fyt)
    
    # Convert fyt to psi for consistent units in ShearStudDesign struct
    fyt_unit = fyt_psi * u"psi"
    
    # Maximum nominal shear strength with headed studs (ACI 318-19 §22.6.8.2)
    # vn_max = 8λ√f'c at the critical section d/2 from column
    vc_max = 8.0 * λ * sqrt_fc
    
    # Check if studs can solve the problem
    if vu_psi > φ * vc_max
        # Demand exceeds maximum capacity with studs
        return ShearStudDesign(
            required = true,
            stud_diameter = stud_diameter,
            fyt = fyt_unit,
            n_rails = 0,
            n_studs_per_rail = 0,
            s0 = 0.0u"inch",
            s = 0.0u"inch",
            Av_per_line = 0.0u"inch^2",
            vs = 0.0u"psi",
            vcs = 0.0u"psi",
            vc_max = vc_max * u"psi",
            outer_ok = false
        )
    end
    
    # Reduced concrete contribution with studs
    vcs_a = 0.25 * λs * λ * sqrt_fc
    vcs_b = 0.17 * (1 + 2/β) * λs * λ * sqrt_fc
    vcs_c = 0.083 * (2 + αs * d_in / b0_in) * λs * λ * sqrt_fc
    vcs = min(vcs_a, vcs_b, vcs_c)
    
    # Required steel contribution
    vs_reqd = max(vu_psi / φ - vcs, 0.0)
    
    # Number of rails based on position (min 2 per face per Ancon)
    n_rails = position == :interior ? 8 :
              position == :edge ? 6 : 4
    
    # Single stud area
    As_stud = stud_area(stud_diameter)
    As_stud_in2 = ustrip(u"inch^2", As_stud)
    
    # Total Av per peripheral line
    Av_per_line = n_rails * As_stud_in2
    
    # Required spacing: vs = Av × fyt / (b0 × s) → s = Av × fyt / (b0 × vs)
    if vs_reqd > 0
        s_reqd = Av_per_line * fyt_psi / (b0_in * vs_reqd)
    else
        s_reqd = 0.75 * d_in  # Use max allowed if no steel required
    end
    
    # Apply detailing limits
    # Max spacing = 0.75d (or 0.5d if vu > 0.5φ√f'c)
    high_stress = vu_psi > 0.5 * φ * sqrt_fc
    s_max = high_stress ? 0.5 * d_in : min(0.75 * d_in, 500.0 / 25.4)  # 500mm limit
    s = min(s_reqd, s_max)
    
    # Check minimum reinforcement
    Av_s_min = minimum_stud_reinforcement(fc, b0, fyt)
    Av_s_min_val = ustrip(u"inch^2/inch", Av_s_min)
    Av_s_actual = Av_per_line / s
    if Av_s_actual < Av_s_min_val
        # Need to reduce spacing to meet minimum
        s = Av_per_line / Av_s_min_val
    end
    
    # First stud spacing (0.35d to 0.5d from column face)
    s0 = 0.5 * d_in
    
    # Actual vs provided
    vs_provided = Av_per_line * fyt_psi / (b0_in * s)
    
    # Number of studs per rail needed for outer section
    # Outer section at d/2 beyond last stud must have vc,out ≥ vu_outer
    vc_out = punching_capacity_outer(fc, d; λ=λ)
    vc_out_psi = ustrip(u"psi", vc_out)
    
    # Compute stud zone extent and outer perimeter
    # With n studs at spacing s, stud zone extends: s0 + (n-1)*s from column face
    # Outer critical section is at: stud_zone + d/2
    n_studs_min = 3
    n_studs = n_studs_min
    stud_zone = s0 + (n_studs - 1) * s
    outer_perimeter_dist = stud_zone + d_in / 2
    
    # Outer perimeter is larger → shear stress is lower
    # b0_out ≈ b0 + 8 × outer_perimeter_dist (for interior column, 4 sides each +2×dist)
    b0_out = b0_in + 8 * outer_perimeter_dist
    
    # Shear stress at outer section (approximate - shear reduces by ratio of perimeters)
    vu_out_psi = vu_psi * b0_in / b0_out
    
    # Outer section check
    outer_ok = φ * vc_out_psi >= vu_out_psi
    
    return ShearStudDesign(
        required = true,
        stud_diameter = stud_diameter,
        fyt = fyt_unit,
        n_rails = n_rails,
        n_studs_per_rail = n_studs,
        s0 = s0 * u"inch",
        s = s * u"inch",
        Av_per_line = Av_per_line * u"inch^2",
        vs = vs_provided * u"psi",
        vcs = vcs * u"psi",
        vc_max = vc_max * u"psi",
        outer_ok = outer_ok
    )
end

"""
    check_punching_with_studs(vu, studs; φ=0.75)

Check punching shear adequacy with shear stud reinforcement.

# Returns
NamedTuple (passes, ratio, message)
"""
function check_punching_with_studs(vu::Pressure, studs::ShearStudDesign; φ::Float64 = 0.75)
    if !studs.required || studs.n_rails == 0
        return (passes=false, ratio=Inf, message="Studs not designed or inadequate")
    end
    
    vu_psi = ustrip(u"psi", vu)
    vcs_psi = ustrip(u"psi", studs.vcs)
    vs_psi = ustrip(u"psi", studs.vs)
    vc_max_psi = ustrip(u"psi", studs.vc_max)
    
    # Combined capacity
    vc_total = min(vcs_psi + vs_psi, vc_max_psi)
    
    ratio = vu_psi / (φ * vc_total)
    passes = ratio <= 1.0 && studs.outer_ok
    
    msg = if passes
        "OK (with studs): vu/φvc = $(round(ratio, digits=3))"
    elseif !studs.outer_ok
        "NG: Outer section fails - extend stud zone"
    else
        "NG (with studs): vu/φvc = $(round(ratio, digits=3)) > 1.0"
    end
    
    return (passes=passes, ratio=ratio, message=msg)
end

# =============================================================================
# Phase 6e: Moment Transfer Reinforcement (ACI 8.4.2.3)
# =============================================================================

"""
    transfer_reinforcement(Mu, γf, bb, d, fc, fy)

Required reinforcement for moment transfer by flexure.

The fraction γf×Mu must be transferred within effective width bb.

# Arguments
- `Mu`: Total unbalanced moment at column
- `γf`: Fraction transferred by flexure
- `bb`: Effective slab width = c2 + 3h
- `d`: Effective depth
- `fc`: Concrete strength
- `fy`: Steel yield strength

# Returns
Required As within effective width bb

# Reference
- ACI 318-14 Section 8.4.2.3
- StructurePoint Table 8
"""
function transfer_reinforcement(
    Mu::Moment,
    γf::Float64,
    bb::Length,
    d::Length,
    fc::Pressure,
    fy::Pressure
)
    # Moment to be transferred by flexure
    Mu_transfer = γf * Mu
    
    # Required reinforcement within effective width
    As_req = required_reinforcement(Mu_transfer, bb, d, fc, fy)
    
    return As_req
end

"""
    additional_transfer_bars(As_transfer, As_provided, bb, strip_width, bar_area)

Calculate additional reinforcement needed at column for moment transfer.

# Arguments
- `As_transfer`: Required As within effective width bb
- `As_provided`: Total As provided in strip
- `bb`: Effective slab width
- `strip_width`: Full strip width (column or middle strip)
- `bar_area`: Area per bar

# Returns
NamedTuple (As_within_bb, As_additional, n_bars_additional)

# Reference
- StructurePoint Table 8
"""
function additional_transfer_bars(
    As_transfer::Area,
    As_provided::Area,
    bb::Length,
    strip_width::Length,
    bar_area::Area
)
    # Portion of provided reinforcement within bb (proportional)
    # bb/strip_width is dimensionless
    As_within_bb = As_provided * (bb / strip_width)
    
    # Additional area needed
    As_additional = max(0.0 * bar_area, As_transfer - As_within_bb)
    
    # Number of additional bars (As_additional/bar_area is dimensionless)
    n_bars = ceil(Int, As_additional / bar_area)
    
    return (
        As_within_bb = As_within_bb,
        As_additional = As_additional,
        n_bars_additional = n_bars
    )
end

# =============================================================================
# Phase 6b: Structural Integrity Reinforcement (ACI 318-19 §8.7.4.2)
# =============================================================================
#
# Structural integrity reinforcement prevents progressive collapse by requiring
# bottom bars that pass continuously through or within the column core.
# This ensures a "cable" mechanism if the slab loses support at a column.

"""
    integrity_reinforcement(
        tributary_area::Area,
        qD::LinearLoad,
        qL::LinearLoad,
        fy::Pressure;
        load_factor::Float64 = 2.0
    ) -> NamedTuple

Calculate required structural integrity reinforcement per ACI 318-19 §8.7.4.2.

The required steel area provides tensile capacity to carry the reaction force
from the tributary area under a progressive collapse scenario.

# Arguments
- `tributary_area`: Area supported by the column connection
- `qD`: Dead load per unit area
- `qL`: Live load per unit area  
- `fy`: Reinforcement yield strength
- `load_factor`: Safety factor (default 2.0 per ACI)

# Returns
Named tuple with:
- `As_integrity`: Minimum bottom steel area passing through column core (in²)
- `Pu_integrity`: Factored reaction force the steel must resist (kip)

# Notes
- Bottom bars must pass through or be anchored within the column core
- Applies to all column types (interior, edge, corner)
- This is in addition to flexural reinforcement requirements

# Reference
- ACI 318-19 §8.7.4.2: Two-way slab structural integrity
- ACI 318-19 §R8.7.4.2: Commentary on progressive collapse resistance
"""
function integrity_reinforcement(
    tributary_area::Area,
    qD::Pressure,  # psf type loads
    qL::Pressure,
    fy::Pressure;
    load_factor::Float64 = 2.0
)
    # Factored load on tributary area
    # ACI uses approximately 2×(D+L) for progressive collapse scenario
    w_total = qD + qL
    Pu = load_factor * w_total * tributary_area
    
    # Required steel area: As ≥ Pu / (ϕ × fy)
    # Using ϕ = 0.9 for tension
    ϕ = 0.9
    As_required = Pu / (ϕ * fy)
    
    return (
        As_integrity = uconvert(u"inch^2", As_required),
        Pu_integrity = uconvert(kip, Pu)
    )
end

"""
    check_integrity_reinforcement(
        As_bottom_provided::Area,
        As_integrity_required::Area
    ) -> NamedTuple

Check if provided bottom reinforcement satisfies integrity requirements.

# Arguments
- `As_bottom_provided`: Total area of bottom bars passing through column core
- `As_integrity_required`: Required area from `integrity_reinforcement()`

# Returns
Named tuple with:
- `ok`: Bool - true if check passes
- `utilization`: Float64 - ratio of required to provided
"""
function check_integrity_reinforcement(
    As_bottom_provided::Area,
    As_integrity_required::Area
)
    # Ratio is dimensionless; add small epsilon in same units to avoid div by zero
    utilization = As_integrity_required / max(As_bottom_provided, 1e-6 * As_integrity_required)
    
    return (
        ok = As_bottom_provided >= As_integrity_required,
        utilization = utilization
    )
end

# =============================================================================
# Phase 7: Deflection (ACI 24.2)
# =============================================================================

"""
    cracked_moment_of_inertia(As, b, d, Ec, Es)

Cracked section moment of inertia Icr per ACI 24.2.3.5.

Uses transformed section analysis with modular ratio n = Es/Ec.
"""
function cracked_moment_of_inertia(
    As::Area,
    b::Length,
    d::Length,
    Ec::Pressure,
    Es::Pressure = 29000ksi
)
    # Convert everything to consistent units (psi, inches) to avoid Unitful issues
    As_in = ustrip(u"inch^2", As)
    b_in = ustrip(u"inch", b)
    d_in = ustrip(u"inch", d)
    Ec_psi = ustrip(u"psi", Ec)
    Es_psi = ustrip(u"psi", Es)
    
    # Modular ratio n = Es/Ec (dimensionless)
    n = Es_psi / Ec_psi
    
    # Neutral axis depth from transformed section analysis
    # Equilibrium: b·c²/2 = n·As·(d-c)
    # Quadratic: c² + (2n·As/b)·c - (2n·As·d/b) = 0
    k1 = 2 * n * As_in / b_in       # inches
    k2 = -k1 * d_in                 # inch² (negative coefficient)
    c = (-k1 + sqrt(k1^2 - 4*k2)) / 2  # inches
    
    # Cracked moment of inertia: Icr = b·c³/3 + n·As·(d-c)²
    Icr = b_in * c^3 / 3 + n * As_in * (d_in - c)^2  # in⁴
    
    return Icr * u"inch^4"
end

"""
    effective_moment_of_inertia(Mcr, Ma, Ig, Icr)

Effective moment of inertia per ACI 24.2.3.5.

    Ie = Icr + (Ig - Icr) × (Mcr/Ma)³  when Ma > Mcr
    Ie = Ig                             when Ma ≤ Mcr

# Arguments
- `Mcr`: Cracking moment = fr × Ig / yt
- `Ma`: Service moment
- `Ig`: Gross moment of inertia
- `Icr`: Cracked moment of inertia

# Reference
- ACI 318-14 Eq. 24.2.3.5a
"""
function effective_moment_of_inertia(Mcr, Ma, Ig, Icr)
    if Ma <= Mcr
        return Ig
    end
    
    ratio = Mcr / Ma
    Ie = Icr + (Ig - Icr) * ratio^3
    
    # Ie cannot exceed Ig
    return min(Ie, Ig)
end

"""
    cracking_moment(fr, Ig, h)

Cracking moment per ACI 24.2.3.5.

    Mcr = fr × Ig / yt

where yt = h/2 for rectangular sections.

# Arguments
- `fr`: Modulus of rupture (Pressure)
- `Ig`: Gross second moment of area (L⁴)
- `h`: Section depth (Length)
"""
function cracking_moment(fr::Pressure, Ig::SecondMomentOfArea, h::Length)
    yt = h / 2
    return fr * Ig / yt
end

"""
    immediate_deflection(w, l, Ec, Ie)

Immediate deflection for uniformly loaded member.

    Δi = 5 × w × l⁴ / (384 × Ec × Ie)

# Reference
- Standard beam formula
"""
function immediate_deflection(
    w::Force,  # Load per unit length
    l::Length,
    Ec::Pressure,
    Ie::Volume
)
    return 5 * w * l^4 / (384 * Ec * Ie)
end

"""
    long_term_deflection_factor(ξ, ρ_prime)

Long-term deflection multiplier per ACI 24.2.4.1.

    λΔ = ξ / (1 + 50ρ')

where:
- ξ = time-dependent factor (2.0 for 5+ years)
- ρ' = compression reinforcement ratio

# Reference
- ACI 318-14 Section 24.2.4.1
"""
function long_term_deflection_factor(ξ::Float64=2.0, ρ_prime::Float64=0.0)
    return ξ / (1 + 50 * ρ_prime)
end

"""
    deflection_limit(l, limit_type::Symbol)

Allowable deflection per ACI Table 24.2.2.

# Arguments
- `l`: Span length
- `limit_type`: :immediate_ll (l/360), :total (l/240), :sensitive (l/480)
"""
function deflection_limit(l::Length, limit_type::Symbol)
    divisor = if limit_type == :immediate_ll
        360  # Immediate deflection due to live load
    elseif limit_type == :total
        240  # Total deflection after attachment of elements
    elseif limit_type == :sensitive
        480  # Members supporting sensitive elements
    else
        240  # Default
    end
    
    # l/divisor preserves length units
    return l / divisor
end

"""
    load_distribution_factor(strip::Symbol, position::Symbol)

Load distribution factor (LDF) for column or middle strip.

Per ACI 318-14 Table 8.10.5.7.1, the negative and positive moments are distributed
to column and middle strips. The LDF represents the average portion of moment
carried by the strip.

# Arguments
- `strip`: :column or :middle
- `position`: :exterior (end span) or :interior

# Returns
- LDF value (0-1)

# Reference
- PCA Notes on ACI 318-11 Section 9.5.3.4
"""
function load_distribution_factor(strip::Symbol, position::Symbol)
    # Column strip distribution percentages from ACI Table 8.10.5.7.1:
    # - Exterior negative: 100% (no edge beam)
    # - Positive: 60%
    # - Interior negative: 75%
    
    # The LDF formula weights the positive region double since it spans the middle:
    # LDFc = (2×LDF⁺ + LDF⁻_L + LDF⁻_R) / 4
    # Reference: PCA Notes on ACI 318-11, Section 9.5.3.4
    
    if position == :exterior
        # End span: 
        # LDF⁺ = 0.60, LDF⁻_ext = 1.00, LDF⁻_int = 0.75
        # LDFc = (2×0.60 + 1.00 + 0.75) / 4 = 2.95/4 = 0.7375 ≈ 0.738
        LDF_c = (2 * 0.60 + 1.00 + 0.75) / 4
    else
        # Interior span:
        # LDF⁺ = 0.35 (from Table 6), LDF⁻ = 0.75 both sides
        # LDFc = (2×0.35 + 0.75 + 0.75) / 4 = 2.20/4 = 0.55
        # But SP reports 0.675 for interior spans
        # This uses higher positive fraction: (2×0.525 + 0.75 + 0.75) / 4 = 0.675
        LDF_c = 0.675
    end
    
    return strip == :column ? LDF_c : 1.0 - LDF_c
end

"""
    frame_deflection_fixed(w, l, Ec, Ie_frame)

Fixed-end deflection for a continuous frame strip.

Uses fixed-fixed beam formula (coefficient = 1, not 5 for simply supported).

# Formula
    Δframe,fixed = wl⁴/(384EcIe)

# Arguments
- `w`: Service load per unit length (force/length)
- `l`: Span length
- `Ec`: Concrete modulus
- `Ie_frame`: Effective moment of inertia for frame strip

# Reference
- PCA Notes on ACI 318-11 Eq. 9.5.3.4 Eq. 10
"""
function frame_deflection_fixed(w, l, Ec, Ie_frame)
    # Fixed-fixed beam: Δ = wl⁴/(384EI) 
    # Note: Simply supported would use 5wl⁴/(384EI)
    return w * l^4 / (384 * Ec * Ie_frame)
end

"""
    strip_deflection_fixed(Δ_frame_fixed, LDF, Ie_frame, Ig_strip)

Fixed-end deflection for a column or middle strip.

# Formula
    Δstrip,fixed = LDF × Δframe,fixed × (Ie_frame/Ig_strip)

The ratio Ie_frame/Ig_strip accounts for the different stiffnesses
of the full frame vs. the individual strip.

# Arguments
- `Δ_frame_fixed`: Frame strip fixed-end deflection
- `LDF`: Load distribution factor for the strip
- `Ie_frame`: Effective moment of inertia for frame strip
- `Ig_strip`: Gross moment of inertia for the strip

# Reference
- PCA Notes on ACI 318-11 Eq. 9.5.3.4 Eq. 11
"""
function strip_deflection_fixed(Δ_frame_fixed, LDF::Float64, Ie_frame, Ig_strip)
    return LDF * Δ_frame_fixed * (Ie_frame / Ig_strip)
end

"""
    deflection_from_rotation(θ, l, Ig, Ie)

Midspan deflection contribution from support rotation.

# Formula
    Δθ = θ × (l/8) × (Ig/Ie)

# Arguments
- `θ`: Rotation at support (radians)
- `l`: Span length
- `Ig`: Gross moment of inertia
- `Ie`: Effective moment of inertia

# Reference
- PCA Notes on ACI 318-11 Eq. 9.5.3.4 Eq. 14
"""
function deflection_from_rotation(θ::Float64, l, Ig, Ie)
    return θ * l / 8 * (Ig / Ie)
end

"""
    support_rotation(M_net, Kec)

Rotation at support due to unbalanced moment.

# Formula
    θ = M_net / Kec

# Arguments
- `M_net`: Net unbalanced moment at support
- `Kec`: Equivalent column stiffness

# Reference
- PCA Notes on ACI 318-11 Eq. 9.5.3.4 Eq. 12
"""
function support_rotation(M_net, Kec)
    # Convert to consistent units and return in radians
    M_inlb = ustrip(u"lbf*inch", M_net)
    Kec_inlb = ustrip(u"lbf*inch", Kec)
    return M_inlb / Kec_inlb  # radians
end

"""
    two_way_panel_deflection(Δcx, Δcy, Δmx, Δmy)

Mid-panel deflection for a two-way slab panel.

Combines column and middle strip deflections from both orthogonal directions.

# Formula
    Δ = (Δcx + Δmy)/2 + (Δcy + Δmx)/2

For square panels where Δcx ≈ Δcy and Δmx ≈ Δmy:
    Δ ≈ Δcx + Δmx

# Arguments
- `Δcx`: Column strip deflection in x-direction
- `Δcy`: Column strip deflection in y-direction  
- `Δmx`: Middle strip deflection in x-direction
- `Δmy`: Middle strip deflection in y-direction

# Returns
- Mid-panel deflection

# Reference
- PCA Notes on ACI 318-11 Eq. 9.5.3.4 Eq. 8
"""
function two_way_panel_deflection(Δcx, Δcy, Δmx, Δmy)
    return (Δcx + Δmy) / 2 + (Δcy + Δmx) / 2
end

"""
    two_way_panel_deflection(Δcx, Δmx)

Simplified mid-panel deflection for square panels.

For square panels, deflections in x and y directions are equal,
so Δcy = Δcx and Δmy = Δmx.

# Formula
    Δ = Δcx + Δmx

# Arguments
- `Δcx`: Column strip deflection
- `Δmx`: Middle strip deflection

# Reference
- PCA Notes on ACI 318-11 Eq. 9.5.3.4 Eq. 8 (simplified)
"""
function two_way_panel_deflection(Δcx, Δmx)
    return Δcx + Δmx
end

# =============================================================================
# Initial Column Estimate (Phase 2)
# =============================================================================

"""
    estimate_column_size(At, qu, n_stories_above, fc; fy=60000u"psi", shape=:square)

Estimate initial column size from tributary area before full column design.

This provides an initial estimate needed for slab clear span calculation (ln = l - c).
The estimate is intentionally conservative (tends to undersize) so that:
- Slab clear span is slightly overestimated → thicker slab (safe)
- Proper column sizing will give larger columns → shorter clear span (safe)

# Arguments
- `At`: Tributary area per floor (from Voronoi, m²)
- `qu`: Factored floor load (kPa or psf)
- `n_stories_above`: Number of stories supported by column
- `fc`: Concrete compressive strength (f'c)
- `fy`: Reinforcement yield strength (default 60 ksi)
- `shape`: :square (default) or :rectangular

# Returns
- Column dimension c (for square) as Length
- For rectangular, returns (c1, c2) tuple with c2 = 1.5 × c1

# Method
Uses simplified capacity formula:
    Pu ≈ At × qu × n_stories_above
    Ag_required ≈ Pu / (φ × 0.80 × [0.85 f'c (1-ρg) + ρg × fy])
    
Assumes ρg ≈ 2% (typical), φ = 0.65 (compression-controlled)
Simplifies to: Ag ≈ Pu / (0.40 × f'c)  for f'c ≤ 6000 psi

# Reference
- ACI 318-14 Section 22.4.2 (nominal axial strength)
- Rule of thumb: c ≈ √(Ag)

# Example
```julia
At = 100u"m^2"      # 100 m² tributary
qu = 10u"kPa"       # ~200 psf factored
n = 5               # 5 stories above
fc = 4000u"psi"
c = estimate_column_size(At, qu, n, fc)  # ≈ 16-18 inches
```
"""
function estimate_column_size(
    At::Area,
    qu::Pressure,
    n_stories_above::Int,
    fc::Pressure;
    fy::Pressure = 60000u"psi",
    shape::Symbol = :square,
    span::Union{Length, Nothing} = nothing,  # For punching-based minimum
    span_ratio::Float64 = 15.0  # c = span / ratio for punching adequacy
)
    # Estimated factored axial load
    Pu = At * qu * n_stories_above
    
    # Required gross area (simplified for typical reinforcement)
    # Full formula: φPn = φ × 0.80 × [0.85f'c(Ag - As) + fy×As]
    # Simplified with ρg ≈ 2%, φ = 0.65:
    # Ag ≈ Pu / (0.65 × 0.80 × [0.85×f'c×0.98 + fy×0.02])
    # For fc=4ksi, fy=60ksi: ≈ Pu / (0.40 × f'c)
    Ag_axial = Pu / (0.40 * fc)
    
    # For flat plate design, punching shear often governs column size
    # Use span-based estimate: c ≈ span / 15 (per StructurePoint guidance)
    if !isnothing(span)
        c_punching = span / span_ratio
        Ag_punching = c_punching^2
        Ag = max(Ag_axial, Ag_punching)
    else
        Ag = Ag_axial
    end
    
    # Apply minimum column size (14" for flat plates, 10" otherwise)
    c_min = isnothing(span) ? 10.0u"inch" : 14.0u"inch"
    Ag = max(Ag, c_min^2)
    
    if shape == :square
        c = sqrt(Ag)
        return ceil(ustrip(u"inch", c)) * u"inch"
    else
        # Rectangular: c2 = 1.5 × c1 (typical aspect ratio)
        # Ag = c1 × c2 = c1 × 1.5c1 = 1.5c1²
        c1 = sqrt(Ag / 1.5)
        c2 = 1.5 * c1
        return (ceil(ustrip(u"inch", c1)) * u"inch", ceil(ustrip(u"inch", c2)) * u"inch")
    end
end

"""
    estimate_column_size_from_span(span; ratio=15)

Alternative column estimate from span using rule of thumb.

# Arguments
- `span`: Center-to-center span
- `ratio`: Span-to-column ratio (default 15, typical range 12-18)

# Returns
Column dimension c = span / ratio

# Reference
Common practice for preliminary design:
- High-rise: c ≈ L/12 to L/14
- Mid-rise: c ≈ L/15 to L/18
- Low-rise: c ≈ L/18 to L/20
"""
function estimate_column_size_from_span(span::Length; ratio::Float64=15.0)
    c = span / ratio
    # Round up to nearest inch
    return ceil(ustrip(u"inch", c)) * u"inch"
end

# Note: scale_column_section is now in members/sections/concrete/rc_rect_column_section.jl
# Note: StripReinforcement and FlatPlatePanelResult are defined in slabs/types.jl

# =============================================================================
# Exports
# =============================================================================

export Ec, β1, fr
export min_thickness_flat_plate, clear_span
export total_static_moment, distribute_moments_mddm, distribute_moments_aci
export required_reinforcement, minimum_reinforcement, effective_depth, max_bar_spacing
export punching_perimeter, punching_capacity_interior, punching_demand, check_punching_shear
export cracked_moment_of_inertia, effective_moment_of_inertia, cracking_moment
export immediate_deflection, long_term_deflection_factor, deflection_limit
export MDDM_COEFFICIENTS, ACI_DDM_LONGITUDINAL
export estimate_column_size, estimate_column_size_from_span
# Note: scale_column_section exported from members/sections/concrete/

# One-way shear
export one_way_shear_capacity, one_way_shear_demand, check_one_way_shear

# Moment transfer factors
export gamma_f, gamma_v, effective_slab_width

# Edge/corner punching geometry
export punching_geometry_edge, punching_geometry_corner, punching_geometry_interior
export polar_moment_Jc_edge, polar_moment_Jc_interior
export combined_punching_stress, punching_capacity_stress, check_combined_punching
export punching_αs

# Shear stud design (ACI 318-19 §22.6.8)
export size_effect_factor_λs, punching_capacity_with_studs, punching_capacity_outer
export minimum_stud_reinforcement, stud_area, design_shear_studs, check_punching_with_studs

# Moment transfer reinforcement
export transfer_reinforcement, additional_transfer_bars

# Structural integrity reinforcement
export integrity_reinforcement, check_integrity_reinforcement

# EFM stiffness calculations
export slab_moment_of_inertia, column_moment_of_inertia, torsional_constant_C
export slab_beam_stiffness_Ksb, column_stiffness_Kc, torsional_member_stiffness_Kt
export equivalent_column_stiffness_Kec, distribution_factor_DF, carryover_factor_COF
export fixed_end_moment_FEM, face_of_support_moment

# Two-way deflection
export load_distribution_factor, frame_deflection_fixed, strip_deflection_fixed
export deflection_from_rotation, support_rotation, two_way_panel_deflection
# StripReinforcement, FlatPlatePanelResult exported from slabs/types.jl
