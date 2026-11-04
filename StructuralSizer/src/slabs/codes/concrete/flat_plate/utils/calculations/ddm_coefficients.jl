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
Transverse distribution to column/middle strips uses ACI 318-11 §13.6.4.1–.4
and varies with l₂/l₁ and αf. For flat plates (αf = 0), see distribute_moments_aci().

# Reference
- ACI 318-11 §13.6.3
- StructurePoint DE-Two-Way-Flat-Plate Table 6
"""
const ACI_DDM_LONGITUDINAL = (
    # ACI 318-11 §13.6.3.3: Distribution of M₀ to negative and positive sections
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
        # Step 1: Longitudinal distribution (ACI 318-11 §13.6.3.3)
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
        # Interior negative: ACI 318-11 §13.6.4.1 (75% for αf=0)
        cs_int_neg = ACI_COL_STRIP_INT_NEG * M_int_neg
        
        # Exterior negative: ACI 318-11 §13.6.4.2 — interpolated with βt
        cs_ext_neg_frac = aci_col_strip_ext_neg_fraction(βt)
        cs_ext_neg = cs_ext_neg_frac * M_ext_neg
        
        # Positive: ACI 318-11 §13.6.4.4
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

