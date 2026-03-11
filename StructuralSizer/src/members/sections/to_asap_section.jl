# =============================================================================
# Asap Section Conversion
# =============================================================================
# Generic conversion of StructuralSizer section types to Asap.Section for FEA.

using Unitful
using Asap: Length, Pressure

"""
    to_asap_section(section, material) -> Asap.Section

Convert a StructuralSizer section to an Asap.Section for finite element analysis.

Requires the section to have `A`, `Ix`, `Iy`, `J` properties and the material
to have `E`, `G`, `ρ` properties.

# Examples
```julia
# Steel W-section
w = get_w_section("W10X22")
w.material = A992()
asap_sec = to_asap_section(w)

# With explicit material
asap_sec = to_asap_section(w, A992())

# RC column (uses gross section properties)
rc = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=9, n_bars=8)
asap_sec = to_asap_section(rc, NWC_4000())
```
"""
function to_asap_section end

# -----------------------------------------------------------------------------
# Steel sections with material embedded
# -----------------------------------------------------------------------------

"""Convert steel I-section (W-shapes) to Asap.Section."""
function to_asap_section(sec::ISymmSection)
    mat = sec.material
    isnothing(mat) && throw(ArgumentError("ISymmSection has no material; use to_asap_section(sec, material)"))
    to_asap_section(sec, mat)
end

"""Convert steel I-section with explicit `Metal` material to Asap.Section."""
function to_asap_section(sec::ISymmSection, mat::Metal)
    Asap.Section(
        uconvert(u"m^2", sec.A),
        uconvert(u"Pa", mat.E),
        uconvert(u"Pa", mat.G),
        uconvert(u"m^4", sec.Ix),
        uconvert(u"m^4", sec.Iy),
        uconvert(u"m^4", sec.J),
        uconvert(u"kg/m^3", mat.ρ)
    )
end

"""Convert HSS rectangular section to Asap.Section."""
function to_asap_section(sec::HSSRectSection)
    mat = sec.material
    isnothing(mat) && throw(ArgumentError("HSSRectSection has no material; use to_asap_section(sec, material)"))
    to_asap_section(sec, mat)
end

"""Convert HSS rectangular section with explicit `Metal` material to Asap.Section."""
function to_asap_section(sec::HSSRectSection, mat::Metal)
    Asap.Section(
        uconvert(u"m^2", sec.A),
        uconvert(u"Pa", mat.E),
        uconvert(u"Pa", mat.G),
        uconvert(u"m^4", sec.Ix),
        uconvert(u"m^4", sec.Iy),
        uconvert(u"m^4", sec.J),
        uconvert(u"kg/m^3", mat.ρ)
    )
end

"""Convert HSS round/pipe section to Asap.Section."""
function to_asap_section(sec::HSSRoundSection)
    mat = sec.material
    isnothing(mat) && throw(ArgumentError("HSSRoundSection has no material; use to_asap_section(sec, material)"))
    to_asap_section(sec, mat)
end

"""Convert HSS round/pipe section with explicit `Metal` material to Asap.Section."""
function to_asap_section(sec::HSSRoundSection, mat::Metal)
    # Round sections: Ix = Iy = I, J = 2I
    Asap.Section(
        uconvert(u"m^2", sec.A),
        uconvert(u"Pa", mat.E),
        uconvert(u"Pa", mat.G),
        uconvert(u"m^4", sec.I),
        uconvert(u"m^4", sec.I),
        uconvert(u"m^4", sec.J),
        uconvert(u"kg/m^3", mat.ρ)
    )
end

# -----------------------------------------------------------------------------
# Concrete sections (effective stiffness per ACI 318)
# -----------------------------------------------------------------------------
# 
# For RC sections, we use CONCRETE properties with ACI cracking reduction factors.
# Per ACI 318-11 §10.10.4.1, effective moment of inertia for elastic analysis:
#   - Columns: 0.70 Ig
#   - Beams: 0.35 Ig  
#   - Walls (uncracked): 0.70 Ig
#   - Walls (cracked): 0.35 Ig
#
# The steel reinforcement contribution to STIFFNESS is typically ignored because:
#   1. Steel is 1-4% of area (minor contribution to I)
#   2. ACI cracking factors implicitly account for steel's effect on cracking
#   3. Steel contribution to STRENGTH is handled separately in P-M calculations
#
# Note: For Asap.Section, we need a single E value. We use Ec (concrete modulus)
# with reduced I to approximate the effective stiffness EI_eff = Ec × (factor × Ig).

"""
    to_asap_section(sec::RCColumnSection, mat::Concrete; I_factor=0.70)

Convert RC rectangular column section to Asap.Section for FEA stiffness.

Uses effective section properties per ACI 318-11 §10.10.4.1:
- Area: Gross area Ag (conservative for axial stiffness)
- Moment of inertia: `I_factor × Ig` (default 0.70 for columns)
- Material: Concrete properties (Ec, ρc)

!!! note "Stiffness vs. Strength"
    This provides STIFFNESS properties for elastic frame analysis.
    STRENGTH (P-M capacity) is computed separately using both concrete
    and steel via `pm_curve`, `check_aci_column`, etc.

# Arguments
- `sec`: RCColumnSection with geometry and reinforcement
- `mat`: Concrete material with Ec, fc′, ν, ρ
- `I_factor`: Reduction factor for cracking (default 0.70 per ACI columns)
"""
function to_asap_section(sec::RCColumnSection, mat::Concrete; I_factor::Real=0.70)
    b = ustrip(u"m", sec.b)
    h = ustrip(u"m", sec.h)
    
    # Gross section properties
    A = b * h                    # [m²]
    Ig_x = b * h^3 / 12          # Gross strong axis [m⁴]
    Ig_y = h * b^3 / 12          # Gross weak axis [m⁴]
    
    # Effective moment of inertia (reduced for cracking)
    Ix = I_factor * Ig_x
    Iy = I_factor * Ig_y
    
    # Torsional constant for rectangular section (also reduced)
    a_dim = max(b, h)
    b_dim = min(b, h)
    β = 1/3 - 0.21 * (b_dim/a_dim) * (1 - (b_dim/a_dim)^4 / 12)
    J = I_factor * β * a_dim * b_dim^3  # [m⁴]
    
    # Concrete material properties
    E = mat.E
    ν = mat.ν
    G = E / (2 * (1 + ν))
    ρ = mat.ρ
    
    Asap.Section(A*u"m^2", E, G, Ix*u"m^4", Iy*u"m^4", J*u"m^4", ρ)
end

"""
    to_asap_section(sec::RCCircularSection, mat::Concrete; I_factor=0.70)

Convert RC circular column section to Asap.Section for FEA stiffness.
Uses effective properties per ACI 318-11 §10.10.4.1.
"""
function to_asap_section(sec::RCCircularSection, mat::Concrete; I_factor::Real=0.70)
    D = ustrip(u"m", sec.D)
    r = D / 2
    
    # Gross section properties
    A = π * r^2                  # [m²]
    Ig = π * r^4 / 4             # Gross I [m⁴]
    Jg = π * r^4 / 2             # Gross polar moment [m⁴]
    
    # Effective (reduced for cracking)
    I = I_factor * Ig
    J = I_factor * Jg
    
    # Concrete material
    E = mat.E
    ν = mat.ν
    G = E / (2 * (1 + ν))
    ρ = mat.ρ
    
    Asap.Section(A*u"m^2", E, G, I*u"m^4", I*u"m^4", J*u"m^4", ρ)
end

"""
    to_asap_section(sec::RCBeamSection, mat::Concrete; I_factor=0.35)

Convert RC beam section to Asap.Section for FEA stiffness.
Uses effective properties per ACI 318-11 §10.10.4.1 (default 0.35 for beams).
"""
function to_asap_section(sec::RCBeamSection, mat::Concrete; I_factor::Real=0.35)
    b = ustrip(u"m", sec.b)
    h = ustrip(u"m", sec.h)
    
    # Gross section properties
    A = b * h
    Ig_x = b * h^3 / 12
    Ig_y = h * b^3 / 12
    
    # Effective (reduced for cracking)
    Ix = I_factor * Ig_x
    Iy = I_factor * Ig_y
    
    a_dim = max(b, h)
    b_dim = min(b, h)
    β = 1/3 - 0.21 * (b_dim/a_dim) * (1 - (b_dim/a_dim)^4 / 12)
    J = I_factor * β * a_dim * b_dim^3
    
    E = mat.E
    ν = mat.ν
    G = E / (2 * (1 + ν))
    ρ = mat.ρ
    
    Asap.Section(A*u"m^2", E, G, Ix*u"m^4", Iy*u"m^4", J*u"m^4", ρ)
end

"""
    to_asap_section(sec::RCTBeamSection, mat::Concrete; I_factor=0.35)

Convert RC T-beam section to Asap.Section for FEA stiffness.
Uses T-shaped gross section properties with ACI 318-11 §10.10.4.1 reduction.
"""
function to_asap_section(sec::RCTBeamSection, mat::Concrete; I_factor::Real=0.35)
    bw = ustrip(u"m", sec.bw)
    bf = ustrip(u"m", sec.bf)
    hf = ustrip(u"m", sec.hf)
    h  = ustrip(u"m", sec.h)
    hw = h - hf  # web height below flange

    # Gross T-shape area
    Af = bf * hf
    Aw = bw * hw
    A  = Af + Aw

    # Centroid from top
    ȳ = (Af * hf / 2 + Aw * (hf + hw / 2)) / A

    # Strong-axis Ig (parallel-axis theorem)
    Ig_f = bf * hf^3 / 12 + Af * (ȳ - hf / 2)^2
    Ig_w = bw * hw^3 / 12 + Aw * (hf + hw / 2 - ȳ)^2
    Ig_x = Ig_f + Ig_w

    # Weak-axis Ig (both rectangles centered on web)
    Ig_y = hf * bf^3 / 12 + hw * bw^3 / 12

    # Effective (reduced for cracking)
    Ix = I_factor * Ig_x
    Iy = I_factor * Ig_y

    # Torsional constant (sum-of-rectangles approximation)
    J = I_factor * (bf * hf^3 + hw * bw^3) / 3

    E = mat.E
    ν = mat.ν
    G = E / (2 * (1 + ν))
    ρ = mat.ρ

    Asap.Section(A*u"m^2", E, G, Ix*u"m^4", Iy*u"m^4", J*u"m^4", ρ)
end

# -----------------------------------------------------------------------------
# PixelFrame sections (FRC + external post-tensioning)
# -----------------------------------------------------------------------------

"""
    to_asap_section(sec::PixelFrameSection; I_factor=0.70)

Convert PixelFrame section to Asap.Section for FEA stiffness.

Uses the CompoundSection polygon geometry for area and moments of inertia.
Material properties come from the embedded FiberReinforcedConcrete (delegates
to inner Concrete for E, ν, ρ).

The `I_factor` reduces Ig for cracking (default 0.70, same as RC columns,
since PixelFrame sections are prestressed and have less cracking).

Torsional constant J is approximated as `n_arms × t × L_px³ / 3` (thin
rectangular strips), which is conservative for open cross-sections.
"""
function to_asap_section(sec::PixelFrameSection; I_factor::Real=0.70)
    cs = sec.section  # CompoundSection (mm units, bare Float64)

    # Section properties from polygon geometry [mm → m]
    A_m2  = cs.area * 1e-6              # mm² → m²
    Ix_m4 = I_factor * cs.Ix * 1e-12   # mm⁴ → m⁴
    Iy_m4 = I_factor * cs.Iy * 1e-12   # mm⁴ → m⁴

    # Torsional constant: sum of thin rectangles J ≈ n × (1/3) × t × L³
    # For open thin-walled sections this is the standard approximation
    n = n_arms(sec)
    t_mm = ustrip(u"mm", sec.t)
    L_px_mm = ustrip(u"mm", sec.L_px)
    J_mm4 = n * (t_mm * L_px_mm^3) / 3.0
    J_m4 = I_factor * J_mm4 * 1e-12    # mm⁴ → m⁴

    # Material from embedded FRC → Concrete delegation
    mat = sec.material  # FiberReinforcedConcrete
    E = mat.E           # delegates to Concrete.E (Unitful Pressure)
    ν = mat.ν           # delegates to Concrete.ν (Float64)
    G = E / (2 * (1 + ν))
    ρ = mat.ρ           # delegates to Concrete.ρ (Unitful Density)

    Asap.Section(A_m2 * u"m^2", E, G, Ix_m4 * u"m^4", Iy_m4 * u"m^4", J_m4 * u"m^4", ρ)
end

"""Overload accepting explicit `FiberReinforcedConcrete` material for interface consistency; delegates to the materialless method."""
function to_asap_section(sec::PixelFrameSection, mat::FiberReinforcedConcrete; I_factor::Real=0.70)
    to_asap_section(sec; I_factor=I_factor)
end

"""Overload accepting any `AbstractMaterial` for interface consistency; delegates to the materialless method."""
function to_asap_section(sec::PixelFrameSection, mat::AbstractMaterial; I_factor::Real=0.70)
    to_asap_section(sec; I_factor=I_factor)
end

# -----------------------------------------------------------------------------
# Timber sections
# -----------------------------------------------------------------------------

"""Convert glulam section to Asap.Section."""
function to_asap_section(sec::GlulamSection, mat::Timber)
    b = ustrip(u"m", sec.b)
    d = ustrip(u"m", sec.d)
    
    A = b * d
    Ix = b * d^3 / 12
    Iy = d * b^3 / 12
    
    a_dim = max(b, d)
    b_dim = min(b, d)
    β = 1/3 - 0.21 * (b_dim/a_dim) * (1 - (b_dim/a_dim)^4 / 12)
    J = β * a_dim * b_dim^3
    
    E = mat.E
    G = mat.G
    ρ = mat.ρ
    
    Asap.Section(A*u"m^2", E, G, Ix*u"m^4", Iy*u"m^4", J*u"m^4", ρ)
end

# -----------------------------------------------------------------------------
# Generic fallback for any AbstractSection with required properties
# -----------------------------------------------------------------------------

"""
Generic fallback: convert any section with A, Ix, Iy, J to Asap.Section.
Material must provide E, G, ρ.
"""
function to_asap_section(sec::AbstractSection, mat::AbstractMaterial)
    # Check required section properties
    for prop in (:A, :Ix, :Iy, :J)
        hasproperty(sec, prop) || throw(ArgumentError("Section missing required property: $prop"))
    end
    
    # Get shear modulus (compute from E, ν if G not available)
    G = if hasproperty(mat, :G)
        mat.G
    elseif hasproperty(mat, :ν)
        mat.E / (2 * (1 + mat.ν))
    else
        throw(ArgumentError("Material must have G or ν to compute shear modulus"))
    end
    
    Asap.Section(
        uconvert(u"m^2", sec.A),
        uconvert(u"Pa", mat.E),
        uconvert(u"Pa", G),
        uconvert(u"m^4", sec.Ix),
        uconvert(u"m^4", sec.Iy),
        uconvert(u"m^4", sec.J),
        uconvert(u"kg/m^3", mat.ρ)
    )
end

# -----------------------------------------------------------------------------
# Geometry-only column section (no rebar / no full Concrete material required)
# -----------------------------------------------------------------------------

"""
    column_asap_section(c1, c2, shape, Ec, ν; I_factor=0.70) -> Asap.Section

Build an Asap.Section from raw column geometry and elastic constants.

This is the single source of truth for computing column gross-section
properties (A, Ig, J) with an ACI 318-11 §10.10.4.1 cracking reduction.
Used by FEA slab models and EFM frame models where only cross-section
dimensions and concrete elastic properties are available (no full
`RCColumnSection` or `Concrete` material object).

# Arguments
- `c1`, `c2`: Cross-section dimensions (Length).  For circular columns,
  `c1 = c2 = D`.
- `shape`: `:rectangular` or `:circular`.
- `Ec`: Concrete elastic modulus (Pressure).
- `ν`: Concrete Poisson's ratio (Float64).
- `I_factor`: Cracking reduction factor (default 0.70 per ACI 318-11 §10.10.4.1).
"""
function column_asap_section(
    c1::Length, c2::Length, shape::Symbol,
    Ec::Pressure, ν::Float64;
    I_factor::Float64 = 0.70,
)
    G = Ec / (2 * (1 + ν))

    if shape == :circular
        D = c1
        A  = π * D^2 / 4
        Ix = I_factor * π * D^4 / 64
        Iy = Ix
        J  = Ix + Iy   # polar = 2I for circle
    else
        A  = c1 * c2
        Ix = I_factor * c1 * c2^3 / 12
        Iy = I_factor * c2 * c1^3 / 12
        # Torsional constant (rectangular approximation)
        a = max(c1, c2); b = min(c1, c2)
        β = 1/3 - 0.21 * (b / a) * (1 - (b / a)^4 / 12)
        J  = I_factor * β * a * b^3
    end

    return Asap.Section(
        uconvert(u"m^2", A),
        uconvert(u"Pa", Ec),
        uconvert(u"Pa", G),
        uconvert(u"m^4", Ix),
        uconvert(u"m^4", Iy),
        uconvert(u"m^4", J),
    )
end