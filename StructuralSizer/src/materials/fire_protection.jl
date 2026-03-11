# =============================================================================
# Fire Protection Types
# =============================================================================
#
# Input types (what the user specifies) and output types (what the system
# computes and attaches to sized members).
#
# Fire protection is only applied to steel members — concrete fire resistance
# is handled through minimum cover, thickness, and dimension provisions
# (ACI 216.1-14) and does not require a coating.
#
# Reference:
#   UL X772 — SFRM for steel columns (4-sided, W/D equation)
#   UL N643 — Intumescent coating for steel beams (3-sided, table lookup)
#   AISC Design Guide 19 — Fire Resistance of Structural Steel Framing
# =============================================================================

# =============================================================================
# Input types (user-facing)
# =============================================================================

"""
    FireProtection

Abstract type for fire protection systems applied to steel members.

Subtypes control how SFRM/intumescent thickness is determined:
- `NoFireProtection()` — no coating (fire_rating = 0 or steel not exposed)
- `SFRM(density)` — spray-applied fire-resistive material (UL X772 equation)
- `IntumescentCoating(density)` — thin-film intumescent (UL N643 table)
- `CustomCoating(thickness, density, name)` — user-specified, bypasses calculation
"""
abstract type FireProtection end

"""No fire protection applied."""
struct NoFireProtection <: FireProtection end

"""
    SFRM(density_pcf=15.0)

Spray-Applied Fire Resistive Material (cementitious fireproofing).

Thickness determined by UL X772 equation:
    h = R / (1.05 × (W/D) + 0.61)

where R = fire rating (hr), W = weight (lb/ft), D = heated perimeter (in).

# Fields
- `density_pcf`: Dry density in pcf (default 15.0, standard; 22 or 40 for high-density)
"""
struct SFRM <: FireProtection
    density_pcf::Float64
end
"""Default SFRM with standard 15 pcf density."""
SFRM() = SFRM(15.0)

"""
    IntumescentCoating(density_pcf=6.0)

Thin-film intumescent coating (mastic).

Thickness determined by UL N643 table lookup based on W/D and fire rating.
Much thinner than SFRM (~0.04"–0.25" vs 0.5"–3"+).

# Fields
- `density_pcf`: Dry density in pcf (default 6.0)
"""
struct IntumescentCoating <: FireProtection
    density_pcf::Float64
end
"""Default intumescent coating with 6 pcf density."""
IntumescentCoating() = IntumescentCoating(6.0)

"""
    CustomCoating(thickness_in, density_pcf, name)

User-specified fire protection coating. Bypasses W/D calculations entirely.

# Fields
- `thickness_in`: Coating thickness in inches
- `density_pcf`: Dry density in pcf
- `name`: Display name (e.g., "Isolatek Blaze-Shield II")
"""
struct CustomCoating <: FireProtection
    thickness_in::Float64
    density_pcf::Float64
    name::String
end

# =============================================================================
# Output type (computed result, attached to sized members)
# =============================================================================

"""
    SurfaceCoating

Computed fire protection coating applied to a steel member.

This is the *output* of fire protection sizing — it stores the resolved
thickness, density, and display name after applying the appropriate UL
listing equation or table.

The coating contributes self-weight as a `LineLoad` in the structural
analysis model: `w = thickness × perimeter × density × g`.

# Fields
- `thickness_in`: Coating thickness (inches)
- `density_pcf`: Dry density (pcf)
- `name`: Description (e.g., "SFRM (15 pcf)", "Intumescent")
"""
struct SurfaceCoating
    thickness_in::Float64
    density_pcf::Float64
    name::String
end

"""Weight per unit length of coating on a member [lb/ft]."""
function coating_weight_per_foot(c::SurfaceCoating, perimeter_in::Real)
    # thickness (in) × perimeter (in) → area (in²)
    # area (in²) / 144 → area (ft²)
    # area (ft²) × density (pcf) → weight (lb/ft)
    return c.thickness_in * perimeter_in / 144.0 * c.density_pcf
end

# =============================================================================
# Exposed Surface Area (for EC accounting)
# =============================================================================

"""
    exposed_perimeter(section; exposure::Symbol=:three_sided)

Compute the heated perimeter of a steel section for fire protection volume
and embodied carbon calculations.

For I-sections uses the AISC Design Guide 19 contour perimeters:
- `:three_sided` (beams): `PA` — full perimeter minus one flange (top flange
  against deck).
- `:four_sided` (columns): `PB` — full contour perimeter.

Returns perimeter in meters.
"""
function exposed_perimeter end

"""
    coating_volume(section, coating::SurfaceCoating, L; exposure::Symbol=:three_sided)

Compute the volume (m³) of fire protection coating on a member.

`V = perimeter × thickness × L`

# Arguments
- `section`: Steel section with PA/PB fields
- `coating`: Computed `SurfaceCoating` (from `compute_surface_coating`)
- `L`: Member length (Unitful, e.g. `6.0u"m"`)
- `exposure`: `:three_sided` (beams) or `:four_sided` (columns)
"""
function coating_volume(section, coating::SurfaceCoating, L::Unitful.Length;
                        exposure::Symbol=:three_sided)
    coating.thickness_in ≤ 0 && return 0.0u"m^3"
    P_m = exposed_perimeter(section; exposure=exposure)
    t_m = coating.thickness_in * 0.0254u"m"  # in → m
    return P_m * t_m * uconvert(u"m", L)
end

"""
    coating_mass(section, coating::SurfaceCoating, L; exposure::Symbol=:three_sided)

Compute the mass (kg) of fire protection coating on a member.

Uses the coating's dry density converted from pcf to kg/m³.
"""
function coating_mass(section, coating::SurfaceCoating, L::Unitful.Length;
                      exposure::Symbol=:three_sided)
    vol = coating_volume(section, coating, L; exposure=exposure)
    ρ_kg_m3 = coating.density_pcf * 16.01846u"kg/m^3"  # 1 pcf = 16.01846 kg/m³
    return uconvert(u"kg", vol * ρ_kg_m3)
end

"""
    coating_ec(section, coating::SurfaceCoating, L;
              exposure::Symbol=:three_sided, ecc=0.85)

Compute the embodied carbon (kgCO₂e) of fire protection coating on a member.

Default ECC for SFRM is 0.85 kgCO₂e/kg (cementitious product, CLF baseline).
"""
function coating_ec(section, coating::SurfaceCoating, L::Unitful.Length;
                    exposure::Symbol=:three_sided, ecc::Real=0.85)
    m = coating_mass(section, coating, L; exposure=exposure)
    return ustrip(u"kg", m) * ecc
end

"""Embodied carbon coefficient for SFRM: 0.85 kgCO₂e/kg (CLF baseline for cementitious fireproofing)."""
const ECC_SFRM = 0.85
