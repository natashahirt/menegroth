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

