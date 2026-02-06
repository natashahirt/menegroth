# =============================================================================
# Flat Plate Analysis Types
# =============================================================================
#
# Shared type definitions for DDM and EFM analysis methods.
#
# Reference: ACI 318-19 Sections 8.10 (DDM), 8.11 (EFM)
# =============================================================================

using Unitful
using Unitful: @u_str

# =============================================================================
# Analysis Method Selection
# =============================================================================

"""
    FlatPlateAnalysisMethod

Abstract type for flat plate moment analysis methods.

Subtypes:
- `DDM`: Direct Design Method (ACI 318 coefficient-based)
- `EFM`: Equivalent Frame Method (stiffness-based frame analysis)
"""
abstract type FlatPlateAnalysisMethod end

"""
    DDM(variant::Symbol = :full)

Direct Design Method - ACI 318 coefficient-based moment distribution.

# Variants
- `:full` - Full ACI 318 Table 8.10.4.2 coefficients with l₂/l₁ interpolation
- `:simplified` - Modified DDM (0.65/0.35 simplified coefficients)

# Example
```julia
size_flat_plate!(struc, slab, col_opts; method=DDM())           # Default full ACI
size_flat_plate!(struc, slab, col_opts; method=DDM(:simplified)) # MDDM
```

# Reference
- ACI 318-19 Section 8.10
- StructurePoint DE-Two-Way-Flat-Plate Section 3.1 (DDM)
"""
struct DDM <: FlatPlateAnalysisMethod
    variant::Symbol
    
    function DDM(variant::Symbol = :full)
        variant in (:full, :simplified) || error("DDM variant must be :full or :simplified")
        new(variant)
    end
end

"""
    EFM(solver::Symbol = :asap)

Equivalent Frame Method - stiffness-based frame analysis.

Models the slab strip as a continuous beam supported on equivalent columns,
accounting for torsional flexibility of the slab-column connection.

# Solvers
- `:asap` - Use ASAP structural analysis package (default)
- `:moment_distribution` - Hardy Cross moment distribution [future]

# Example
```julia
size_flat_plate!(struc, slab, col_opts; method=EFM())       # Default ASAP solver
```

# Reference
- ACI 318-19 Section 8.11
- StructurePoint DE-Two-Way-Flat-Plate Section 3.2 (EFM)
"""
struct EFM <: FlatPlateAnalysisMethod
    solver::Symbol
    
    function EFM(solver::Symbol = :asap)
        solver in (:asap, :moment_distribution) || error("EFM solver must be :asap or :moment_distribution")
        new(solver)
    end
end

# =============================================================================
# Moment Analysis Results
# =============================================================================

"""
    MomentAnalysisResult

Results from DDM or EFM moment analysis for a flat plate panel.

This is the common interface between moment analysis (DDM/EFM) and the 
downstream design pipeline. Both methods produce this same structure.

# Fields
- `M0::Moment`: Total static moment (qu × l₂ × ln² / 8)
- `M_neg_ext::Moment`: Exterior negative moment (at exterior column)
- `M_neg_int::Moment`: Interior negative moment (at first interior column)
- `M_pos::Moment`: Positive moment (midspan)
- `qu::Pressure`: Factored uniform load (1.2D + 1.6L)
- `qD::Pressure`: Service dead load
- `qL::Pressure`: Service live load
- `l1::Length`: Span in analysis direction (center-to-center)
- `l2::Length`: Panel width perpendicular to span (tributary width)
- `ln::Length`: Clear span (face-to-face of columns)
- `c_avg::Length`: Average column dimension
- `column_moments::Vector{<:Moment}`: Design moments at each column (unitful)
- `column_shears::Vector{<:Force}`: Shear at each column
- `unbalanced_moments::Vector{<:Moment}`: Unbalanced moment at each column
- `Vu_max::Force`: Maximum shear demand

# Note
The column/middle strip distribution (ACI 8.10.5) is applied AFTER this result
is produced, in the shared pipeline. Both DDM and EFM use the same transverse
distribution factors.
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
end

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
end

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

# =============================================================================
# Exports
# =============================================================================

export FlatPlateAnalysisMethod, DDM, EFM
export MomentAnalysisResult
export EFMSpanProperties, EFMJointStiffness
