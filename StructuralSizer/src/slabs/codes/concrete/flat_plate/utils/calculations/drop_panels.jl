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
    return (w_slab, drop_panel_dead_pressure(drop, ρ))
end

"""
    drop_panel_dead_pressure(drop, ρ) -> Pressure

Unfactored self-weight of the drop projection per unit plan area,
`h_drop × ρ × g`. It acts only inside the drop outline, on top of the slab's
own `qD`.
"""
drop_panel_dead_pressure(drop::DropPanelGeometry, ρ) = uconvert(psf, drop.h_drop * ρ * GRAVITY)

"""
    governing_dead_factor(qD, qL) -> Float64

Dead-load factor of the combination that sets `qu = max(1.2D + 1.6L, 1.4D)`
(ASCE 7 §2.3.1 combinations 1 and 2). Loads added to the slab's own `qD`,
such as the drop projection, take this factor so they stay in the same
combination as `qu`.
"""
governing_dead_factor(qD, qL) = 1.2 * qD + 1.6 * qL >= 1.4 * qD ? 1.2 : 1.4

"""
    drop_negative_section(drop, columns, d, cs_width) -> Union{Nothing, NamedTuple}

Section a drop panel gives the negative column-strip moment at a column
face, `(b, d, x_edge)`. `drop` is oriented with `a_drop_1` along the span;
`d` is the slab effective depth of the layer being designed.

ACI 318-11 §13.3.7 (corpus: aci-318-11, page 246): "In computing required
slab reinforcement, the thickness of the drop panel below the slab shall not
be assumed to be greater than one-quarter the distance from the edge of drop
panel to the face of column or column capital." The section depth is
`d + min(h_drop, distance / 4)`.

`x_edge` is the distance from the column face to the drop edge along the
span, where the slab-only section takes over. Returns `nothing` when the
drop does not extend past the column faces.

ENGINEERING JUDGMENT (not stated by §13.3.7):
- The compression zone of a negative-moment section is at the drop soffit,
  so the section is only as wide as the drop: `b = min(drop width, cs_width)`.
- The face-to-edge distance is the shorter of the two plan directions.
- The largest column dimension in the slab locates the face for every
  column, which gives the smallest drop thickness and the nearest drop edge.
"""
function drop_negative_section(drop, columns, d, cs_width)
    (drop === nothing || isempty(columns)) && return nothing
    c = maximum(col -> max(col.c1, col.c2), columns)
    reach_1 = drop.a_drop_1 - c / 2
    reach_2 = drop.a_drop_2 - c / 2
    (reach_1 > zero(reach_1) && reach_2 > zero(reach_2)) || return nothing
    h_eff = min(drop.h_drop, min(reach_1, reach_2) / 4)
    return (b = min(drop_extent_2(drop), cs_width), d = d + h_eff, x_edge = reach_1)
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
function gross_section_at_drop(l2::Length, h_slab::Length, drop::DropPanelGeometry;
                               b_drop::Length = drop_extent_2(drop))
    # Total depth at drop = h_slab + h_drop
    h_total = h_slab + drop.h_drop

    # Width of drop panel strip (perpendicular to span). A frame that ends at a
    # slab edge passes the clipped width.
    b_drop = min(b_drop, l2)

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
based on c₁/l₁, c₂/l₂, and h_drop/h_slab. The patch runs from each column
centre to the drop edge (`a_drop_1` along the span), and `b_drop` is the
drop width across the span (`2 a_drop_2`).

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

    # Patch line load = w_drop × width across the span
    b_drop = drop_extent_2(drop)  # 2 × a_drop_2

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
