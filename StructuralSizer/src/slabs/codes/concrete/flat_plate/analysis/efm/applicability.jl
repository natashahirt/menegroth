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

"""Panels this frame will not take. Empty when the slab has no skeleton."""
function _efm_irregular_panels(struc, slab)
    hasproperty(struc, :skeleton) || return String[]
    hasproperty(struc, :cells) || return String[]
    skel = struc.skeleton
    hasproperty(skel, :face_vertex_indices) || return String[]
    out = String[]
    for ci in slab.cell_indices
        face = struc.cells[ci].face_idx
        pts = [_vertex_xy_m(skel, Int(vi)) for vi in skel.face_vertex_indices[face]]
        is_rectangular_panel(pts) && continue
        push!(out, "irregular panel: face $face is not a rectangle. This equivalent frame is built on rectangular panels")
    end
    return out
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

# ACI 318-11 §13.7 Requirements (corpus: aci-318-11, pages 258–261):

Unlike DDM, EFM has fewer geometric restrictions. This implementation still requires:

1. **§13.7.2** — each frame is a row of columns or supports and slab-beam strips
2. **§13.7.3.3** — slab-beam inertia from the center of the support to its face;
   a support is a column, capital, bracket, or wall (R13.7.3.3)
3. **§13.7.4 / §13.7.5** — column stiffness and the torsional member, sized from
   the column, bracket, or capital. A wall that covers the panel edge is a fixed
   joint (R13.1, R13.6.3.3). A shorter wall is a column. Neither case builds the
   torsional member from the wall length.
4. **§13.7.7** — factored moments are taken at the face of the support

A wall is a support (R13.7.3.3). §13.7.5.1 does not give the torsional member
for a wall longer than a column, and §13.7.4 does not give that wall's stiffness.
This check refuses the equivalent frame when a wall supports the slab.

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
    
    # §13.7.2 — this frame is a row of supports and slab-beam strips on a
    # rectangular panel. The code does not forbid other panels; this model does.
    if l1_val <= 0 || l2_val <= 0
        push!(violations, "§13.7.2: equivalent frame needs a rectangular panel; invalid span dimensions l₁=$(l1), l₂=$(l2)")
    end

    # ACI 318-11 §13.7 does not limit panel shape. This frame is built on
    # rectangular panels, so anything else is refused and analyzed by the shell.
    if hasproperty(slab, :is_rectangular) && !slab.is_rectangular
        push!(violations, "irregular panel: slab is marked non-rectangular. This equivalent frame is built on rectangular panels")
    end
    append!(violations, _efm_irregular_panels(struc, slab))

    # §13.7.2 — a frame is a row of columns or supports.
    n_cols = length(columns)
    if n_cols < 2
        push!(violations, "§13.7.2: equivalent frame needs a row of supports; only $(n_cols) column(s) found")
    end

    # R13.7.3.3 (corpus: aci-318-11, page 259) — a support is a column, capital,
    # bracket, or wall. A full-edge wall is a fixed joint on the frame; a
    # shorter wall is a column. See `_lines_with_wall_supports`.

    # §13.7.3.3 — I_face / (1 − c2/l2)^2. The expression is singular as
    # c2/l2 → 1. The 0.5 limit is a numerical guard, not a code cutoff.
    if l2_val > 0
        for (i, col) in enumerate(columns)
            c2 = isnothing(col.c2) ? 0.0u"inch" : col.c2
            c2_l2_ratio = ustrip(c2) / l2_val
            if c2_l2_ratio > 0.5
                push!(violations, "§13.7.3.3: Column $i dimension c₂ = $(c2) exceeds half of l₂ = $(l2); the support-face inertia (1 − c₂/l₂)⁻² is not used past that")
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
spans are recomputed from those stations and the column faces.

Torsional members follow the frame, not the column's plan position
(ACI 318-11 R13.7.4, corpus: aci-318-11, page 260): each side with an
adjacent panel has one, with that panel's transverse span. The line's
optional `torsion_l2 = (l2_neg, l2_pos)` carries those spans, so a
building-edge column at the end of an interior frame has two members and
every column of an edge frame has one. Without `torsion_l2`, each column's
`position` sets the count.

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
    # Flat slab: the drop is a dead line load on each span end (PCA Tables
    # A2–A5 patch loads) and adds its weight to each column's shear. Its
    # factor is the one of the combination that sets `qu`.
    strip_extents = hasproperty(frame_line, :strip_extents) ? frame_line.strip_extents : nothing
    drop_width = isnothing(drop_panel) ? nothing : _frame_drop_width(drop_panel, l2, strip_extents)
    spans = _spans_from_projections(columns, proj, axis, l2, h, Ecs; drop_panel, drop_width)
    _reuse_line_model!(efm_cache, spans)
    drop_loads = isnothing(drop_panel) ? nothing :
        _frame_drop_loads(spans, columns,
                          governing_dead_factor(qD, qL) * drop_panel_dead_pressure(drop_panel, ρ_concrete),
                          drop_width)
    drop_shears = isnothing(drop_panel) ? nothing :
        column_drop_panel_shears(columns, drop_panel, ρ_concrete, axis, qD, qL)
    joint_positions = [col.position for col in columns]
    torsion_l2 = hasproperty(frame_line, :torsion_l2) ? frame_line.torsion_l2 : nothing
    env, use_pattern = _solve_efm_line(
        method, spans, columns, joint_positions, struc, Ecs, Ecc, qu, qD, qL;
        ν_concrete, ρ_concrete, verbose, efm_cache, col_I_factor, torsion_l2,
        drop_loads, drop_shears,
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
        M_wall_ext = uconvert(kip * u"ft", env.M_wall_ext),
        M_wall_int = uconvert(kip * u"ft", env.M_wall_int),
        M_neg_ext_face = uconvert(kip * u"ft", env.M_neg_ext_face),
        M_neg_int_face = uconvert(kip * u"ft", env.M_neg_int_face),
        wall_transfer = _efm_wall_transfer(columns, env.unbalanced_moments),
    )
end

"""
    _efm_wall_transfer(columns, unbalanced_moments) -> Vector

`(seg, M)` for each wall joint of one frame line: the joint's unbalanced
moment, which goes into the wall because the joint is the wall. It is the
full end moment at an end of the line and the difference of the two span
moments between spans, enveloped over the §13.7.6 patterns per pattern
(`_efm_demands_with_pattern`). Joints without a wall segment are skipped.
"""
function _efm_wall_transfer(columns, unbalanced_moments)
    out = Any[]
    for (j, col) in enumerate(columns)
        _is_wall_support(col) || continue
        seg = hasproperty(col, :wall_seg) ? col.wall_seg : nothing
        seg === nothing && continue
        push!(out, (seg = seg, M = uconvert(kip * u"ft", abs(unbalanced_moments[j]))))
    end
    return out
end

"""
    _sum_wall_transfer(lists) -> Vector

Per-wall totals over several frame lines: each line carries the moment of
its own strip, so the moments of one wall add.
"""
function _sum_wall_transfer(lists)
    total = Dict{Any, Any}()
    for list in lists, w in list
        key = _segment_key(w.seg)
        total[key] = haskey(total, key) ? (seg = total[key].seg, M = total[key].M + w.M) : w
    end
    return collect(Any, values(total))
end
