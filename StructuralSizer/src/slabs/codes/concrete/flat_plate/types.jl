# =============================================================================
# Flat Plate Analysis Types
# =============================================================================
#
# Analysis method types (FlatPlateAnalysisMethod, DDM, EFM, FEA) are defined
# in slabs/types.jl so that options.jl can reference them before codes/ loads.
#
# Reference: ACI 318-11 §13.6 (DDM), §13.7 (EFM)
# =============================================================================

using Unitful
using Unitful: @u_str

# =============================================================================
# Moment Analysis Results
# =============================================================================

"""
    MomentAnalysisResult

Results from moment analysis (DDM, EFM, or FEA) for a flat plate panel.

This is the common interface between moment analysis and the downstream design
pipeline (reinforcement, punching shear, deflection).

## Primary data: `column_moments`

The per-column moment vector **`column_moments`** is the authoritative source
of column negative moments.  All methods populate it:

- **DDM**: assigns `M_neg_ext` to exterior columns, `M_neg_int` to interior
- **EFM**: assigns span-end moments from frame analysis to each column
- **FEA**: assigns per-column strip-integration moments directly

The scalar fields `M_neg_ext` and `M_neg_int` are **derived envelopes** —
the maximum of `column_moments` across exterior and interior columns,
respectively.  The design pipeline reads `column_moments` directly via
ACI 8.10.5 transverse distribution.

## Fields
- `M0::Moment`: Total static moment (qu × l₂ × ln² / 8)
- `M_neg_ext::Moment`: Envelope exterior M⁻ (max of column_moments at ext columns)
- `M_neg_int::Moment`: Envelope interior M⁻ (max of column_moments at int columns)
- `M_pos::Moment`: Positive midspan moment
- `qu::Pressure`: Factored uniform load (1.2D + 1.6L)
- `qD::Pressure`: Service dead load
- `qL::Pressure`: Service live load
- `l1::Length`: Span in analysis direction (center-to-center)
- `l2::Length`: Panel width perpendicular to span (tributary width)
- `ln::Length`: Clear span (face-to-face of columns)
- `c_avg::Length`: Average column dimension
- `column_moments::Vector{<:Moment}`: **Primary** per-column M⁻ (unitful)
- `column_shears::Vector{<:Force}`: Shear at each column
- `unbalanced_moments::Vector{<:Moment}`: Unbalanced moment at each column
- `Vu_max::Force`: Maximum shear demand
- `secondary::Union{Nothing, NamedTuple}`: Perpendicular direction moments (FEA only).
  NamedTuple `(M_neg_ext, M_neg_int, M_pos, M0)` — all in kip·ft.  `nothing` for DDM/EFM.
- `fea_Δ_panel::Union{Nothing, Length}`: Max panel deflection from FEA at factored load,
  gross section.  Used by `check_two_way_deflection` for direct FEA-based deflection
  instead of the approximate crossing-beam method.  `nothing` for DDM/EFM.
"""
struct MomentAnalysisResult{M<:Moment, P<:Pressure, F<:Force}
    # Total static moment
    M0::M
    
    # Longitudinal moments (frame strip level, before transverse distribution)
    M_neg_ext::M
    M_neg_int::M
    M_pos::M
    
    # Loads
    qu::P
    qD::P
    qL::P
    
    # Geometry (allow mixed length units - Unitful handles conversions)
    l1::Length
    l2::Length
    ln::Length
    c_avg::Length
    
    # Column-level results (all unitful for consistency)
    column_moments::Vector{M}            # Design moments at each column
    column_shears::Vector{F}             # Shear at each column
    unbalanced_moments::Vector{M}        # Unbalanced moment at each column
    Vu_max::F

    # Optional: secondary (perpendicular) direction moments
    # NamedTuple with fields: M0, M_neg_ext, M_neg_int, M_pos, l1, l2, ln,
    #   column_moments, column_shears, unbalanced_moments
    # Populated by run_secondary_moment_analysis (DDM/EFM/FEA).
    secondary::Union{Nothing, NamedTuple}

    # Optional: FEA max panel deflection (factored load, gross section)
    # Extracted directly from FEA nodal displacements — `nothing` for DDM/EFM.
    fea_Δ_panel::Union{Nothing, Length}

    # Whether pattern loading (ACI 13.7.6) was applied to produce this result.
    # True when L/D > 0.75 and the analysis method supports pattern loading
    # (EFM, FEA).  DDM coefficients already account for this implicitly.
    pattern_loading::Bool

    function MomentAnalysisResult(
        M0::M, M_neg_ext::M, M_neg_int::M, M_pos::M,
        qu::P, qD::P, qL::P,
        l1::Length, l2::Length, ln::Length, c_avg::Length,
        column_moments::Vector{M},
        column_shears::Vector{F},
        unbalanced_moments::Vector{M},
        Vu_max::F;
        secondary::Union{Nothing, NamedTuple} = nothing,
        fea_Δ_panel::Union{Nothing, Length} = nothing,
        pattern_loading::Bool = false,
    ) where {M<:Moment, P<:Pressure, F<:Force}
        new{M,P,F}(
            M0, M_neg_ext, M_neg_int, M_pos,
            qu, qD, qL, l1, l2, ln, c_avg,
            column_moments, column_shears, unbalanced_moments,
            Vu_max, secondary, fea_Δ_panel,
            pattern_loading,
        )
    end
end

# =============================================================================
# Per-Column Envelope Helper
# =============================================================================

"""
    _envelope_from_columns(column_moments, columns) -> (M_neg_ext, M_neg_int)

Derive `M_neg_ext` and `M_neg_int` envelope values from per-column moments.

Iterates over `columns`, classifying each by `.position`:
- `:interior` → contributes to `M_neg_int`
- anything else (`:edge`, `:corner`) → contributes to `M_neg_ext`

Returns the maximum column moment in each group.  If a group has no members
the envelope value is `zero(eltype(column_moments))`.

This is the single, shared helper used by FEA (and available to DDM/EFM) to
derive the scalar envelope from the authoritative `column_moments` vector.
"""
function _envelope_from_columns(column_moments, columns)
    T = eltype(column_moments)
    M_neg_ext = zero(T)
    M_neg_int = zero(T)
    for (i, col) in enumerate(columns)
        m = column_moments[i]
        if col.position == :interior
            M_neg_int = max(M_neg_int, m)
        else
            M_neg_ext = max(M_neg_ext, m)
        end
    end
    return (M_neg_ext=M_neg_ext, M_neg_int=M_neg_int)
end

# =============================================================================
# Drop Panel Geometry (Flat Slab — ACI 318-11 §13.2.5)
# =============================================================================

"""
    DropPanelGeometry

Geometry of a drop panel (thickened slab zone around a column) for flat slab design.

Drop panels must satisfy ACI 318-11 §13.2.5:
- (a) Projection below slab ≥ h_slab / 4
- (b) Extend ≥ l/6 from column center in each direction

# Fields
- `h_drop::Length`: Drop panel projection below the slab soffit.
      Total depth at drop = h_slab + h_drop.
- `a_drop_1::Length`: Drop panel half-extent in span direction 1 (from column center).
      Full extent in direction 1 = 2 × a_drop_1.
- `a_drop_2::Length`: Drop panel half-extent in span direction 2 (from column center).
      Full extent in direction 2 = 2 × a_drop_2.

# ACI Requirements
- `h_drop ≥ h_slab / 4`                          ACI 318-11 §13.2.5
- `a_drop_1 ≥ l1 / 6`,  `a_drop_2 ≥ l2 / 6`    ACI 318-11 §13.2.5

# Formwork
Standard lumber sizes control practical drop depths:
| Nominal | Actual | + Plyform (3/4") | h_drop |
|---------|--------|------------------|--------|
| 2×      | 1.5"   | 0.75"            | 2.25"  |
| 4×      | 3.5"   | 0.75"            | 4.25"  |
| 6×      | 5.5"   | 0.75"            | 6.25"  |
| 8×      | 7.25"  | 0.75"            | 8.00"  |

# Reference
- ACI 318-11 §13.2.5
- StructurePoint DE-Two-Way-Flat-Slab: h_drop = 4.25 in. (4× lumber), a_drop = 5 ft
"""
struct DropPanelGeometry{L<:Length}
    h_drop::L       # projection below slab soffit
    a_drop_1::L     # half-extent in direction 1 (from column center)
    a_drop_2::L     # half-extent in direction 2 (from column center)
end

"""Convert mixed-unit lengths to Float64-based meters for internal consistency."""
function DropPanelGeometry(h_drop::Length, a1::Length, a2::Length)
    h   = Float64(ustrip(u"m", h_drop)) * u"m"
    a1m = Float64(ustrip(u"m", a1))     * u"m"
    a2m = Float64(ustrip(u"m", a2))     * u"m"
    DropPanelGeometry{typeof(h)}(h, a1m, a2m)
end

"""Total slab depth at the drop panel location."""
total_depth_at_drop(h_slab::Length, dp::DropPanelGeometry) = h_slab + dp.h_drop

"""Full plan extent of drop panel in direction i."""
drop_extent_1(dp::DropPanelGeometry) = 2 * dp.a_drop_1
drop_extent_2(dp::DropPanelGeometry) = 2 * dp.a_drop_2

"""
    check_drop_panel_aci(dp, h_slab, l1, l2) -> (ok, violations)

Verify drop panel geometry against ACI 318-11 §13.2.5 requirements.
Returns `(true, [])` if compliant, or `(false, ["violation description", ...])`.
"""
function check_drop_panel_aci(dp::DropPanelGeometry, h_slab::Length, l1::Length, l2::Length)
    violations = String[]
    
    # §8.2.4(a): projection ≥ h_slab / 4
    min_proj = h_slab / 4
    if dp.h_drop < min_proj
        push!(violations, "h_drop=$(dp.h_drop) < h_slab/4=$(min_proj) [ACI 8.2.4(a)]")
    end
    
    # §8.2.4(b): extent ≥ l/6 from column center in each direction
    min_a1 = l1 / 6
    min_a2 = l2 / 6
    if dp.a_drop_1 < min_a1
        push!(violations, "a_drop_1=$(dp.a_drop_1) < l1/6=$(min_a1) [ACI 8.2.4(b)]")
    end
    if dp.a_drop_2 < min_a2
        push!(violations, "a_drop_2=$(dp.a_drop_2) < l2/6=$(min_a2) [ACI 8.2.4(b)]")
    end
    
    return (isempty(violations), violations)
end

"""Standard formwork drop panel depths in inches (actual lumber + 3/4" plyform)."""
const STANDARD_DROP_DEPTHS_INCH = [2.25, 4.25, 6.25, 8.0]

# =============================================================================
# EFM-Specific Types
# =============================================================================

"""
    EFMSpanProperties

Properties for a single span in the EFM frame model.

# Fields
- `span_idx::Int`: Span index (1-based)
- `left_joint::Int`: Left joint index
- `right_joint::Int`: Right joint index
- `l1::Length`: Span length (center-to-center)
- `l2::Length`: Tributary width perpendicular to span
- `ln::Length`: Clear span
- `h::Length`: Slab thickness
- `c1_left::Length`: Left column dimension parallel to span
- `c2_left::Length`: Left column dimension perpendicular to span
- `c1_right::Length`: Right column dimension parallel to span
- `c2_right::Length`: Right column dimension perpendicular to span
- `Is::SecondMomentOfArea`: Slab moment of inertia
- `Ksb::Moment`: Slab-beam stiffness
- `m_factor::Float64`: FEM coefficient (from PCA tables)
- `COF::Float64`: Carryover factor
- `k_slab::Float64`: Stiffness factor (from PCA tables)
- `drop::Union{Nothing, DropPanelGeometry}`: Drop panel geometry (nothing for flat plate)
- `Is_drop::Union{Nothing, SecondMomentOfArea}`: Moment of inertia at drop panel section
"""
struct EFMSpanProperties{I<:SecondMomentOfArea, M<:Moment}
    span_idx::Int
    left_joint::Int
    right_joint::Int
    l1::Length
    l2::Length
    ln::Length
    h::Length
    c1_left::Length
    c2_left::Length
    c1_right::Length
    c2_right::Length
    Is::I
    Ksb::M
    m_factor::Float64
    COF::Float64
    k_slab::Float64
    drop::Union{Nothing, DropPanelGeometry}
    Is_drop::Union{Nothing, I}
end

"""Convenience constructor for flat plate (no drop panels): sets `drop` and `Is_drop` to `nothing`."""
function EFMSpanProperties(
    span_idx::Int, left_joint::Int, right_joint::Int,
    l1::Length, l2::Length, ln::Length, h::Length,
    c1_left::Length, c2_left::Length, c1_right::Length, c2_right::Length,
    Is::I, Ksb::M, m_factor::Float64, COF::Float64, k_slab::Float64,
) where {I<:SecondMomentOfArea, M<:Moment}
    EFMSpanProperties{I,M}(
        span_idx, left_joint, right_joint,
        l1, l2, ln, h,
        c1_left, c2_left, c1_right, c2_right,
        Is, Ksb, m_factor, COF, k_slab,
        nothing, nothing,
    )
end

"""Does this span have drop panels?"""
has_drop_panels(sp::EFMSpanProperties) = !isnothing(sp.drop)

"""
    EFMJointStiffness

Stiffness properties at an EFM frame joint.

# Fields
- `Kc_above::Moment`: Column stiffness above joint
- `Kc_below::Moment`: Column stiffness below joint
- `Kt_left::Moment`: Torsional stiffness from left
- `Kt_right::Moment`: Torsional stiffness from right
- `Kec::Moment`: Equivalent column stiffness (combined)
- `position::Symbol`: Joint position (:interior, :edge, :corner)
"""
struct EFMJointStiffness{M<:Moment}
    Kc_above::M
    Kc_below::M
    Kt_left::M
    Kt_right::M
    Kec::M
    position::Symbol
end

