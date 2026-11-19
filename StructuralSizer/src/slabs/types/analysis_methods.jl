# =============================================================================
# Vault Analysis Methods
# =============================================================================

"""
    VaultAnalysisMethod

Abstract type for vault analysis methods. Allows dispatch between
analytical solutions and FEA-based approaches.

## Subtypes
- `HaileAnalytical`: Haile's 3-hinge parabolic arch (closed-form)
- `ShellFEA`: Shell finite element analysis (future)
"""
abstract type VaultAnalysisMethod end

"""
Haile's analytical method for unreinforced parabolic vaults.

Uses 3-hinge arch theory with elastic shortening correction.
Valid for parabolic intrados under uniform distributed load.

Reference: Haile method for three-hinge parabolic arch analysis.
"""
struct HaileAnalytical <: VaultAnalysisMethod end

"""
Shell FEA analysis for vault stress (future implementation).

Placeholder for FinEtools-based shell analysis for validation
and non-standard geometries.
"""
struct ShellFEA <: VaultAnalysisMethod end

# =============================================================================
# Flat Plate Analysis Methods
# =============================================================================
#
# Defined here (slab-level types) so that options.jl can reference them
# before codes/ is included.  Concrete subtypes live alongside the abstract
# type for locality.
#
# Reference: ACI 318-11 §13.6 (DDM), §13.7 (EFM)
# =============================================================================

"""
    FlatPlateAnalysisMethod

Abstract type for flat plate moment analysis methods.

Subtypes:
- `DDM`: Direct Design Method (ACI 318 coefficient-based)
- `EFM`: Equivalent Frame Method (stiffness-based frame analysis)
- `FEA`: Finite Element Analysis (shell model)
"""
abstract type FlatPlateAnalysisMethod end

"""
    DDM(variant::Symbol = :full)

Direct Design Method - ACI 318 coefficient-based moment distribution.

# Variants
- `:full` - Full ACI 318-11 §13.6.3.3 coefficients with l₂/l₁ interpolation
- `:simplified` - Modified DDM (0.65/0.35 simplified coefficients)

# Reference
- ACI 318-11 §13.6
"""
struct DDM <: FlatPlateAnalysisMethod
    variant::Symbol
    
    function DDM(variant::Symbol = :full)
        variant in (:full, :simplified) || error("DDM variant must be :full or :simplified")
        new(variant)
    end
end

"""
    EFM(; solver=:asap, column_stiffness=:Kec, cracked_columns=false, pattern_loading=true)

Equivalent Frame Method — stiffness-based frame analysis with composable options.

# Solver
- `:asap` — ASAP structural analysis (direct stiffness, default)
- `:hardy_cross` — Hardy Cross moment distribution

# Column Stiffness (`column_stiffness`)
- `:Kec` — Equivalent column stiffness with torsional reduction (standard ACI §13.7).
  `Kec = Kc×Kt/(Kc+Kt)`, where Kt is the torsional member stiffness.
- `:Kc`  — Raw column flexural stiffness (no torsional reduction). Provides a
  comparison point between standard EFM and FEA.

# Cracked Columns (`cracked_columns`)
- `false` (default) — Gross Ig for column stubs (PCA/ACI §13.7 convention).
  Matches Hardy Cross cross-validation.
- `true`  — 0.70 Ig for column stubs (ACI 318-11 §10.10.4.1).
  Provides a direct comparison with FEA column modeling.
  Only affects the `:asap` solver; Hardy Cross always uses gross Ig.

# Pattern Loading (`pattern_loading`)
- `true` (default) — Enable ACI 318-11 §13.7.6 checkerboard pattern loading.
- `false` — Full load on all spans (for direct comparison with DDM).

# Combinations
| Constructor                                               | Torsion | Cracking | Notes                    |
|-----------------------------------------------------------|---------|----------|--------------------------|
| `EFM()`                                                   | Kec     | Gross Ig | Standard EFM             |
| `EFM(column_stiffness=:Kc)`                               | Kc      | Gross Ig | Isolates torsion effect  |
| `EFM(column_stiffness=:Kc, cracked_columns=true)`         | Kc      | 0.70 Ig  | Matches FEA convention   |
| `EFM(solver=:hardy_cross)`                                | Kec     | Gross Ig | StructurePoint match     |
| `EFM(solver=:hardy_cross, column_stiffness=:Kc)`          | Kc      | Gross Ig | HC without torsion       |
| `EFM(cracked_columns=true)`                               | Kec     | 0.70 Ig  | Cracked + torsion        |

# Reference
- ACI 318-11 §13.7, PCA Notes on ACI 318-11 Appendix 20A
"""
struct EFM <: FlatPlateAnalysisMethod
    solver::Symbol
    column_stiffness::Symbol
    cracked_columns::Bool
    pattern_loading::Bool

    function EFM(;
        solver::Symbol = :asap,
        column_stiffness::Symbol = :Kec,
        cracked_columns::Bool = false,
        pattern_loading::Bool = true,
    )
        solver in (:asap, :hardy_cross) ||
            error("EFM solver must be :asap or :hardy_cross, got :$solver")
        column_stiffness in (:Kec, :Kc) ||
            error("EFM column_stiffness must be :Kec or :Kc, got :$column_stiffness")
        if cracked_columns && solver == :hardy_cross
            @warn "cracked_columns=true has no effect with :hardy_cross solver (PCA uses gross Ig)"
        end
        new(solver, column_stiffness, cracked_columns, pattern_loading)
    end
end

"""
    FEA(; target_edge, pattern_loading, pattern_mode, design_approach,
           moment_transform, field_smoothing, cut_method, iso_alpha,
           rebar_direction, sign_treatment, strip_design)

Finite Element Analysis — 2D shell model with column stubs.

No geometric restrictions — works for any slab shape or column layout.
Dead and live loads are solved separately for proper post-solve combination
(ASCE 7 §2.3.1).

# Mesh
- `target_edge::Length`: Target mesh edge length (default: adaptive from span).

# Source  (`source`)
- `:slab` (default) — mesh this slab alone on column stubs.
- `:building` — read the slab shells of the building model. Every slab and
  column of the building is in that solve, so a column shared by two slabs
  carries both. Mesh, patch and pattern settings are the building model's;
  `pattern_mode` is not used because each pattern is a building re-solve.

# Loading
- `pattern_loading::Bool`: Enable ACI 318-11 §13.7.6 pattern loading (default: `true`).
- `pattern_mode::Symbol`: How pattern loading is applied when `pattern_loading=true`:
  - `:efm_amp` (default) — Equivalent-frame pattern envelope, one frame per
    column line in each direction. Those ratios scale the shell moments and
    the column at the same index. Fast, and not a shell re-solve.
    `:fea_resolve` is the shell pattern path. Ratios are floored at 1
    (ACI 318-11 §13.7.6.4).
  - `:fea_resolve` — Re-solve the FEA model for each load pattern (D on all spans,
    L on selected spans) and take the per-element moment envelope.  More accurate
    (captures 2-D redistribution) but slower (one FEA solve per pattern).
    Requires the D/L split solve (always enabled).

# Design Approach  (`design_approach`)
Controls how FEA element moments become design moments:
- `:frame` — integrate moments across the full frame width at critical sections,
  then distribute to column-strip / middle-strip using ACI 318-11 §13.6.4/.6 tabulated
  fractions (same logic as DDM/EFM).
- `:strip` — integrate moments directly over the column-strip and middle-strip
  widths.  Sub-knobs control how the integration is performed.
- `:area` — per-element design: transform each element's moment tensor into
  design moments (no strip integration).  For use with per-element rebar maps.

# Moment Transform  (`moment_transform`)
How the 2D moment tensor (Mxx, Myy, Mxy) is reduced to a scalar design moment:
- `:projection` — project the tensor onto the reinforcement axis:
  Mn = Mxx cos²θ + Myy sin²θ + Mxy sin2θ.  Preserves equilibrium.
- `:wood_armer` — Wood (1968) / Wood–Armer transformation: adds |Mxy| to both
  Mxx and Myy to produce conservative design moments that account for twisting.
  Required for area-based design; optional for strip/frame.
- `:no_torsion` — project the tensor onto the reinforcement axis but **ignore
  the twisting moment Mxy**: Mn = Mxx cos²θ + Myy sin²θ.  This is intentionally
  unconservative and exists as a baseline to quantify the effect of Mxy.
  See Parsekian (2018) and Shin & Alemdar (2020) for why ignoring Mxy is unsafe.

# Concrete Torsion Discount  (`concrete_torsion_discount`)
- `false` (default) — use the full twisting moment |Mxy| in Wood–Armer.
- `true` — subtract the ACI-based concrete torsion capacity Mxy_c from |Mxy|
  before applying the Wood–Armer transformation.  The concrete can resist some
  twisting via its shear capacity; only the excess Mxy needs reinforcement.
  Uses a circular V–T interaction: Mxy_c = √(1 − (V/(d·τ_c))²) · h²·τ_c/3,
  where τ_c = 2λ√f'c (ACI 318-11 §11.2.1.1) and V = max(|Qxz|, |Qyz|).
  Reference: Parsekian (1996), adapted to ACI 318.

# Field Smoothing  (`field_smoothing`)
- `:element` — use raw element-centroid moments (default for strip/frame).
- `:nodal` — area-weighted nodal smoothing → continuous field.

# Sign Treatment  (`sign_treatment`)
Controls how signed moments are handled during nodal smoothing.  Only meaningful
when `field_smoothing = :nodal`; ignored for `:element`.
- `:signed` (default) — smooth the full signed tensor field.  Opposite-sign
  contributions from adjacent elements can cancel at shared nodes.  This is the
  standard SPR approach.
- `:separate_faces` — smooth top-face (hogging) and bottom-face (sagging) fields
  independently, preventing cross-sign cancellation at inflection points.
  Recommended for irregular grids or high L/D cases where hogging zones shift
  under pattern loading.  See Skorpen & Dekker (2014), Pacoste & Plos (2006).

# Cut Method  (`cut_method`, strip design only)
- `:delta_band` — δ-band section-cut integration (adaptive bandwidth).
- `:isoparametric` — isoparametric line-integral cuts through quad cells.

# Isoparametric Alpha  (`iso_alpha ∈ [0, 1]`)
Blending parameter for isoparametric cuts (only used when `cut_method = :isoparametric`):
- `0.0` — cuts follow slab contours (waffle-slab style)
- `1.0` — straight cuts perpendicular to span axis
- Default: `1.0` (straight cuts)

# Rebar Direction  (`rebar_direction`)
Angle (radians) of the primary reinforcement from the global x-axis.
`nothing` (default) → aligned with the span axis.  For skewed slabs, set to
the actual reinforcement direction.

# Backward Compatibility
The legacy `strip_design` keyword is still accepted and maps to the new knobs:
- `:aci_fractions`   → `design_approach=:frame`
- `:fea_integration` → `design_approach=:strip, moment_transform=:projection`
- `:nodal_cuts`      → `design_approach=:strip, field_smoothing=:nodal, cut_method=:isoparametric`
- `:wood_armer`      → `design_approach=:strip, moment_transform=:wood_armer`

# Reference
- ACI 318-11 §13.2.1
- Wood (1968) for Wood–Armer transformation
"""
struct FEA <: FlatPlateAnalysisMethod
    target_edge::Union{Nothing, typeof(1.0u"m")}
    pattern_loading::Bool
    pattern_mode::Symbol          # :efm_amp, :fea_resolve
    design_approach::Symbol       # :frame, :strip, :area
    moment_transform::Symbol      # :projection, :wood_armer, :no_torsion
    field_smoothing::Symbol       # :element, :nodal
    cut_method::Symbol            # :delta_band, :isoparametric
    iso_alpha::Float64            # ∈ [0, 1] for isoparametric cuts
    rebar_direction::Union{Nothing, Float64}  # radians from global x, nothing = span axis
    sign_treatment::Symbol        # :signed, :separate_faces
    concrete_torsion_discount::Bool  # subtract concrete Mxy capacity before Wood–Armer

    # Column-patch modulus multiplier. 100 stiffens the footprint to a rigid
    # zone; 1 leaves it as ordinary slab. ENGINEERING JUDGMENT: the rigid
    # patch is the default because a point-node stub on ordinary slab
    # understates the edge-column transfer.
    patch_stiffness_factor::Float64

    # Transverse averaging width at the column face, as a multiple of the
    # column dimension across the span. `nothing` integrates the whole
    # strip. A number averages the intensity inside that width and applies
    # it across the strip. The band depth along the span stays one column,
    # starting at the face. ENGINEERING JUDGMENT: ACI 318 does not
    # prescribe this width.
    averaging_width_factor::Union{Nothing, Float64}

    # Effective moment of inertia method for deflection:
    #   :aci318_19 — ACI 318-19 Table 24.2.3.5, Bischoff form with (2/3)Mcr (default)
    #   :branson   — ACI 318-11 Eq. (9-8), cubic interpolation
    #   :bischoff  — Bischoff (2005) reciprocal interpolation without the 2/3 factor
    deflection_Ie_method::Symbol

    # Legacy alias — kept for reading in dispatch/options; not a user knob
    strip_design::Symbol

    # Which shell model carries the slab:
    #   :slab     — a model of this slab alone, on column stubs (default)
    #   :building — the slab shells of the whole building model, read through
    #               `building_fea_analysis!`, which the building package defines
    source::Symbol

    function FEA(;
        target_edge::Union{Nothing, Unitful.Length} = nothing,
        pattern_loading::Bool = true,
        pattern_mode::Symbol = :efm_amp,
        design_approach::Symbol = :frame,
        moment_transform::Symbol = :projection,
        field_smoothing::Symbol = :element,
        cut_method::Symbol = :delta_band,
        iso_alpha::Float64 = 1.0,
        rebar_direction::Union{Nothing, Float64} = nothing,
        sign_treatment::Symbol = :signed,
        concrete_torsion_discount::Bool = false,
        patch_stiffness_factor::Float64 = 100.0,
        averaging_width_factor::Union{Nothing, Real} = nothing,
        deflection_Ie_method::Symbol = :aci318_19,
        # Legacy keyword — maps to new knobs when provided alone
        strip_design::Union{Nothing, Symbol} = nothing,
        source::Symbol = :slab,
    )
        # ── Legacy mapping ──
        if !isnothing(strip_design)
            if strip_design == :aci_fractions
                design_approach = :frame
            elseif strip_design == :fea_integration
                design_approach = :strip
                moment_transform = :projection
                field_smoothing = :element
                cut_method = :delta_band
            elseif strip_design == :nodal_cuts
                design_approach = :strip
                field_smoothing = :nodal
                cut_method = :isoparametric
            elseif strip_design == :wood_armer
                design_approach = :strip
                moment_transform = :wood_armer
            elseif strip_design == :peak_nodal
                # Deprecated — map to nodal strip with element smoothing
                design_approach = :strip
                field_smoothing = :nodal
                cut_method = :delta_band
                @warn "FEA strip_design=:peak_nodal is deprecated; mapped to :strip + :nodal + :delta_band"
            else
                error("Unknown legacy strip_design=$(strip_design)")
            end
        end

        # ── Compute canonical strip_design for backward compat ──
        _strip_design = if design_approach == :frame
            :aci_fractions
        elseif design_approach == :strip && moment_transform == :wood_armer
            :wood_armer
        elseif design_approach == :strip && field_smoothing == :nodal && cut_method == :isoparametric
            :nodal_cuts
        elseif design_approach == :strip
            :fea_integration
        else  # :area
            :wood_armer  # area-based defaults to wood_armer in legacy view
        end

        # ── Validation ──
        design_approach in (:frame, :strip, :area) ||
            error("FEA design_approach must be :frame, :strip, or :area; got :$design_approach")
        moment_transform in (:projection, :wood_armer, :no_torsion) ||
            error("FEA moment_transform must be :projection, :wood_armer, or :no_torsion; got :$moment_transform")
        field_smoothing in (:element, :nodal) ||
            error("FEA field_smoothing must be :element or :nodal; got :$field_smoothing")
        cut_method in (:delta_band, :isoparametric) ||
            error("FEA cut_method must be :delta_band or :isoparametric; got :$cut_method")
        pattern_mode in (:efm_amp, :fea_resolve) ||
            error("FEA pattern_mode must be :efm_amp or :fea_resolve; got :$pattern_mode")
        sign_treatment in (:signed, :separate_faces) ||
            error("FEA sign_treatment must be :signed or :separate_faces; got :$sign_treatment")
        0.0 ≤ iso_alpha ≤ 1.0 ||
            error("FEA iso_alpha must be in [0, 1]; got $iso_alpha")

        # :area + :projection / :no_torsion ignores the Mxy envelope and is
        # unconservative.  Default :frame + :projection is documented (strip
        # integration).  Refuse the area combination by coercing to Wood–Armer.
        if design_approach == :area && moment_transform in (:projection, :no_torsion)
            @error "FEA :area with moment_transform=:$(moment_transform) is refused " *
                   "(unconservative for twisting). Coercing to :wood_armer."
            moment_transform = :wood_armer
        end
        if moment_transform == :no_torsion
            @warn "FEA: :no_torsion ignores Mxy — intentionally unconservative baseline"
        end
        if sign_treatment == :separate_faces && field_smoothing != :nodal
            @warn "FEA: sign_treatment=:separate_faces only affects nodal smoothing; " *
                  "ignored with field_smoothing=:$(field_smoothing)"
        end
        if concrete_torsion_discount && moment_transform != :wood_armer
            @warn "FEA: concrete_torsion_discount=true only affects :wood_armer; " *
                  "ignored with moment_transform=:$(moment_transform)"
        end
        patch_stiffness_factor > 0 ||
            error("FEA patch_stiffness_factor must be > 0; got $patch_stiffness_factor")
        width_factor = averaging_width_factor === nothing ? nothing : Float64(averaging_width_factor)
        width_factor === nothing || width_factor > 0 ||
            error("FEA averaging_width_factor must be > 0; got $width_factor")
        deflection_Ie_method in (:aci318_19, :branson, :bischoff) ||
            error("FEA deflection_Ie_method must be :aci318_19, :branson, or :bischoff; got :$deflection_Ie_method")
        source in (:slab, :building) ||
            error("FEA source must be :slab or :building; got :$source")

        te = if target_edge !== nothing
            ustrip(u"m", target_edge) > 0 || error("FEA target_edge must be > 0")
            uconvert(u"m", target_edge)
        else
            nothing
        end

        new(te, pattern_loading, pattern_mode, design_approach, moment_transform,
            field_smoothing, cut_method, iso_alpha, rebar_direction, sign_treatment,
            concrete_torsion_discount, patch_stiffness_factor, width_factor,
            deflection_Ie_method,
            _strip_design, source)
    end
end

"""
    RuleOfThumb <: FlatPlateAnalysisMethod

Rule-of-thumb slab sizing: use ACI `min_thickness`, run one pass of all
design checks, and report results even when checks fail.

Wraps an underlying analysis method (default: simplified DDM) for moment
analysis.  The slab thickness is NOT iterated — it is fixed at the ACI
minimum, and each check result (punching, deflection, shear, flexure) is
recorded regardless of pass/fail.

# Fields
- `analysis`: Underlying moment analysis method (default `DDM(:simplified)`)

# Example
```julia
RuleOfThumb()                      # uses DDM(:simplified) internally
RuleOfThumb(FEA())                 # uses FEA for moments
```
"""
struct RuleOfThumb <: FlatPlateAnalysisMethod
    analysis::FlatPlateAnalysisMethod
end
RuleOfThumb() = RuleOfThumb(DDM(:simplified))

