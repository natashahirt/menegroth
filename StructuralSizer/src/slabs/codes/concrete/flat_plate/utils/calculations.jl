# =============================================================================
# CIP Flat Plate Design per ACI 318-11
# =============================================================================
#
# Methodology: StructurePoint Design Examples (ACI 318-11)
# Equations: Broyles, Solnosky, Brown (2024) - Supplementary Document
#
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf
# Example: 18 ft × 14 ft panel, 16" columns, f'c=4000 psi (slab), fy=60 ksi
#
# =============================================================================
# NOT YET IMPLEMENTED (Future Work)
# =============================================================================
#
# 1. Shear Reinforcement (ACI 318-11 §11.11.5)
#    - Stud rails / headed shear studs for punching shear enhancement
#    - Stirrup cages around columns
#    - vn = vc + vs calculations where shear exceeds concrete capacity
#    Note: Currently punching shear failure requires column size or slab thickness increase
#
# 2. Pattern Loading (ACI 318-11 §13.7.6)  
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
#   h = min_thickness(FlatPlate(), 16.67u"ft")  # Returns Quantity in inches
#   fc = 4000u"psi"
#   Ec_val = Ec(fc, 150)  # Returns Quantity in psi (wc=150 pcf)
#
# =============================================================================

using Unitful
using Unitful: @u_str
using Asap: kip, ksi, ksf, psf, pcf
using Asap: Length, Area, Volume, SecondMomentOfArea, TorsionalConstant, Pressure, Force, Moment, Torque, LinearLoad


# =============================================================================
# Self-Weight Calculation
# =============================================================================


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
slab_self_weight(h, ρ) = uconvert(psf, h * ρ * GRAVITY)


"""
    clear_span(l, c; shape=:rectangular)

Clear span from face-to-face of supports.

For circular columns, deducts the equivalent square dimension `c_eq = D√(π/4)`
so that the cross-sectional area is preserved.

# Arguments
- `l`: Center-to-center span
- `c`: Column dimension in span direction (diameter D for circular)
- `shape`: Column shape — `:rectangular` or `:circular`
"""
function clear_span(l::Length, c::Length; shape::Symbol=:rectangular)
    if shape == :circular
        return l - equivalent_square_column(c)
    else
        return l - c
    end
end

# =============================================================================
# Circular Column Utilities (ACI 318-11 R13.6.2.5)
# =============================================================================

"""
    equivalent_square_column(D) -> Length

Equivalent square column dimension for a circular column of diameter D.

    c_eq = D × √(π/4) ≈ 0.886 D

Preserves cross-sectional area: π D²/4 = c_eq².
Used for clear span, torsional constant, and EFM stiffness calculations.

# Reference
- ACI 318-11 R13.6.2.5
- PCA Notes on ACI 318-11: "For circular columns, use equivalent square"
"""
function equivalent_square_column(D::Length)
    return D * sqrt(π / 4)
end

"""
    circular_column_Ic(D) -> SecondMomentOfArea

Moment of inertia for a circular column section.

    Ic = π D⁴ / 64
"""
function circular_column_Ic(D::Length)
    return π * D^4 / 64
end

# =============================================================================
# Phase 3: Static Moment & Moment Distribution (ACI 318-11 §13.6)
# =============================================================================

"""
    total_static_moment(qu, l2, ln)

Total factored static moment per ACI 318-11 Eq. (13-4).

    M₀ = (qᵤ × l₂ × lₙ²) / 8

# Arguments
- `qu`: Factored uniform load (psf or kPa)
- `l2`: Panel width perpendicular to span direction
- `ln`: Clear span (face-to-face of columns)

# Reference
- ACI 318-11 §13.6.2.2 (Eq. 13-4)
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
- ACI 318-11 §13.6.3, §13.6.4 (underlying methodology)
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
ACI DDM Longitudinal Distribution Coefficients per ACI 318-11 §13.6.3.

These are the code-mandated coefficients for distributing total static moment M₀
to negative and positive moment regions along the span. These apply before
transverse distribution to column/middle strips.

# Source
- ACI 318-11 §13.6.3.2 (interior), §13.6.3.3 (end span)
- Supplementary Document Table S-1 (uses same values: 0.26, 0.52, 0.70)

# Note
Transverse distribution to column/middle strips uses ACI Tables 8.10.5.1-5.7
and varies with l₂/l₁ and αf. For flat plates (αf = 0), see distribute_moments_aci().

# Reference
- ACI 318-11 §13.6.3
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
ACI 318-11 §13.6.4.1 — Column strip negative moment at interior supports.
For flat plates (αf = 0), always 75%.
"""
const ACI_COL_STRIP_INT_NEG = 0.75

"""
ACI 318-11 §13.6.4.2 — Column strip negative moment at exterior supports.
Without edge beam (βt = 0), always 100%.
"""
const ACI_COL_STRIP_EXT_NEG_NO_BEAM = 1.00

"""
    edge_beam_βt(h, c1, c2, l2, Ecs_slab, Ecs_beam)

Compute the torsional stiffness ratio β_t for an edge beam per ACI 318-11 Eq. (13-5).

    β_t = E_cb × C / (2 × E_cs × I_s)

When no explicit beam dimensions are provided, the "beam" is taken as the
slab depth × column dimension at the edge (ACI R8.4.1.8), which gives a
conservative (low) β_t for a flat plate with spandrel columns.

# Arguments
- `h`: Slab thickness
- `c1`: Column dimension in span direction (torsional member length)
- `c2`: Column dimension perpendicular to span (torsional member width)
- `l2`: Panel width perpendicular to span
- `Ecs_slab`: Slab concrete modulus (default: same as beam)
- `Ecs_beam`: Beam concrete modulus (default: same as slab)

# Returns
Dimensionless torsional stiffness ratio β_t

# Reference
- ACI 318-11 §13.6.4.2, Eq. (13-5)
- ACI 318-11 §13.2.4 (effective beam section)
"""
function edge_beam_βt(h::Length, c1::Length, c2::Length, l2::Length;
                      Ecs_slab::Pressure = 1.0u"psi",
                      Ecs_beam::Pressure = Ecs_slab)
    # Torsional constant of the slab strip acting as edge beam
    # x = h (slab thickness, short dimension), y = c2 (column width, long dimension)
    C = torsional_constant_C(h, c2)
    
    # Slab moment of inertia for the full panel width
    Is = slab_moment_of_inertia(l2, h)
    
    # β_t = E_cb × C / (2 × E_cs × I_s)
    # When E_cb = E_cs (same concrete), simplifies to C / (2 × I_s)
    E_ratio = ustrip(Ecs_beam) / ustrip(Ecs_slab)
    βt = E_ratio * ustrip(u"inch^4", C) / (2.0 * ustrip(u"inch^4", Is))
    
    return βt
end

"""
    aci_ddm_longitudinal_with_edge_beam(βt) -> NamedTuple

ACI 318-11 §13.6.3.3 longitudinal distribution coefficients,
interpolated for edge beam stiffness ratio β_t.

Interpolates linearly between:
- β_t = 0 (no edge beam): ext_neg=0.26, pos=0.52, int_neg=0.70
- β_t ≥ 2.5 (full edge beam): ext_neg=0.30, pos=0.50, int_neg=0.70

# Reference
- ACI 318-11 §13.6.3.3, Columns (3) and (4)
"""
function aci_ddm_longitudinal_with_edge_beam(βt::Float64)
    t = clamp(βt / 2.5, 0.0, 1.0)  # interpolation parameter [0,1]
    
    ext_neg = 0.26 + t * (0.30 - 0.26)  # 0.26 → 0.30
    pos     = 0.52 + t * (0.50 - 0.52)  # 0.52 → 0.50
    int_neg = 0.70                        # unchanged
    
    return (ext_neg=ext_neg, pos=pos, int_neg=int_neg)
end

"""
    aci_col_strip_ext_neg_fraction(βt)

ACI 318-11 §13.6.4.2 — Column strip fraction of exterior negative moment.

Interpolates linearly between:
- β_t = 0: 100% to column strip
- β_t ≥ 2.5: 75% to column strip

# Reference
- ACI 318-11 §13.6.4.2 (for l₂/l₁ = 1.0, αf = 0)
"""
function aci_col_strip_ext_neg_fraction(βt::Float64)
    t = clamp(βt / 2.5, 0.0, 1.0)
    return 1.00 - t * (1.00 - 0.75)  # 1.00 → 0.75
end

"""
ACI 318-11 §13.6.4.4 — Column strip positive moment.
For flat plates (αf = 0), constant at 60% regardless of l₂/l₁.
"""
function aci_col_strip_positive(l2_l1::Float64)
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

Distribute moments using full ACI 318-11 DDM procedure (§13.6.3–13.6.6).

# Arguments
- `M0`: Total static moment
- `span_type`: :end_span or :interior_span
- `l2_l1`: Ratio of panel width to span length
- `edge_beam`: Whether exterior edge has a beam (affects βt)

# Returns
Named tuple with distributed moments to column and middle strips.
"""
function distribute_moments_aci(M0, span_type::Symbol, l2_l1::Float64;
                                edge_beam::Bool=false, βt::Float64=0.0)
    # When edge_beam=true but no explicit βt provided, use the threshold value
    if edge_beam && βt ≈ 0.0
        βt = 2.5  # ACI table threshold for "with edge beam"
    end
    
    if span_type == :end_span
        # Step 1: Longitudinal distribution (Table 8.10.4.2)
        # With edge beam: interpolate coefficients based on βt
        if βt > 0.0
            long_coeffs = aci_ddm_longitudinal_with_edge_beam(βt)
            M_ext_neg = long_coeffs.ext_neg * M0
            M_pos = long_coeffs.pos * M0
            M_int_neg = long_coeffs.int_neg * M0
        else
            M_ext_neg = ACI_DDM_LONGITUDINAL.end_span.ext_neg * M0
            M_pos = ACI_DDM_LONGITUDINAL.end_span.pos * M0
            M_int_neg = ACI_DDM_LONGITUDINAL.end_span.int_neg * M0
        end
        
        # Step 2: Transverse distribution to column strip
        # Interior negative: Table 8.10.5.1 (75% for αf=0)
        cs_int_neg = ACI_COL_STRIP_INT_NEG * M_int_neg
        
        # Exterior negative: Table 8.10.5.2 — interpolated with βt
        cs_ext_neg_frac = aci_col_strip_ext_neg_fraction(βt)
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
        # Interior span — edge beam doesn't affect interior span coefficients
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
# Phase 4: Equivalent Frame Method (EFM) - ACI 318-11 §13.7
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
- ACI 318-11 §13.7.3
- StructurePoint Example: l2=168 in, h=7 in → Is = 4,802 in⁴
"""
function slab_moment_of_inertia(l2::Length, h::Length)
    return l2 * h^3 / 12
end

"""
    column_moment_of_inertia(c1, c2; shape=:rectangular)

Gross moment of inertia for column section.

- Rectangular/square: Iᶜ = c₁ × c₂³ / 12
- Circular: Iᶜ = π D⁴ / 64  (c1 = c2 = D)

# Arguments  
- `c1`: Column dimension in span direction (diameter D for circular)
- `c2`: Column dimension perpendicular to span (diameter D for circular)
- `shape`: Column shape — `:rectangular` or `:circular`

# Returns
Moment of inertia (Length⁴)

# Reference
- ACI 318-11 §13.7.4
- StructurePoint Example: c1=c2=16 in → Ic = 5,461 in⁴
"""
function column_moment_of_inertia(c1::Length, c2::Length; shape::Symbol=:rectangular)
    if shape == :circular
        return circular_column_Ic(c1)
    else
        return c1 * c2^3 / 12
    end
end

"""
    torsional_constant_C(x, y)

Cross-sectional constant C for torsional member per ACI 318-11 Eq. (13-6).

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
- ACI 318-11 Eq. (13-6)
- StructurePoint Example: x=7 in, y=16 in → C = 1,325 in⁴
"""
function torsional_constant_C(x::Length, y::Length)
    # Ensure x ≤ y for the formula (ACI convention)
    x_short = min(x, y)
    y_long = max(x, y)
    
    # ACI 318-11 Eq. (13-6): C = (1 - 0.63x/y) × x³y/3
    # Ratio is dimensionless, so units work out to Length⁴
    return (1 - 0.63 * (x_short / y_long)) * (x_short^3 * y_long / 3)
end

"""
    slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor)

Flexural stiffness of slab-beam at both ends per ACI 318-11 §13.7.3.

    Kₛᵦ = k × Eᶜₛ × Iₛ / l₁

The stiffness factor k accounts for the non-prismatic section:
- Enhanced moment of inertia at column region: Is / (1 - c2/l2)²
- Obtain k from `pca_slab_beam_factors(c1, l1, c2, l2).k`

# Arguments
- `Ecs`: Modulus of elasticity of slab concrete
- `Is`: Gross moment of inertia of slab (from slab_moment_of_inertia)
- `l1`: Span length center-to-center of columns
- `c1`: Column dimension in span direction
- `c2`: Column dimension perpendicular to span
- `k_factor`: Stiffness factor from PCA Table A1 (via `pca_slab_beam_factors`)

# Returns
Slab-beam stiffness Ksb (Moment units, e.g., in-lb)

# Reference
- ACI 318-11 §13.7.3
- PCA Notes on ACI 318-11 Table A1
"""
function slab_beam_stiffness_Ksb(
    Ecs::Pressure,
    Is::SecondMomentOfArea,
    l1::Length,
    c1::Length,
    c2::Length;
    k_factor::Float64
)
    # Ksb = k × Ec × Is / l1 — units: (lbf/in²) × in⁴ / in = lbf*in = Moment
    Ec = ustrip(u"psi", Ecs)
    I = ustrip(u"inch^4", Is)
    l1val = ustrip(u"inch", l1)
    return k_factor * Ec * I / l1val * u"lbf*inch"
end

"""
    column_stiffness_Kc(Ecc, Ic, H, h; k_factor)

Flexural stiffness of column at slab-beam joint per ACI 318-11 §13.7.4.

    Kᶜ = k × Eᶜᶜ × Iᶜ / H

The stiffness factor k accounts for:
- Infinite moment of inertia within the slab depth (joint region)
- Column clear height Hc = H - h
- Obtain k from `pca_column_factors(H, h).k`

# Arguments
- `Ecc`: Modulus of elasticity of column concrete
- `Ic`: Gross moment of inertia of column (from column_moment_of_inertia)
- `H`: Story height (floor-to-floor)
- `h`: Slab thickness
- `k_factor`: Stiffness factor from PCA Table A7 (via `pca_column_factors`)

# Returns
Column stiffness Kc (Moment units, e.g., in-lb)

# Reference
- ACI 318-11 §13.7.4
- PCA Notes on ACI 318-11 Table A7
"""
function column_stiffness_Kc(
    Ecc::Pressure,
    Ic::SecondMomentOfArea,
    H::Length,
    h::Length;
    k_factor::Float64
)
    # Kc = k × Ec × Ic / H — units: (lbf/in²) × in⁴ / in = lbf*in = Moment
    Ec = ustrip(u"psi", Ecc)
    I = ustrip(u"inch^4", Ic)
    Hval = ustrip(u"inch", H)
    return k_factor * Ec * I / Hval * u"lbf*inch"
end

"""
    torsional_member_stiffness_Kt(Ecs, C, l2, c2)

Torsional stiffness of transverse slab strip per ACI 318-11 R13.7.5.

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
- ACI 318-11 R13.7.5
- StructurePoint Example: Ecs=3,834×10³ psi, C=1,325 in⁴, l2=168 in, c2=16 in
  → Kt = 9 × 3,834×10³ × 1,325 / (168 × (1 - 16/168)³) = 367,484,240 in-lb
"""
function torsional_member_stiffness_Kt(Ecs::Pressure, C::TorsionalConstant, l2::Length, c2::Length)
    # ACI 318-11 R13.7.5: Kt = 9 × Ec × C / (l2 × (1 - c2/l2)³)
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
- ACI 318-11 §13.7.5 (series combination of column + torsional stiffness)
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

# carryover_factor_COF removed — COF is now returned by pca_slab_beam_factors()
# and stored per-span in EFMSpanProperties.COF.

"""
    fixed_end_moment_FEM(qu, l2, l1; m_factor)

Fixed-end moment for uniformly loaded non-prismatic slab-beam.

    FEM = m × qᵤ × l₂ × l₁²

# Arguments
- `qu`: Factored uniform load (pressure)
- `l2`: Panel width perpendicular to span
- `l1`: Span length center-to-center
- `m_factor`: FEM factor from PCA Table A1 (via `pca_slab_beam_factors`)

# Returns
Fixed-end moment FEM (moment units)

# Reference
- PCA Notes on ACI 318-11 Table A1
"""
function fixed_end_moment_FEM(qu::Pressure, l2::Length, l1::Length; m_factor::Float64)
    return m_factor * qu * l2 * l1^2
end

"""
    face_of_support_moment(M_centerline, V, c, l1)

Reduce centerline moment to face-of-support for design per ACI 318-11 §13.7.7.1.

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
- ACI 318-11 §13.7.7.1
- StructurePoint Example: M_cl = 83.91 kip-ft, V = 26.39 kip, c = 16/12 ft
  → M_face = 83.91 - 26.39 × (16/12/2) = 66.32 ft-kip
  
# Note
The 0.175×l1 limit ensures the design moment is taken at a reasonable
distance from the column center for very large columns.
"""
function face_of_support_moment(M_centerline, V, c::Length, l1::Length)
    # Distance to face of support
    d_face = c / 2
    
    # Maximum distance for moment reduction (ACI 318-11 §13.7.7.1)
    d_max = 0.175 * l1
    
    # Use smaller of face distance or max distance
    d_use = min(d_face, d_max)
    
    # Reduce moment by V × d
    M_face = M_centerline - V * d_use
    
    return M_face
end

# =============================================================================
# Phase 5: Reinforcement Design (ACI 318-11 §13.3, §10.5)

"""
    minimum_reinforcement(b, h, fy)

Minimum reinforcement per ACI 318-11 §13.3.1 / §7.12.2.1 for shrinkage and temperature.

# Minimum Ratios (ACI 318-11 §7.12.2.1)
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
- ACI 318-11 §13.3.1, §7.12.2.1
- StructurePoint Example: fy=60ksi → As_min = 0.0018 × b × h
"""
function minimum_reinforcement(b::Length, h::Length, fy::Pressure)
    # ACI 318-11 §7.12.2.1 thresholds
    # Round to nearest psi to avoid Asap ksi ↔ Unitful psi conversion gap
    fy_psi = round(Int, ustrip(u"psi", fy))
    
    ρ_min = if fy_psi < 60_000      # fy < 60 ksi (Grade 40/50)
        0.0020
    elseif fy_psi < 77_000          # 60 ksi ≤ fy < 77 ksi (Grade 60)
        0.0018
    else                            # fy ≥ 77 ksi (Grade 80+)
        max(0.0014, 0.0018 * 60_000 / fy_psi)
    end
    
    return ρ_min * b * h
end


"""
    effective_depth(h; cover=0.75u"inch", bar_diameter=0.5u"inch", two_way=true)

Effective depth for slab reinforcement design.

For **two-way** slabs (default), bars run in both directions — the second layer
sits below the first, so each direction has a different d:

    d₁ = h − cover − db/2        (top layer)
    d₂ = h − cover − 3·db/2      (bottom layer)
    d_avg = (d₁ + d₂)/2 = h − cover − db

ACI R22.6.1 and StructurePoint both use d_avg for two-way design (moments,
punching shear, deflection).

For **one-way** slabs (`two_way=false`), only one bar layer:

    d = h − cover − db/2

# Arguments
- `h`: Total slab thickness
- `cover`: Clear cover to reinforcement (default 0.75" per ACI Table 20.6.1.3.1)
- `bar_diameter`: Assumed bar diameter (default #4 = 0.5")
- `two_way`: Use average depth for two orthogonal bar layers (default `true`)

# Reference
- ACI 318-11 R11.11.1: "d shall be the average of the effective depths in the
  two orthogonal directions"
- StructurePoint Example: d_avg = 5.75 in (h=7", cover=0.75", #4 bars)
"""
function effective_depth(h::Length; cover=0.75u"inch", bar_diameter=0.5u"inch", two_way=true)
    if two_way
        # d_avg = h − cover − db  (average of both bar layers)
        return h - cover - bar_diameter
    else
        # d = h − cover − db/2  (single bar layer)
        return h - cover - bar_diameter / 2
    end
end

"""
    max_bar_spacing(h)

Maximum bar spacing per ACI 318-11 §13.3.2.

    s_max = min(2h, 18 in)

# Reference
- ACI 318-11 §13.3.2
"""
function max_bar_spacing(h::Length)
    # ACI 318-11 §13.3.2: s_max = min(2h, 18")
    return min(2 * h, 18.0u"inch")
end


# ─────────────────────────────────────────────────────────────────────────────
# Phase 6 (Punching / Shear / Moment-Transfer): MOVED to codes/aci/punching.jl
# All punching geometry, capacity, demand, gamma_f/v, Jc, combined stress,
# one-way shear, effective_slab_width, and punching_check functions are now
# shared between slabs and foundations via the shared ACI module.
# ─────────────────────────────────────────────────────────────────────────────


# =============================================================================
# Phase 6d+: Shear Stud Design (ACI 318-11 §11.11.5 / Ancon Shearfix)
# =============================================================================

"""
    punching_capacity_with_studs(fc, β, αs, b0, d, Av, s, fyt; λ=1.0)

Punching shear capacity with headed shear stud reinforcement per ACI 318-11 §11.11.5.

# Three Failure Modes Checked:
1. Nominal capacity limit (vc_max = 8√f'c, §11.11.3.2)
2. Combined concrete + steel within studs (vcs + vs)
3. Outer critical section (checked separately)

# Formulas (ACI 318-11, US customary psi):
- vcs = min(4λ√f'c, (2+4/β)λ√f'c, (αs d/b0+2)λ√f'c, 3λ√f'c)  §11.11.5.1
- vs  = Av × fyt / (b0 × s)
- vc_max = 8λ√f'c  (headed studs, §11.11.3.2)

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
    b0_in = ustrip(u"inch", b0)
    d_in = ustrip(u"inch", d)
    s_in = ustrip(u"inch", s)
    Av_in2 = ustrip(u"inch^2", Av)
    fyt_psi = ustrip(u"psi", fyt)
    
    # ACI 318-11 §11.11.5.1: Vc with studs ≤ 3λ√f'c × b0 × d
    # Compute vc from §11.11.2.1, then cap at 3λ√f'c
    vc_a = (2 + 4 / β) * λ * sqrt_fc               # Eq. (11-31)
    vc_b = (αs * d_in / b0_in + 2) * λ * sqrt_fc   # Eq. (11-32)
    vc_c = 4 * λ * sqrt_fc                          # Eq. (11-33)
    vcs = min(min(vc_a, vc_b, vc_c), 3.0 * λ * sqrt_fc)
    
    # Steel contribution: vs = Av × fyt / (b0 × s)
    vs = s_in > 0 ? Av_in2 * fyt_psi / (b0_in * s_in) : 0.0
    
    # Nominal capacity limit for headed studs (ACI 318-11 §11.11.3.2)
    # Vn ≤ 8√f'c × b0 × d
    vc_max = 8.0 * λ * sqrt_fc
    
    # Combined capacity (but limited by nominal cap)
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

Punching capacity at outer critical section (beyond shear studs).

    vc,out = 2λ√f'c  (psi)

At d/2 beyond the outermost peripheral line of studs, the concrete is
unreinforced. ACI 318-11 §11.11.5.4 requires vu ≤ φ × 2λ√f'c at this section.

# Reference
- ACI 318-11 §11.11.5.4
"""
function punching_capacity_outer(fc::Pressure, d::Length; λ::Float64 = 1.0)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    vc_out = 2.0 * λ * sqrt_fc
    return vc_out * u"psi"
end

"""
    minimum_stud_reinforcement(fc, b0, fyt)

Minimum shear stud reinforcement per ACI 318-11 §11.11.5.1:

    Av × fyt / (b0 × s) ≥ 2√f'c   →   Av/s ≥ 2√f'c × b0 / fyt

# Returns
Minimum Av/s ratio (Area/Length)

# Reference
- ACI 318-11 §11.11.5.1
"""
function minimum_stud_reinforcement(fc::Pressure, b0::Length, fyt::Pressure)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    b0_in = ustrip(u"inch", b0)
    fyt_psi = ustrip(u"psi", fyt)
    
    # ACI 318-11 §11.11.5.1: Av*fyt/(b0*s) ≥ 2√f'c
    Av_s_min = 2.0 * sqrt_fc * b0_in / fyt_psi
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
    design_shear_studs(vu, fc, β, αs, b0, d, position, fyt, stud_diameter; λ, φ, c1, c2, qu, catalog)

Design headed shear stud reinforcement for a punching shear failure.

# Design Steps (ACI 318-11 §11.11.5 / INCON ISS):
1. Compute required vs = vu/φ − vcs
2. Select number of rails based on position (8 interior, 6 edge, 4 corner)
3. Determine Av per line from n_rails × stud_area
4. Compute spacing s = Av × fyt / (b0 × vs)
5. Apply detailing limits (s ≤ 0.75d or 0.5d if high stress, §11.11.5.2)
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
- `stud_diameter`: Stud diameter (target; snapped to catalog if provided)
- `c1`, `c2`: Column dimensions (for outer section geometry; optional)
- `qu`: Factored uniform pressure (for outer section Vu reduction; optional)
- `catalog`: Stud catalog vector (`Vector{StudSpec}`). When provided, the stud
  is snapped to the nearest catalog product and its actual shank area is used
  instead of the generic π d²/4 formula. Pass `nothing` for generic studs.

When `c1`, `c2`, and `qu` are provided, the outer section check uses the
exact ACI approach: Vu_outer = Vu_total − qu × A_enclosed.
Otherwise falls back to the perimeter-ratio approximation.

# Returns
ShearStudDesign struct with complete stud layout

# Reference
- ACI 318-11 §11.11.3.2, §11.11.5
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
    φ::Float64 = 0.75,
    c1::Union{Length, Nothing} = nothing,
    c2::Union{Length, Nothing} = nothing,
    qu::Union{Pressure, Nothing} = nothing,
    catalog::Union{Vector{StudSpec}, Nothing} = nothing
)
    d_in = ustrip(u"inch", d)
    b0_in = ustrip(u"inch", b0)
    vu_psi = ustrip(u"psi", vu)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    fyt_psi = ustrip(u"psi", fyt)
    
    # Convert fyt to psi for consistent units in ShearStudDesign struct
    fyt_unit = fyt_psi * u"psi"
    
    # ─── Resolve stud from catalog (or use generic π d²/4) ───
    if !isnothing(catalog)
        spec = snap_to_catalog(catalog, stud_diameter)
        catalog_name = spec.catalog
        actual_diameter = spec.shank_diameter
        As_stud = spec.head_area           # shank cross-sectional area from catalog
    else
        catalog_name = :generic
        actual_diameter = stud_diameter
        As_stud = stud_area(stud_diameter)  # π d²/4
    end
    As_stud_in2 = ustrip(u"inch^2", As_stud)
    actual_diameter_unit = uconvert(u"inch", actual_diameter)
    
    # Maximum nominal shear strength with headed studs (ACI 318-11 §11.11.3.2)
    # Vn ≤ 8√f'c × b0 × d
    vc_max = 8.0 * λ * sqrt_fc
    
    # Check if studs can solve the problem
    if vu_psi > φ * vc_max
        # Demand exceeds maximum capacity with studs
        return ShearStudDesign(
            required = true,
            catalog_name = catalog_name,
            stud_diameter = actual_diameter_unit,
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
    
    # ACI 318-11 §11.11.5.1: Vc with studs ≤ 3λ√f'c × b0 × d
    # Compute vc from §11.11.2.1, then cap at 3λ√f'c
    vc_a = (2 + 4 / β) * λ * sqrt_fc               # Eq. (11-31)
    vc_b = (αs * d_in / b0_in + 2) * λ * sqrt_fc   # Eq. (11-32)
    vc_c = 4 * λ * sqrt_fc                          # Eq. (11-33)
    vcs = min(min(vc_a, vc_b, vc_c), 3.0 * λ * sqrt_fc)
    
    # Required steel contribution
    vs_reqd = max(vu_psi / φ - vcs, 0.0)
    
    # Number of rails based on position (min 2 per face per ACI 318-11 §11.11.5)
    n_rails = position == :interior ? 8 :
              position == :edge ? 6 : 4
    
    # Total Av per peripheral line
    Av_per_line = n_rails * As_stud_in2
    
    # Required spacing: vs = Av × fyt / (b0 × s) → s = Av × fyt / (b0 × vs)
    if vs_reqd > 0
        s_reqd = Av_per_line * fyt_psi / (b0_in * vs_reqd)
    else
        s_reqd = 0.75 * d_in  # Use max allowed if no steel required
    end
    
    # ACI 318-11 §11.11.5.2: spacing limits based on total factored shear stress
    # (a) s ≤ 0.75d when vu ≤ 6φ√f'c
    # (b) s ≤ 0.5d  when vu > 6φ√f'c
    high_stress = vu_psi > 6.0 * φ * sqrt_fc
    s_max = high_stress ? 0.5 * d_in : 0.75 * d_in
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
    
    # Outer perimeter geometry — position-aware (ACI 318-11 §11.11.5.4)
    # Total offset from column face to outer critical section
    total_offset_in = outer_perimeter_dist  # s0 + (n-1)*s + d/2
    
    if !isnothing(c1) && !isnothing(c2) && !isnothing(qu)
        # ─── Exact ACI approach (R22.6.4.1) ───
        # Compute outer perimeter and enclosed area from actual geometry
        c1_in = ustrip(u"inch", c1)
        c2_in_col = ustrip(u"inch", c2)
        
        if position == :interior
            # 4-sided: rectangle (c1 + 2×offset) × (c2 + 2×offset)
            b1_out = c1_in + 2 * total_offset_in
            b2_out = c2_in_col + 2 * total_offset_in
            b0_out = 2 * b1_out + 2 * b2_out
            A_enclosed_in2 = b1_out * b2_out
        elseif position == :edge
            # 3-sided: slab edge clips one side of c1
            b1_out = c1_in / 2 + total_offset_in
            b2_out = c2_in_col + 2 * total_offset_in
            b0_out = 2 * b1_out + b2_out
            A_enclosed_in2 = b1_out * b2_out
        else  # :corner
            # 2-sided: two slab edges clip
            b1_out = c1_in / 2 + total_offset_in
            b2_out = c2_in_col / 2 + total_offset_in
            b0_out = b1_out + b2_out
            A_enclosed_in2 = b1_out * b2_out
        end
        
        # Vu at outer section = Vu_total - qu × A_enclosed
        Vu_total_psi_in = vu_psi * b0_in * d_in  # total shear force (psi × in × in = lb)
        qu_psi = ustrip(u"psi", qu)               # psf → psi via Unitful
        load_in_zone = qu_psi * A_enclosed_in2     # lb of load inside outer perimeter
        Vu_outer_lb = max(Vu_total_psi_in - load_in_zone, 0.0)
        vu_out_psi = Vu_outer_lb / (b0_out * d_in)
    else
        # ─── Fallback: perimeter-ratio approximation ───
        # Expand all sides uniformly (conservative for edge/corner)
        n_sides = position == :interior ? 8 :
                  position == :edge ? 6 : 4
        b0_out = b0_in + n_sides * total_offset_in
        vu_out_psi = vu_psi * b0_in / b0_out
    end
    
    # Outer section check
    outer_ok = φ * vc_out_psi >= vu_out_psi
    
    return ShearStudDesign(
        required = true,
        catalog_name = catalog_name,
        stud_diameter = actual_diameter_unit,
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
NamedTuple (ok, ratio, message)
"""
function check_punching_with_studs(vu::Pressure, studs::ShearStudDesign; φ::Float64 = 0.75)
    if !studs.required || studs.n_rails == 0
        return (ok=false, ratio=Inf, message="Studs not designed or inadequate")
    end
    
    vu_psi = ustrip(u"psi", vu)
    vcs_psi = ustrip(u"psi", studs.vcs)
    vs_psi = ustrip(u"psi", studs.vs)
    vc_max_psi = ustrip(u"psi", studs.vc_max)
    
    # Combined capacity
    vc_total = min(vcs_psi + vs_psi, vc_max_psi)
    
    ratio = vu_psi / (φ * vc_total)
    ok = ratio <= 1.0 && studs.outer_ok
    
    msg = if ok
        "OK (with studs): vu/φvc = $(round(ratio, digits=3))"
    elseif !studs.outer_ok
        "NG: Outer section fails - extend stud zone"
    else
        "NG (with studs): vu/φvc = $(round(ratio, digits=3)) > 1.0"
    end
    
    return (ok=ok, ratio=ratio, message=msg)
end

# =============================================================================
# Phase 6e: Moment Transfer Reinforcement (ACI 318-11 §13.5.3)
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
- ACI 318-11 §13.5.3
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
# Phase 6b: Structural Integrity Reinforcement (ACI 318-11 §13.3.8.5)
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

Calculate required structural integrity reinforcement per ACI 318-11 §13.3.8.5.

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
- ACI 318-11 §13.3.8.5: Two-way slab structural integrity
- ACI 318-11 R13.3.8: Commentary on progressive collapse resistance
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


"""
    load_distribution_factor(strip::Symbol, position::Symbol)

Load distribution factor (LDF) for column or middle strip.

Per ACI 318-11 §13.6.4, the negative and positive moments are distributed
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
    # Column strip distribution percentages from ACI 318-11 §13.6.4:
    # - Exterior negative: 100% (no edge beam)
    # - Positive: 60%
    # - Interior negative: 75%
    
    # The LDF formula weights the positive region double since it spans the middle:
    # LDFc = (2×LDF⁺ + LDF⁻_L + LDF⁻_R) / 4
    # Reference: PCA Notes on ACI 318-11, Section 9.5.3.4
    
    if position == :exterior
        # End span: 
        # ACI 318-11 §13.6.4: LDF⁺ = 0.60, LDF⁻_ext = 1.00, LDF⁻_int = 0.75
        # LDFc = (2×0.60 + 1.00 + 0.75) / 4 = 2.95/4 = 0.7375 ≈ 0.738
        LDF_c = (2 * 0.60 + 1.00 + 0.75) / 4
    else
        # Interior span:
        # ACI 318-11 §13.6.4: LDF⁺ = 0.60, LDF⁻ = 0.75 both sides
        # LDFc = (2×0.60 + 0.75 + 0.75) / 4 = 2.70/4 = 0.675
        LDF_c = (2 * 0.60 + 0.75 + 0.75) / 4
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
- ACI 318-11 §10.3.6 (nominal axial strength)
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


# =============================================================================
# Flat Slab (Drop Panel) Calculations — ACI 318-11
# =============================================================================


"""
    slab_self_weight_with_drop(h_slab, drop::DropPanelGeometry, ρ) -> (w_slab, w_drop)

Compute self-weight pressures for flat slab with drop panels.

Returns two pressures:
- `w_slab`: Self-weight of slab alone (applied everywhere)
- `w_drop`: *Additional* self-weight from drop panel projection (applied on drop zone only)

The caller applies w_slab as a uniform load on the full span, and w_drop
as a patch load on the drop panel zone.

# Arguments
- `h_slab`: Slab thickness (constant portion)
- `drop`: Drop panel geometry
- `ρ`: Concrete mass density

# Reference
- StructurePoint DE-Two-Way-Flat-Slab:
    w_slab = 150 pcf × 10"/12 = 125.00 psf
    w_drop = 150 pcf × 4.25"/12 = 53.13 psf (additional from drop panel)
"""
function slab_self_weight_with_drop(h_slab::Length, drop::DropPanelGeometry, ρ)
    w_slab = uconvert(psf, h_slab * ρ * GRAVITY)
    w_drop = uconvert(psf, drop.h_drop * ρ * GRAVITY)
    return (w_slab, w_drop)
end

"""
    drop_panel_concrete_volume(dp::DropPanelGeometry, a1_eff, a2_eff) -> Volume

Additional concrete volume from one drop panel (the projection below slab soffit).
`a1_eff` and `a2_eff` are the *full* plan extents after trimming to the slab boundary.
Volume = a1_eff × a2_eff × h_drop.
"""
function drop_panel_concrete_volume(dp::DropPanelGeometry, a1_eff, a2_eff)
    dp.h_drop <= zero(dp.h_drop) && return zero(a1_eff * a2_eff * dp.h_drop)
    return a1_eff * a2_eff * dp.h_drop
end

"""
    DropSectionProperties

Composite section properties at the drop panel (support) location.

# Fields
- `Ig::SecondMomentOfArea`: Gross moment of inertia about composite centroid
- `yt::Length`: Distance from centroid to extreme tension fiber
- `A_total::Area`: Total cross-sectional area (slab + drop)
- `y_bar::Length`: Centroid location measured from bottom of drop panel
- `h_total::Length`: Total depth at drop (h_slab + h_drop)
"""
struct DropSectionProperties{I<:SecondMomentOfArea, L<:Length, A<:Area}
    Ig::I
    yt::L
    A_total::A
    y_bar::L
    h_total::L
end

"""
    gross_section_at_drop(l2, h_slab, drop::DropPanelGeometry) -> DropSectionProperties

Gross moment of inertia and neutral axis depth for the non-prismatic section
at the drop panel (support) location.

The composite section is:
- Full-width slab strip: l2 × h_slab (top)
- Drop panel: (2 × a_drop_2) × h_drop (bottom, centered under slab)

Returns a `DropSectionProperties` with Ig about the composite centroid and yt
(distance from centroid to extreme tension fiber).

# Reference
- StructurePoint DE-Two-Way-Flat-Slab:
    h_total = 14.25 in., yt = 5.88 in., Ig = 53,445 in⁴
"""
function gross_section_at_drop(l2::Length, h_slab::Length, drop::DropPanelGeometry)
    # Total depth at drop = h_slab + h_drop
    h_total = h_slab + drop.h_drop
    
    # Width of drop panel strip (perpendicular to span)
    b_drop = drop_extent_2(drop)  # = 2 × a_drop_2
    
    # Slab strip: l2 × h_slab, centroid at h_total - h_slab/2 from bottom
    A_slab = l2 * h_slab
    y_slab = h_total - h_slab / 2   # from bottom of drop panel
    
    # Drop panel: b_drop × h_drop, centroid at h_drop/2 from bottom
    A_drop = b_drop * drop.h_drop
    y_drop = drop.h_drop / 2   # from bottom of drop panel
    
    # Composite centroid
    A_total = A_slab + A_drop
    y_bar = (A_slab * y_slab + A_drop * y_drop) / A_total
    
    # Parallel axis theorem for Ig about composite centroid
    Ig_slab = l2 * h_slab^3 / 12 + A_slab * (y_slab - y_bar)^2
    Ig_drop = b_drop * drop.h_drop^3 / 12 + A_drop * (y_drop - y_bar)^2
    Ig = Ig_slab + Ig_drop
    
    # Distance from centroid to tension face
    # For negative bending (hogging), tension is on top → yt = h_total - y_bar
    # For positive bending, tension is on bottom → yt = y_bar
    # Use the larger (more conservative for Mcr):
    yt = max(y_bar, h_total - y_bar)
    
    return DropSectionProperties(Ig, yt, A_total, y_bar, h_total)
end

"""
    weighted_slab_thickness(h_slab, drop::DropPanelGeometry, l_strip) -> Length

Weighted average thickness across a strip for minimum reinforcement calculations.

Per StructurePoint procedure, the weighted thickness accounts for the
variable depth across the column strip:

    h_w = (h_total × a_drop + h_slab × (l_strip/2 - a_drop)) / (l_strip/2)

Where:
- h_total = h_slab + h_drop
- a_drop = drop panel half-extent in the strip direction
- l_strip = strip total width

# Reference
- StructurePoint DE-Two-Way-Flat-Slab:
    h_w = (14.25 × 10/2 + 10 × (15 - 10/2)) / 15 = 12.83 in.
"""
function weighted_slab_thickness(h_slab::Length, drop::DropPanelGeometry, l_strip::Length)
    h_total = h_slab + drop.h_drop
    a = drop.a_drop_2  # half-extent (use direction 2 for column strip width direction)
    half_strip = l_strip / 2
    
    # Clamp a to half-strip (drop can't be wider than strip)
    a_eff = min(a, half_strip)
    
    # Weighted average
    h_w = (h_total * a_eff + h_slab * (half_strip - a_eff)) / half_strip
    return h_w
end

"""
    fixed_end_moment_FEM(qu_slab, qu_drop, l2, l1, c1, c2, h_slab, drop::DropPanelGeometry)

Fixed-end moment for non-prismatic slab-beam with drop panels using
PCA Tables A2–A5 FEM coefficients (geometry-dependent).

    FEM = m_uniform × w_slab × l₂ × l₁²
        + m_near × w_drop × b_drop × l₁²
        + m_far  × w_drop × b_drop × l₁²

Where the three m coefficients are interpolated from PCA Tables A2–A5
based on c₁/l₁, c₂/l₂, and h_drop/h_slab.

# Arguments
- `qu_slab`: Factored uniform slab load (pressure)
- `qu_drop`: Factored additional drop panel load (pressure) — weight of projection only
- `l2`: Panel width perpendicular to span
- `l1`: Span length center-to-center
- `c1`: Column dimension parallel to span
- `c2`: Column dimension perpendicular to span
- `h_slab`: Slab thickness
- `drop`: Drop panel geometry

# Reference
- PCA Notes on ACI 318-11, Tables A2–A5
- StructurePoint DE-Two-Way-Flat-Slab:
    FEM = 0.0915 × 0.270 × 30 × 30² + 0.0163 × 0.064 × 10 × 30² + 0.002 × 0.064 × 10 × 30²
        = 677.53 ft-kips
"""
function fixed_end_moment_FEM(
    qu_slab::Pressure,
    qu_drop::Pressure,
    l2::Length,
    l1::Length,
    c1::Length,
    c2::Length,
    h_slab::Length,
    drop::DropPanelGeometry,
)
    # Look up geometry-dependent FEM coefficients from PCA Tables A2–A5
    mc = pca_np_fem_coefficients(c1, l1, c2, l2, drop.h_drop, h_slab, drop.a_drop_1)

    # Drop panel extent (full width in direction 1 for the patch load)
    b_drop = drop_extent_1(drop)  # 2 × a_drop_1

    # Term 1: Uniform slab load on full span
    FEM_slab = mc.m_uniform * qu_slab * l2 * l1^2
    
    # Term 2: Drop panel patch load at near column
    FEM_near = mc.m_near * qu_drop * b_drop * l1^2
    
    # Term 3: Drop panel patch load at far column
    FEM_far = mc.m_far * qu_drop * b_drop * l1^2
    
    return FEM_slab + FEM_near + FEM_far
end

"""
    column_stiffness_Kc(Ecc, Ic, H, h_slab, drop::DropPanelGeometry;
                         position=:bottom)

Column stiffness for flat slab accounting for asymmetric joint depth.

With drop panels, the column clear height and joint depths differ for
columns above and below the slab:
- Bottom column: ta = h_slab/2 + h_drop, tb = h_slab/2
- Top column: ta = h_slab/2, tb = h_slab/2 + h_drop (reversed)

The PCA Table A7 k-factor changes because ta/tb ≠ 1.

# Arguments
- `Ecc`: Column concrete modulus
- `Ic`: Column moment of inertia
- `H`: Story height (floor-to-floor)
- `h_slab`: Slab thickness
- `drop`: Drop panel geometry
- `position`: `:bottom` or `:top` column at the joint

# Reference
- PCA Notes on ACI 318-11, Table A7
- StructurePoint DE-Two-Way-Flat-Slab:
    Bottom: ta=9.25", tb=5.00", k=5.318 → Kc = 2,134,472,479 in-lb
    Top:    ta=5.00", tb=9.25", k=4.879 → Kc = 1,958,272,137 in-lb
"""
function column_stiffness_Kc(
    Ecc::Pressure,
    Ic::SecondMomentOfArea,
    H::Length,
    h_slab::Length,
    drop::DropPanelGeometry;
    position::Symbol = :bottom,
)
    # Compute ta and tb from geometry (PCA Notes, Table A7)
    # Bottom column: top end at slab soffit → ta = h_slab/2 + h_drop
    # Bottom column: bottom end at floor below → tb = h_slab/2
    # Top column: reversed (ta = h_slab/2, tb = h_slab/2 + h_drop)
    if position == :bottom
        ta = h_slab / 2 + drop.h_drop
        tb = h_slab / 2
    else
        ta = h_slab / 2
        tb = h_slab / 2 + drop.h_drop
    end

    # Total joint depth for clear height: Hc = H - (ta + tb) = H - (h_slab + h_drop)
    h_total = h_slab + drop.h_drop
    cf = pca_column_factors(H, h_total; ta=ta, tb=tb)
    k_factor = cf.k

    Ec = ustrip(u"psi", Ecc)
    I = ustrip(u"inch^4", Ic)
    Hval = ustrip(u"inch", H)
    return k_factor * Ec * I / Hval * u"lbf*inch"
end
