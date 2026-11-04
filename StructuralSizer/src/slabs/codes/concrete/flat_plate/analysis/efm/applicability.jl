# =============================================================================
# EFM Applicability Check - ACI 318-11 §13.7
# =============================================================================

"""
    EFMApplicabilityError <: Exception

Error thrown when EFM is not applicable for the given geometry/loading.
"""
struct EFMApplicabilityError <: Exception
    violations::Vector{String}
end

"""Print a human-readable error listing violated ACI 318-11 §13.7 conditions and suggest FEA as fallback."""
function Base.showerror(io::IO, e::EFMApplicabilityError)
    println(io, "EFM (Equivalent Frame Method) is not permitted for this slab per ACI 318-11 §13.7:")
    for (i, v) in enumerate(e.violations)
        println(io, "  $i. $v")
    end
    # FEA is always valid - suggest it as the fallback
    println(io, "\nConsider using FEA (Finite Element Analysis) instead: method=FEA()")
    println(io, "FEA has no geometric restrictions and can handle any layout.")
end

"""
    check_efm_applicability(struc, slab, columns; throw_on_failure=true)

Check if EFM is applicable per ACI 318-11 §13.7.

# ACI 318-11 §13.7 Requirements:

Unlike DDM, EFM has **fewer geometric restrictions**. It is a general method that can
handle irregular layouts. However, it still requires:

1. **§8.11.1.1** - Analysis is for gravity loads only (lateral by separate analysis)
2. **§8.11.2** - Slab-beam must extend from column centerline to column centerline
3. **§8.11.5** - Equivalent column stiffness must properly account for torsion
4. **§8.11.6.1** - Design moments taken at face of support
5. **§8.11.6.1** - Negative moment not taken at distance > 0.175×l₁ from column center

# Key Advantage
EFM has **no restrictions** on:
- Number of spans (DDM requires ≥3)
- Panel aspect ratio (DDM requires l₂/l₁ ≤ 2.0)
- Successive span ratios (DDM requires ≤1/3 difference)
- Column offsets (DDM requires ≤10% of span)
- L/D ratio (DDM requires ≤2.0)

# Arguments
- `struc`: BuildingStructure
- `slab`: Slab being designed
- `columns`: Vector of supporting columns
- `throw_on_failure`: If true, throw EFMApplicabilityError; if false, return result

# Returns
Named tuple with:
- `ok::Bool`: true if EFM is applicable
- `violations::Vector{String}`: list of violated conditions with code references

# Throws
`EFMApplicabilityError` if any condition is violated and `throw_on_failure=true`
"""
function check_efm_applicability(struc, slab, columns; throw_on_failure::Bool = true)
    violations = String[]
    
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    l1_val = ustrip(l1)
    l2_val = ustrip(l2)
    
    # -------------------------------------------------------------------------
    # Minimum clear span check (practical limit for two-way behavior)
    # -------------------------------------------------------------------------
    # Two-way slab analysis assumes slenderness; spans < 4 ft behave more like
    # thick plates where shear governs over flexure
    if !isempty(columns)
        c1_avg = sum(isnothing(col.c1) ? 0.0u"inch" : col.c1 for col in columns) / length(columns)
        ln = clear_span(l1, c1_avg)
        
        ln_min = 4.0u"ft"
        if ln < ln_min
            push!(violations, "Clear span ln = $(round(ustrip(u"ft", ln), digits=2)) ft < $(ustrip(u"ft", ln_min)) ft minimum for two-way slab behavior")
        end
    end
    
    # -------------------------------------------------------------------------
    # §8.11.2 - Panel geometry: must be rectangular
    # -------------------------------------------------------------------------
    # EFM models the slab as a 2D frame; non-rectangular bays require FEA
    if l1_val <= 0 || l2_val <= 0
        push!(violations, "§8.11.2: Panel must be rectangular; invalid span dimensions l₁=$(l1), l₂=$(l2)")
    end
    
    # Check if slab has non-rectangular geometry flag (if available)
    if hasproperty(slab, :is_rectangular) && !slab.is_rectangular
        push!(violations, "§8.11.2: Panel must be rectangular; EFM frame model requires orthogonal bays (use FEA for irregular geometry)")
    end
    
    # -------------------------------------------------------------------------
    # §8.11.1.1 - Gravity loads only
    # -------------------------------------------------------------------------
    # We assume this is satisfied since EFM frame doesn't include lateral loads
    # Lateral loads should be handled by a separate lateral system analysis
    
    # -------------------------------------------------------------------------
    # Minimum geometry requirements
    # -------------------------------------------------------------------------
    # EFM requires at least 2 columns to form a span
    n_cols = length(columns)
    if n_cols < 2
        push!(violations, "§8.11.2: EFM requires at least 2 columns to form a frame; only $(n_cols) column(s) found")
    end
    
    # -------------------------------------------------------------------------
    # Column sizing requirements for torsional stiffness
    # -------------------------------------------------------------------------
    # Check that columns have reasonable dimensions for Kt calculation
    # c2/l2 should not be too large (approaches infinity in Kt formula)
    if l2_val > 0
        for (i, col) in enumerate(columns)
            c2 = isnothing(col.c2) ? 0.0u"inch" : col.c2
            c2_l2_ratio = ustrip(c2) / l2_val
            if c2_l2_ratio > 0.5
                push!(violations, "§8.11.5: Column $i dimension c₂ = $(c2) exceeds 50% of panel width l₂ = $(l2); torsional stiffness formula invalid")
            end
        end
    end
    
    ok = isempty(violations)
    
    if !ok && throw_on_failure
        throw(EFMApplicabilityError(violations))
    end
    
    return (ok=ok, violations=violations)
end

"""
    enforce_efm_applicability(struc, slab, columns)

Enforce EFM applicability, throwing an error if not permitted.
This is called automatically by `run_moment_analysis(::EFM, ...)`.
"""
function enforce_efm_applicability(struc, slab, columns)
    check_efm_applicability(struc, slab, columns; throw_on_failure=true)
end

# =============================================================================
# FrameLine-Based EFM Analysis
# =============================================================================

"""
    run_moment_analysis(method::EFM, frame_line, struc, h, fc, Ecs, Ecc, qu, qD, qL; kwargs...)

Solve one equivalent frame.

`frame_line` supplies `columns`, `column_projections`, `tributary_width`, and
`direction`. A projection that is a length is converted to meters. A bare
number is already meters, which is what `_equivalent_frames` stores. Clear
spans are recomputed from those stations and the column faces. Joint stiffness uses each column's
own `position`: an interior column has a torsion member on both sides, and
an edge or corner column has one (ACI 318-11 §13.7.2.3, corpus: aci-318-11,
page 259). The frame line's end/middle tags are not used, because the middle
of an edge line is still an edge column.

# Returns
`MomentAnalysisResult` for this line. Column vectors follow the line's
span order, not the order of a floor-wide column list.
"""
function run_moment_analysis(
    method::EFM,
    frame_line,
    struc,
    h::Length,
    fc::Pressure,  # historical argument; the column modulus used here is Ecc
    Ecs::Pressure,
    Ecc::Pressure,
    qu::Pressure,
    qD::Pressure,
    qL::Pressure;
    ν_concrete::Float64 = 0.20,
    ρ_concrete = 2380.0u"kg/m^3",
    verbose::Bool = false,
    efm_cache::Union{Nothing, EFMModelCache} = nothing,
    cache = nothing,  # API parity (unused by EFM)
    col_I_factor::Float64 = 0.70,  # ACI 318-11 §10.10.4.1 — cracked-column magnitude (from caller)
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
)
    length(frame_line.column_projections) == length(frame_line.columns) ||
        error("EFM frame line projections do not match its columns")
    axes = _eq137_unit_axes(Tuple{Float64, Float64}(frame_line.direction))
    axes === nothing && error("EFM frame line direction is zero")
    axis = axes[1]
    proj = [p isa Length ? ustrip(u"m", p) : Float64(p) for p in frame_line.column_projections]
    perm = sortperm(proj)
    columns = [frame_line.columns[i] for i in perm]
    proj = proj[perm]
    l2 = frame_line.tributary_width isa Length ? frame_line.tributary_width :
        frame_line.tributary_width * u"m"
    spans = _spans_from_projections(columns, proj, axis, l2, h, Ecs; drop_panel)
    _reuse_line_model!(efm_cache, spans)
    # col.position, not the line's end/middle tag: the middle of an edge
    # frame is an edge column and has one torsion member.
    joint_positions = [col.position for col in columns]
    env, use_pattern = _solve_efm_line(
        method, spans, columns, joint_positions, struc, Ecs, Ecc, qu, qD, qL;
        ν_concrete, ρ_concrete, verbose, efm_cache, col_I_factor,
    )
    n_spans = length(spans)
    ln_avg = sum(sp.ln for sp in spans) / n_spans
    l1_avg = sum(sp.l1 for sp in spans) / n_spans
    c_avg = sum(sp.c1_left + sp.c1_right for sp in spans) / (2 * n_spans)
    M0 = total_static_moment(qu, l2, eq13_4_clear_span(l1_avg, ln_avg))
    return MomentAnalysisResult(
        uconvert(kip * u"ft", M0),
        uconvert(kip * u"ft", env.M_neg_ext),
        uconvert(kip * u"ft", env.M_neg_int),
        uconvert(kip * u"ft", env.M_pos),
        uconvert(psf, qu),
        uconvert(psf, qD),
        uconvert(psf, qL),
        uconvert(u"ft", l1_avg),
        uconvert(u"ft", l2),
        uconvert(u"ft", ln_avg),
        uconvert(u"ft", c_avg),
        [uconvert(kip * u"ft", m) for m in env.column_moments],
        [uconvert(kip, v) for v in env.column_shears],
        [uconvert(kip * u"ft", m) for m in env.unbalanced_moments],
        uconvert(kip, qu * l2 * ln_avg / 2);
        pattern_loading = use_pattern,
    )
end
