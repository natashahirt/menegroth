# =============================================================================
# Flat Plate Design Helpers
# =============================================================================
#
# Support functions for the flat plate design pipeline:
# - Column finding and ordering
# - Frame line construction
# - Axial load computation
# - Asap model updates
#
# Note: This file is included in StructuralSizer, inheriting Logging, Meshes, etc.
# =============================================================================

# =============================================================================
# Column Accessor Functions
# =============================================================================
# These provide a stable interface for column properties that may or may not
# exist on the input object (e.g., NamedTuple from standalone tests vs. a full
# Column struct from StructuralSynthesizer).

"""Column cross-section shape (`:rectangular` or `:circular`)."""
col_shape(col)::Symbol = hasproperty(col, :shape) ? col.shape : :rectangular

"""Skeleton vertex index for the column (0 = not available)."""
col_vertex_idx(col)::Int = hasproperty(col, :vertex_idx) ? col.vertex_idx : 0

"""Story index for the column (default 1)."""
col_story(col)::Int = hasproperty(col, :story) ? col.story : 1

"""Boundary edge directions for the column (empty = interior)."""
col_boundary_edge_dirs(col) = hasproperty(col, :boundary_edge_dirs) ? col.boundary_edge_dirs : NTuple{2, Float64}[]

"""Column orientation angle in radians (CCW from global X). 0.0 = axis-aligned."""
col_orientation(col)::Float64 = hasproperty(col, :θ) ? Float64(col.θ) : 0.0

# =============================================================================
# Analysis Method Utilities
# =============================================================================

"""Display name for DDM analysis method."""
method_name(method::DDM) = method.variant == :simplified ? "MDDM (Simplified)" : "DDM (ACI 8.10)"

"""Display name for EFM analysis method."""
function method_name(method::EFM)
    solver_str = method.solver == :asap ? "ASAP FEM" : "Hardy Cross"
    stiff_str  = method.column_stiffness == :Kc ? ", Kc" : ""
    crack_str  = method.cracked_columns ? ", cracked" : ""
    return "EFM (ACI 8.11, $(solver_str)$(stiff_str)$(crack_str))"
end

"""Display name for FEA analysis method."""
function method_name(method::FEA)
    # Design approach
    da = method.design_approach
    da_str = da == :frame ? "frame" :
             da == :strip ? "strip" :
             da == :area  ? "area" : string(da)

    # Sub-knobs (only shown when relevant)
    parts = String[]

    if da in (:strip, :area)
        mt = method.moment_transform
        mt == :wood_armer && push!(parts, "W-A")
        mt == :no_torsion && push!(parts, "no-Mxy")
    end

    if da == :strip
        fs = method.field_smoothing
        fs != :element && push!(parts, string(fs))

        cm = method.cut_method
        cm != :delta_band && push!(parts, string(cm))

        if cm == :isoparametric && method.iso_alpha != 1.0
            push!(parts, "α=$(method.iso_alpha)")
        end
    end

    if method.sign_treatment != :signed
        push!(parts, "sep-faces")
    end

    if !isnothing(method.rebar_direction)
        push!(parts, "θ=$(round(rad2deg(method.rebar_direction), digits=0))°")
    end

    if method.pattern_loading && method.pattern_mode != :efm_amp
        push!(parts, "pat=$(method.pattern_mode)")
    end

    knob_str = isempty(parts) ? "" : ", " * join(parts, "/")
    edge_str = isnothing(method.target_edge) ? "auto" : string(method.target_edge)
    return "FEA ($(da_str)$(knob_str), edge=$(edge_str))"
end

"""Display name for RuleOfThumb analysis method."""
method_name(::RuleOfThumb) = "ACI Min"

"""
    round_up_thickness(h, increment) -> Length

Round slab thickness up to the nearest increment.

# Example
```julia
round_up_thickness(7.3u"inch", 0.5u"inch")  # → 7.5u"inch"
```
"""
function round_up_thickness(h::Length, increment::Length)
    h_val = ustrip(u"inch", h)
    inc_val = ustrip(u"inch", increment)
    h_rounded = ceil(h_val / inc_val) * inc_val
    return h_rounded * u"inch"
end

# =============================================================================
# Column Finding
# =============================================================================

"""
    find_supporting_columns(struc, slab_cell_indices) -> Vector{Column}

Find columns whose tributary area includes any of the slab's cells.

Uses `col.tributary_cell_indices` (populated by `compute_vertex_tributaries!`).
"""
function find_supporting_columns(struc, slab_cell_indices::Set{Int})
    supporting = typeof(struc.columns)()
    for col in struc.columns
        if !isempty(col.tributary_cell_indices)
            if any(cell_idx in slab_cell_indices for cell_idx in col.tributary_cell_indices)
                push!(supporting, col)
            end
        end
    end
    return supporting
end

# =============================================================================
# Column Moment Distribution (ACI 318-11 §8.10.4)
# =============================================================================

"""
    _col_Ec_ksi(col, Ec_default_ksi) -> Float64

Return Ec in ksi for a column. Uses the column's own `concrete` field when
available (for mixed-strength buildings); otherwise falls back to the default.
"""
function _col_Ec_ksi(col, Ec_default_ksi::Float64)::Float64
    hasproperty(col, :concrete) || return Ec_default_ksi
    conc = col.concrete
    isnothing(conc) && return Ec_default_ksi
    wc = ustrip(pcf, conc.ρ)
    return ustrip(ksi, Ec(conc.fc′, wc))
end

"""
    _col_flexural_stiffness(col, Ec_default_ksi) -> Float64

Flexural stiffness K = 4·Ec·Ig / L for a single column (kip·in units).
Handles rectangular (I = b·h³/12) and circular (I = π·D⁴/64) shapes.
Uses per-column concrete when available; otherwise `Ec_default_ksi`.
"""
function _col_flexural_stiffness(col, Ec_default_ksi::Float64)::Float64
    c1 = ustrip(u"inch", col.c1)
    c2 = ustrip(u"inch", col.c2)
    L  = ustrip(u"inch", col.base.L)
    L > 0 || return 0.0

    Ec_ksi = _col_Ec_ksi(col, Ec_default_ksi)

    shape = col_shape(col)
    Ig = if shape === :circular
        D = max(c1, c2)           # c1 = c2 = D for circular
        π * D^4 / 64
    else  # :rectangular
        c1 * c2^3 / 12
    end

    return 4 * Ec_ksi * Ig / L
end

"""
    column_moment_distribution_factors(struc, columns, column_opts) -> Vector{Float64}

Compute the fraction of joint unbalanced moment resisted by each supporting
column (below the slab), per ACI 318-11 §8.10.4.

The unbalanced moment at a slab–column joint is distributed to the columns
above and below in proportion to their flexural stiffnesses:

    K = 4·E·I / L    (far-end fixed, standard gravity assumption)

Returns a vector of factors ∈ (0, 1] — one per supporting column.
Factor = 1.0 when no column exists above (roof level or single-story).
Factor ≈ 0.5 for equal columns above and below (typical interior floor).

Handles unequal columns (different dimensions, lengths, or shapes) and
per-column concrete grades (via `col.concrete`). When a column has no
per-column material, falls back to `column_opts.material`.

# Arguments
- `struc`: BuildingStructure with all columns
- `columns`: Supporting columns for this slab (below the slab)
- `column_opts`: ConcreteColumnOptions (provides default concrete grade for Ec)
"""
function column_moment_distribution_factors(struc, columns, column_opts)
    n = length(columns)
    factors = ones(Float64, n)

    # Default column Ec from column_opts (used when col.concrete is nothing)
    fc_default = column_opts.material.fc′
    wc_default = ustrip(pcf, column_opts.material.ρ)
    Ec_default = ustrip(ksi, Ec(fc_default, wc_default))  # ksi

    for (i, col_below) in enumerate(columns)
        col_above = col_below.column_above
        isnothing(col_above) && continue  # no column above → factor stays 1.0

        # Guard: skip if either column lacks cross-section dimensions
        (isnothing(col_below.c1) || isnothing(col_below.c2)) && continue
        (isnothing(col_above.c1) || isnothing(col_above.c2)) && continue

        # Stiffness K = 4·Ec·I / L — each column uses its own Ec if available
        K_below = _col_flexural_stiffness(col_below, Ec_default)
        K_above = _col_flexural_stiffness(col_above, Ec_default)

        K_total = K_below + K_above
        K_total > 0 && (factors[i] = K_below / K_total)
    end

    return factors
end

# =============================================================================
# Frame Line Construction
# =============================================================================

"""
    build_frame_line(struc, columns, l2, direction::Symbol=:x) -> FrameLine

Build a FrameLine from columns and tributary width for EFM analysis.

# Arguments
- `struc`: BuildingStructure with skeleton for column positions
- `columns`: Vector of Column objects
- `l2`: Tributary width (panel width perpendicular to frame)
- `direction`: Frame direction (:x or :y)
"""
function build_frame_line(struc, columns, l2, direction::Symbol=:x)
    vc = struc.skeleton.geometry.vertex_coords
    # Position accessor: reads from cached coordinate matrix
    function get_position(col)
        (vc[col.vertex_idx, 1], vc[col.vertex_idx, 2])
    end
    
    # Width accessor: returns column width in frame direction
    function get_width(col, dir::NTuple{2, Float64})
        if abs(dir[1]) > abs(dir[2])
            return col.c1  # X-direction
        else
            return col.c2  # Y-direction
        end
    end
    
    return FrameLine(direction, columns, l2, get_position, get_width)
end

"""
    build_frame_lines_both_directions(struc, columns, slab) -> (fl_primary, fl_secondary)

Build frame lines for analysis in both directions (for crossing beam deflection method).
"""
function build_frame_lines_both_directions(struc, columns, slab)
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    
    fl_primary = build_frame_line(struc, columns, l2, :x)
    fl_secondary = build_frame_line(struc, columns, l1, :y)
    
    return (fl_primary, fl_secondary)
end

# =============================================================================
# Load Computation
# =============================================================================

"""
    compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate) -> Vector{Float64}

Compute factored axial loads Pu (in kips) for each column from tributary areas.

Uses `col.tributary_cell_areas` which maps cell_idx → area in m².
"""
function compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)::Vector{Float64}
    n_cols = length(columns)
    Pu = Vector{Float64}(undef, n_cols)
    
    for (i, col) in enumerate(columns)
        load = 0.0kip
        
        for (cell_idx, area_m2) in col.tributary_cell_areas
            cell_idx in slab_cell_indices || continue
            cell = struc.cells[cell_idx]
            area = area_m2 * u"m^2"
            
            sw = iszero(cell.self_weight) ? sw_estimate : cell.self_weight
            qD = cell.sdl + sw
            qL = cell.live_load
            # Governing of 1.2D+1.6L vs 1.4D (ASCE 7 §2.3.1)
            q_factored = max(qD * 1.2 + qL * 1.6, qD * 1.4)
            
            load += q_factored * area
        end
        
        Pu[i] = ustrip(kip, load)
    end
    
    return Pu
end

# =============================================================================
# Asap Model Updates
# =============================================================================

"""
    update_asap_column_sections!(struc, columns, material::Concrete; I_factor=0.70)

Propagate final column geometry to Asap model after design converges.

Updates Asap elements with final column sections so subsequent structural 
analyses reflect the actual column sizes.  `I_factor` is the cracking
reduction per ACI 318-11 §10.10.4.1 (default 0.70 for columns).
"""
function update_asap_column_sections!(struc, columns, material::Concrete;
                                      I_factor::Real = 0.70)
    model = struc.asap_model
    
    for col in columns
        section = col.base.section
        isnothing(section) && continue
        
        asap_sec = to_asap_section(section, material; I_factor=I_factor)
        
        for seg_idx in col.base.segment_indices
            edge_idx = struc.segments[seg_idx].edge_idx
            if edge_idx > 0 && edge_idx <= length(model.elements)
                model.elements[edge_idx].section = asap_sec
            end
        end
    end
    
    # Re-process model with updated sections
    if model.processed
        Asap.process!(model)
    end
end

# =============================================================================
# Method Applicability Checks
# =============================================================================

"""
    check_pattern_loading_requirement(moment_results; verbose=false, threshold=0.75)

Check if pattern loading may be required per ACI 318-11 §13.7.6.

When L/D > 0.75, pattern loading can increase peak moments by up to 15%.
Issues a warning if the ratio exceeds the threshold.
"""
function check_pattern_loading_requirement(moment_results; verbose::Bool=false, threshold::Float64=0.75)
    qL = moment_results.qL
    qD = moment_results.qD
    
    qD_val = ustrip(qD)
    if qD_val < 1e-10
        return  # No dead load, skip check
    end
    
    ratio = ustrip(qL) / qD_val
    
    if ratio > threshold
        if hasproperty(moment_results, :pattern_loading) && moment_results.pattern_loading
            verbose && @debug "Pattern loading applied (ACI 13.7.6)" L_D=round(ratio, digits=2)
        else
            @warn "L/D = $(round(ratio, digits=2)) > $threshold. " *
                  "Pattern loading required per ACI 318-11 §13.7.6 but not applied " *
                  "(DDM assumes uniform loading)." qL qD
        end
    elseif verbose
        @debug "Pattern loading check" L_D_ratio=round(ratio, digits=2) threshold=threshold status="OK"
    end
end

"""
    enforce_method_applicability(method::DDM, struc, slab, columns; verbose=false)

Enforce that DDM is valid for the given geometry. Throws if not applicable.
"""
function enforce_method_applicability(method::DDM, struc, slab, columns; verbose::Bool=false, ρ_concrete::Density = NWC_4000.ρ)
    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "CHECKING DDM APPLICABILITY (ACI 318-11 §13.6.1)"
        @debug "───────────────────────────────────────────────────────────────────"
    end
    
    result = check_ddm_applicability(struc, slab, columns; throw_on_failure=true, ρ_concrete=ρ_concrete)
    
    if verbose && result.ok
        @debug "DDM applicability check: ✓ PASSED"
    end
end

"""
    enforce_method_applicability(method::EFM, struc, slab, columns; verbose=false)

Enforce that EFM is valid for the given geometry. Throws if not applicable.
"""
function enforce_method_applicability(method::EFM, struc, slab, columns; verbose::Bool=false, kwargs...)
    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "CHECKING EFM APPLICABILITY (ACI 318-11 §13.7)"
        @debug "───────────────────────────────────────────────────────────────────"
    end
    
    result = check_efm_applicability(struc, slab, columns; throw_on_failure=true)
    
    if verbose && result.ok
        @debug "EFM applicability check: ✓ PASSED"
    end
end


"""
    enforce_method_applicability(method::FEA, struc, slab, columns; verbose=false)

FEA shell model has no geometric restrictions — always applicable.
However, the post-processing design approach may have assumptions that
are violated for certain geometries.  This function issues warnings
(not errors) for approach-specific concerns.
"""
function enforce_method_applicability(method::FEA, struc, slab, columns; verbose::Bool=false, kwargs...)
    n_cols = length(columns)
    if n_cols < 2
        error("FEA requires at least 2 supporting columns; found $n_cols")
    end

    # ── Approach-specific guardrails (warnings, not hard errors) ──
    _check_fea_approach_applicability(method, struc, slab, columns; verbose=verbose)

    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "FEA APPLICABILITY: ✓ Shell model always valid"
        @debug "  $(n_cols) columns, target edge = $(method.target_edge)"
        @debug "  design_approach = $(method.design_approach)"
        @debug "───────────────────────────────────────────────────────────────────"
    end
end

# =============================================================================
# FEA Approach-Specific Guardrails
# =============================================================================

"""
    _check_fea_approach_applicability(method::FEA, struc, slab, columns; verbose=false)

Issue warnings when the chosen FEA design approach has assumptions that may
be violated by the slab geometry.  The FEA solve itself always proceeds —
these are advisory, not blocking.

# Checks by `design_approach`

## `:frame` — Frame-Level + ACI Fractions (§8.10.5)
Uses DDM-like ACI fractions to split total moments into CS/MS.  The fraction
tables assume the same geometric regularity as DDM (§8.10.2):
- Rectangular panels
- Aspect ratio l₂/l₁ ≤ 2.0
- Successive span ratio within 1/3
- ≥ 3 continuous spans per direction
- L/D ≤ 2.0 (without pattern loading)

## `:strip` — Design Strip Integration
- Non-quad cells cannot use isoparametric section cuts (falls back to δ-band)
- Non-convex cells cannot use any isoparametric mapping

## `:area` — Per-Element Design
- `:projection` moment transform is unconservative (ignores twisting moment
  envelope); `:wood_armer` is recommended for area-based design.
"""
function _check_fea_approach_applicability(
    method::FEA, struc, slab, columns;
    verbose::Bool = false,
)
    da = method.design_approach

    # ── :frame — ACI fractions assume DDM-like regularity ──
    if da == :frame
        result = check_ddm_applicability(struc, slab, columns; throw_on_failure=false)
        if !result.ok
            violated = join(result.violations, "\n    • ")
            @warn "FEA design_approach=:frame uses ACI §8.10.5 fractions for the " *
                  "CS/MS moment split.  These fractions assume the same geometric " *
                  "regularity as DDM.  The following DDM checks failed:\n    • " *
                  violated *
                  "\nResults may be approximate.  Consider :strip or :area for " *
                  "irregular geometry."
        elseif verbose
            @debug "FEA :frame guardrails — DDM geometry checks passed"
        end
    end

    # ── :strip — isoparametric cuts require quad (or convex) cells ──
    if da == :strip
        skel = struc.skeleton
        non_quad = 0
        for ci in slab.cell_indices
            cell = struc.cells[ci]
            n_v = length(skel.face_vertex_indices[cell.face_idx])
            n_v != 4 && (non_quad += 1)
        end
        n_cells = length(slab.cell_indices)
        if non_quad > 0
            @warn "FEA strip: $(non_quad)/$(n_cells) cell(s) are non-quad. " *
                  "Wachspress mapping handles convex N-gons; non-convex " *
                  "cells fall back to δ-band integration."
        end
        if verbose && non_quad == 0
            @debug "FEA :strip guardrails — all cells are quad"
        end
    end

    # ── :area — projection/no_torsion without Wood-Armer is unconservative ──
    if da == :area && method.moment_transform in (:projection, :no_torsion)
        @warn "FEA design_approach=:area with moment_transform=:$(method.moment_transform) does " *
              "not envelope twisting moments (Mxy) in the design.  This can be " *
              "unconservative for elements with significant torsion.  Consider " *
              "using moment_transform=:wood_armer for area-based design."
    end

    return nothing
end
