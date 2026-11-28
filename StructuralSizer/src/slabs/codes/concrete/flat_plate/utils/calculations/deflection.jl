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
    strip_deflection_fixed(Δ_frame_fixed, LDF, Ig_frame, Ig_strip)

Fixed-end deflection for a column or middle strip.

# Formula
    Δstrip,fixed = LDF × Δframe,fixed × (Iframe,g / Istrip,g)

`Δframe,fixed` carries the cracking (it is computed with the frame's
averaged effective I). The ratio is of **gross** moments of inertia, frame
strip over column or middle strip. Passing the effective frame I here
cancels the effective I of `Δframe,fixed` and returns a gross-section
deflection.

# Arguments
- `Δ_frame_fixed`: Frame strip fixed-end deflection (computed with Ie)
- `LDF`: Load distribution factor for the strip
- `Ig_frame`: Gross moment of inertia of the frame strip
- `Ig_strip`: Gross moment of inertia of the strip

# Reference
- PCA Notes on ACI 318-11 §9.5.3.4 Eq. 11, as worked in StructurePoint
  examples: sp-de-two-way-slab-with-beams-aci318-14 pp. 57–58
  (0.690 × 0.0063 × 25,395.13 / 20,040.49, both gross, with Ie,avg = 22,761.52
  used only in Δframe,fixed) and sp-de-two-way-flat-slab-drop-panels-aci318-14
  p. 72 (0.738 × 0.0995 × 30,000 / 15,000, slab gross over strip gross, with
  Ie,avg = 37,190 used only in Δframe,fixed).
"""
function strip_deflection_fixed(Δ_frame_fixed, LDF::Float64, Ig_frame, Ig_strip)
    return LDF * Δ_frame_fixed * (Ig_frame / Ig_strip)
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
ACI 318-11 Eq. (10-2), the same form the workflow uses to grow and check columns:
    Pu ≈ At × qu × n_stories_above
    Ag_required = Pu / (0.80 φ [0.85 f'c (1-ρg) + ρg × fy])

with ρg = 1% (§10.9.1 minimum) and φ = 0.65 (tied, compression-controlled).

# Reference
- ACI 318-11 §10.3.6 (nominal axial strength)
- Rule of thumb: c ≈ √(Ag)

# Example
```julia
At = 100u"m^2"      # 100 m² tributary
qu = 10u"kPa"       # ~200 psf factored
n = 5               # 5 stories above
fc = 4000u"psi"
c = estimate_column_size(At, qu, n, fc)  # ≈ 24 inches
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
    span_ratio::Float64 = 15.0,  # c = span / ratio for punching adequacy
    min_size::Union{Length, Nothing} = nothing,  # overrides the 14"/10" minimum
)
    # Estimated factored axial load
    Pu = At * qu * n_stories_above
    Ag_axial = tied_column_area_for_axial(Pu, fc; fy = fy)
    
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
    c_min = something(min_size, isnothing(span) ? 10.0u"inch" : 14.0u"inch")
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
    tied_column_axial_strength(Ag, fc; fy=60 ksi, ρg=0.01) -> Force

Maximum design axial strength of a tied column, ACI 318-11 Eq. (10-2)
(§10.3.6.2; corpus: aci-318-11, page 143):

    φPn,max = 0.80 φ [0.85 f′c (Ag − Ast) + fy Ast]

with φ = 0.65 for a compression-controlled tied member (§9.3.2.2(b),
page 127) and Ast = ρg Ag. The default ρg = 0.01 is the §10.9.1 minimum
(page 148). Column growth, the axial check, and the recorded axial ratio
all use this.
"""
function tied_column_axial_strength(Ag::Area, fc::Pressure;
                                    fy::Pressure = 60000u"psi", ρg::Float64 = 0.01)
    Ast = ρg * Ag
    return 0.80 * 0.65 * (0.85 * fc * (Ag - Ast) + fy * Ast)
end

"""
    tied_column_area_for_axial(Pu, fc; fy=60 ksi, ρg=0.01) -> Area

Gross area at which [`tied_column_axial_strength`](@ref) equals `Pu`.
Eq. (10-2) is linear in Ag, so this is `Pu` divided by the strength of
a unit area.
"""
function tied_column_area_for_axial(Pu::Force, fc::Pressure;
                                    fy::Pressure = 60000u"psi", ρg::Float64 = 0.01)
    per_area = tied_column_axial_strength(1.0u"m^2", fc; fy, ρg) / 1.0u"m^2"
    return Pu / per_area
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
    # Round up to nearest inch. The 0.1" tolerance keeps a metric bay stored
    # as 6.1 m (20.01 ft → 16.01") at 16", not 17".
    return ceil(ustrip(u"inch", c) - 0.1) * u"inch"
end


