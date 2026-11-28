# =============================================================================
# FrameLine-Based DDM Analysis
# =============================================================================

"""
§13.6.3.3 support class of every FrameLine column along
`frame_line.direction` (`_ddm_support_class`).  Without skeleton geometry
the FrameLine `joint_positions` are used and each column emits a
`:fallback` trace event (`no_geometry`).
"""
function _frameline_support_classes(struc, frame_line; tc = nothing,
                                    ctx = _eq137_geometry_available(struc) ?
                                          _eq137_context(struc, frame_line.columns) : nothing)
    cols = frame_line.columns
    d = frame_line.direction
    axis = (Float64(d[1]), Float64(d[2]))
    classes = Symbol[]
    for (i, col) in enumerate(cols)
        cls = nothing
        if ctx === nothing
            _eq137_trace_fallback(tc, col, :no_geometry; stage = "_ddm_support_moment")
        else
            cls = _ddm_support_class(struc, col, axis; index = ctx.index,
                                     vertex_column = ctx.vertex_column,
                                     partway = ctx.partway, tc = tc)
        end
        if cls === nothing
            cls = frame_line.joint_positions[i] == :exterior ? :exterior : :interior
        end
        push!(classes, cls)
    end
    return classes
end

"""
True when `col` is a wall that supports the whole edge it meets.

ACI 318-11 R13.1 (aci-318-11, page 243) treats that wall as a beam of
infinite stiffness, so §13.6.3.3 Column (5) applies (page 254). A shorter
wall is stored with `wall_fixed` false and stays a column joint.
"""
_support_is_wall_fixed(col) = hasproperty(col, :wall_fixed) && col.wall_fixed === true

"""
Per-span DDM moments of a FrameLine with the given exterior supports.

Each span: M0 by ACI 318-11 §13.6.2.2 Eq. (13-4) (corpus: aci-318-11,
page 253) and the §13.6.3 coefficients (page 254): Column (5) when either
support is a fully restrained wall, otherwise end-span coefficients when
either support is exterior (edge beam via `βt`), interior-span coefficients
otherwise; `:simplified` uses 0.65 / 0.35 throughout.
"""
function _frameline_span_moments(method::DDM, frame_line, qu, column_is_exterior, βt)
    l2 = frame_line.tributary_width
    M_type = typeof(qu * l2 * (1.0u"m")^2)
    L_type = typeof(1.0u"m")
    span_moments = NamedTuple{(:span_idx, :ln, :M0, :M_neg_left, :M_pos, :M_neg_right),
                              Tuple{Int, L_type, M_type, M_type, M_type, M_type}}[]
    end_coeffs = βt > 0.0 ? aci_ddm_longitudinal_with_edge_beam(βt) : ACI_DDM_LONGITUDINAL.end_span
    for span_idx in eachindex(frame_line.span_lengths)
        ln = frame_line.span_lengths[span_idx]
        # ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): ℓn in Eq. (13-4)
        # is at least 0.65ℓ1.  A line without center-to-center spans keeps the
        # face-to-face value.
        ln_m0 = hasproperty(frame_line, :center_spans) ?
            eq13_4_clear_span(frame_line.center_spans[span_idx], ln) : ln
        M0 = total_static_moment(qu, l2, ln_m0)
        left_is_ext = column_is_exterior[span_idx]
        right_is_ext = column_is_exterior[span_idx + 1]
        left_fixed = _support_is_wall_fixed(frame_line.columns[span_idx])
        right_fixed = _support_is_wall_fixed(frame_line.columns[span_idx + 1])
        if left_fixed || right_fixed
            # §13.6.3.3 Column (5) for the span that ends on the wall.
            fixed = ACI_DDM_LONGITUDINAL.end_span_fully_restrained
            M_neg_left = (left_fixed ? fixed.ext_neg : fixed.int_neg) * M0
            M_neg_right = (right_fixed ? fixed.ext_neg : fixed.int_neg) * M0
            M_pos = fixed.pos * M0
        elseif method.variant == :simplified
            M_neg_left = 0.65 * M0
            M_neg_right = 0.65 * M0
            M_pos = 0.35 * M0
        elseif left_is_ext || right_is_ext
            M_neg_left = (left_is_ext ? end_coeffs.ext_neg : end_coeffs.int_neg) * M0
            M_neg_right = (right_is_ext ? end_coeffs.ext_neg : end_coeffs.int_neg) * M0
            M_pos = end_coeffs.pos * M0
        else
            M_neg_left = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
            M_neg_right = ACI_DDM_LONGITUDINAL.interior_span.neg * M0
            M_pos = ACI_DDM_LONGITUDINAL.interior_span.pos * M0
        end
        push!(span_moments, (
            span_idx = span_idx,
            ln = ln,
            M0 = M0,
            M_neg_left = M_neg_left,
            M_pos = M_pos,
            M_neg_right = M_neg_right,
        ))
    end
    return span_moments
end

TRACE_REGISTRY[(:_frameline_ddm_gate, :slab)] = TracedFunctionMeta(
    :_frameline_ddm_gate, :slab, [:decision, :failure], nothing, @__FILE__, @__LINE__,
)

"""
ACI 318-11 §13.6.1 (corpus: aci-318-11, page 252) violations that a
`FrameLine` can establish on its own:

- §13.6.1.1 — at least three continuous spans: `frame_line` has ≥ 3 spans.
- §13.6.1.5 — unfactored live load ≤ 2 × unfactored dead load (`qL`, `qD`
  as passed).
- With skeleton geometry (`ctx !== nothing`), from the structural centerlines
  of successive columns measured along / across `frame_line.direction`:
  §13.6.1.2 longer / shorter of the center-to-center span and
  `tributary_width` ≤ 2 (`_DDM_PANEL_ASPECT_MAX`); §13.6.1.3 successive
  center-to-center spans differ by ≤ one-third of the longer; §13.6.1.4 the
  successive column is offset from the frame axis through the previous one
  by ≤ 10% of the span (`_DDM_OFFSET_LIMIT_FRAC`).  Without geometry these
  three are not checked; the gate reads spans from the skeleton, not from
  the FrameLine's stored `center_spans`.

Rectangularity of the panels (§13.6.1.2) needs the slab faces and is
checked only on the slab path (`check_ddm_applicability`).
"""
function _frameline_ddm_violations(struc, frame_line, qD, qL; ctx = nothing)::Vector{String}
    out = String[]
    n_spans = length(frame_line.span_lengths)
    if n_spans < 3
        push!(out, "§13.6.1.1: DDM requires at least 3 continuous spans; the frame line has " *
                   "$(n_spans) (corpus: aci-318-11, page 252)")
    end
    qD_psf, qL_psf = ustrip(psf, qD), ustrip(psf, qL)
    if qL_psf > 2 * qD_psf
        push!(out, "§13.6.1.5: Unfactored live load $(round(qL_psf, digits=1)) psf > 2 × " *
                   "unfactored dead load $(round(qD_psf, digits=1)) psf (corpus: aci-318-11, page 252)")
    end
    ctx === nothing && return out
    d = frame_line.direction
    ax = (Float64(d[1]), Float64(d[2]))
    perp = (-ax[2], ax[1])
    l2_m = ustrip(u"m", frame_line.tributary_width)
    cols = frame_line.columns
    spans = Float64[]
    for k in 1:(length(cols) - 1)
        if col_vertex_idx(cols[k]) <= 0 || col_vertex_idx(cols[k + 1]) <= 0
            push!(spans, NaN)
            continue
        end
        a = _eq137_structural_xy(struc, cols[k])
        b = _eq137_structural_xy(struc, cols[k + 1])
        Δ = (b[1] - a[1], b[2] - a[2])
        along = abs(Δ[1] * ax[1] + Δ[2] * ax[2])
        across = abs(Δ[1] * perp[1] + Δ[2] * perp[2])
        if !(isfinite(along) && isfinite(across)) || along <= 0
            push!(spans, NaN)
            continue
        end
        push!(spans, along)
        if across > _DDM_OFFSET_LIMIT_FRAC * along
            push!(out, "§13.6.1.4: Frame-line column $(k + 1) offset $(round(across, digits=2)) m " *
                       "from the axis through column $(k) > 10% of the " *
                       "$(round(along, digits=2)) m span (corpus: aci-318-11, page 252)")
        end
        if l2_m > 0 && max(along, l2_m) / min(along, l2_m) >
                       _DDM_PANEL_ASPECT_MAX * (1 + _DDM_PANEL_ASPECT_RTOL)
            push!(out, "§13.6.1.2: Frame-line span $(k): longer / shorter span center-to-center = " *
                       "$(round(max(along, l2_m) / min(along, l2_m), digits=2)) > 2 " *
                       "[$(round(along, digits=2)) m × $(round(l2_m, digits=2)) m] " *
                       "(corpus: aci-318-11, page 252)")
        end
    end
    for k in 1:(length(spans) - 1)
        la, lb = spans[k], spans[k + 1]
        (isfinite(la) && isfinite(lb)) || continue
        abs(la - lb) > max(la, lb) / 3 || continue
        push!(out, "§13.6.1.3: Successive frame-line spans $(k) and $(k + 1) center-to-center " *
                   "differ by $(round(abs(la - lb), digits=2)) m > one-third of the longer span " *
                   "[$(round(la, digits=2)) m vs $(round(lb, digits=2)) m] (corpus: aci-318-11, page 252)")
    end
    return out
end

"""
    _frameline_ddm_gate(struc, frame_line, qD, qL, on_inapplicable; ctx, tc)

DDM applicability gate of `run_moment_analysis(::DDM, frame_line, ...)`
(`_frameline_ddm_violations`, ACI 318-11 §13.6.1, corpus: aci-318-11,
page 252).  A FrameLine has no FEA overload to fall back to, so:

- `on_inapplicable = :error` (default) — emits a `:failure` trace event
  (`reason = "ddm_not_applicable"`) and throws `DDMApplicabilityError`; use
  the slab pipeline (`size_flat_plate!` with `method = FEA()`) instead.
- `on_inapplicable = :proceed` — the caller takes responsibility for using
  DDM coefficients outside §13.6.1 (e.g. to study one frame in isolation):
  `@warn`, a `:decision` trace event (`reason = "ddm_not_applicable_proceed"`)
  and the analysis continues.

No violations: nothing is emitted.
"""
function _frameline_ddm_gate(struc, frame_line, qD, qL, on_inapplicable::Symbol;
                             ctx = nothing, tc = nothing)
    on_inapplicable in (:error, :proceed) || throw(ArgumentError(
        "FrameLine DDM on_inapplicable must be :error or :proceed; got :$on_inapplicable"))
    violations = _frameline_ddm_violations(struc, frame_line, qD, qL; ctx = ctx)
    isempty(violations) && return nothing
    if on_inapplicable === :error
        emit!(tc, :slab, "_frameline_ddm_gate", "frame_line", :failure;
              reason = "ddm_not_applicable", violations = violations,
              n_violations = length(violations))
        throw(DDMApplicabilityError(violations, [
            "FEA (Finite Element Analysis) at slab level: size_flat_plate!(...; method=FEA()) " *
            "— there is no FrameLine FEA analysis"]))
    end
    @warn "FrameLine DDM outside ACI 318-11 §13.6.1 (on_inapplicable = :proceed)" violations = join(violations, "; ")
    emit!(tc, :slab, "_frameline_ddm_gate", "frame_line", :decision;
          reason = "ddm_not_applicable_proceed", violations = violations,
          n_violations = length(violations))
    return nothing
end

"""
    run_moment_analysis(method::DDM, frame_line::FrameLine, struc, qu, qD, qL; verbose=false)

Run DDM moment analysis using a FrameLine (multi-span frame strip).

This overload accepts a pre-built FrameLine which already has:
- Columns sorted along the frame direction
- Clear span lengths computed
- Joint positions (exterior/interior) determined

Each support is classified for §13.6.3.3 (corpus: aci-318-11, page 254)
by `_ddm_support_class` along `frame_line.direction`, the same panel
geometry and tag/conformance rule as the single-panel DDM, with the same
trace events.  Only when `struc` carries no skeleton geometry are the
FrameLine `joint_positions` used (traced `no_geometry`).  An `:envelope`
support takes, at every section of its adjacent spans, the larger of the
coefficients with that support exterior and with it interior.

# Arguments
- `method::DDM`: DDM method with variant (:full or :simplified)
- `frame_line::FrameLine`: Pre-built frame strip with columns and spans
- `struc`: BuildingStructure (tributary areas and skeleton geometry)
- `qu::Pressure`: Factored uniform load (1.2D + 1.6L)
- `qD::Pressure`: Service dead load
- `qL::Pressure`: Service live load
- `γ_concrete`: concrete density, used (as in the cell path) for the self-weight
  and drop panel of a neighbour slab beyond a continuous frame end; `nothing`
  falls back to the stored `cell.self_weight` without a drop
- `design_drop::Pressure`: the design slab's service drop pressure already
  included in `qD` (default 0)
- `on_inapplicable::Symbol`: `:error` (default) throws `DDMApplicabilityError`
  when the frame line violates ACI 318-11 §13.6.1 (`_frameline_ddm_gate`;
  there is no FrameLine FEA fallback); `:proceed` continues with a `@warn` and
  a `:decision` trace event, the caller taking responsibility
- `tc`: optional trace collector

# Returns
`MomentAnalysisResult` with all moments and geometry data.

# Example
```julia
# Build frame line from columns
fl = FrameLine(:x, columns, l2, get_pos, get_width)

# Run DDM analysis
result = run_moment_analysis(DDM(), fl, struc, qu, qD, qL)
```
"""
function run_moment_analysis(
    method::DDM,
    frame_line,  # FrameLine{T, C}
    struc,
    qu::Pressure,
    qD::Pressure,
    qL::Pressure;
    verbose::Bool = false,
    βt::Float64 = 0.0,
    γ_concrete = nothing,
    design_drop::Pressure = 0.0psf,
    on_inapplicable::Symbol = :error,
    tc = nothing,
)
    # Extract from FrameLine
    sorted_columns = frame_line.columns
    l2 = frame_line.tributary_width
    n_spans = length(frame_line.span_lengths)
    n_cols = n_spans + 1

    ctx = _eq137_geometry_available(struc) ? _eq137_context(struc, sorted_columns) : nothing
    _frameline_ddm_gate(struc, frame_line, qD, qL, on_inapplicable; ctx = ctx, tc = tc)

    # §13.6.3.3 support classes, as the single-panel DDM classifies them.
    # They drive both the span coefficients and the transfer moments.
    classes = _frameline_support_classes(struc, frame_line; tc = tc, ctx = ctx)
    column_is_exterior = [c != :interior for c in classes]
    span_moments = _frameline_span_moments(method, frame_line, qu, column_is_exterior, βt)
    if any(==(:envelope), classes)
        # An uncertain support takes the larger of its exterior and interior
        # coefficients at every section of its adjacent spans.
        as_interior = _frameline_span_moments(method, frame_line, qu,
                                              [c == :exterior for c in classes], βt)
        span_moments = [merge(a, (M_neg_left = max(a.M_neg_left, b.M_neg_left),
                                  M_pos = max(a.M_pos, b.M_pos),
                                  M_neg_right = max(a.M_neg_right, b.M_neg_right)))
                        for (a, b) in zip(span_moments, as_interior)]
    end
    
    if verbose
        variant_name = method.variant == :simplified ? "MDDM (Simplified)" : "DDM (Full ACI)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS - $variant_name (FrameLine)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Frame direction" dir=frame_line.direction n_spans=n_spans l2=l2
        @debug "Loads" qD=qD qL=qL qu=qu
        @debug "Per-span moments:"
        for sm in span_moments
            ln_ft = round(ustrip(u"ft", sm.ln), digits=2)
            M0_kipft = round(ustrip(kip*u"ft", sm.M0), digits=1)
            @debug "  Span $(sm.span_idx): ln=$(ln_ft) ft, M0=$(M0_kipft) kip-ft"
        end
    end
    
    # Build column-level results — interior columns use ACI 318-11 §13.6.9.2 Eq. (13-7).
    column_moments, column_shears, unbalanced_moments = _compute_column_demands_from_spans(
        struc, sorted_columns, classes, span_moments, qu, qD, qL, l2;
        span_axis = frame_line.direction, ctx = ctx,
        γ = γ_concrete, design_drop = design_drop, tc = tc,
    )
    
    # Representative panel geometry stays the first span. The moments are
    # the envelope of every span, with a wall kept out of the column labels.
    ln = span_moments[1].ln
    l1 = hasproperty(frame_line, :center_spans) ? frame_line.center_spans[1] :
        ln + sum(c.c1 for c in sorted_columns) / n_cols
    M0 = span_moments[1].M0
    env = _envelope_support_moments(span_moments, sorted_columns)
    M_neg_ext = env.M_neg_ext
    M_neg_int = env.M_neg_int
    M_pos = env.M_pos
    
    c1_avg = sum(c.c1 for c in sorted_columns) / n_cols
    
    # Convert to consistent units for MomentAnalysisResult
    # The type system requires homogeneous Moment and Force vectors
    M0_kft = uconvert(kip*u"ft", M0)
    M_neg_ext_kft = uconvert(kip*u"ft", M_neg_ext)
    M_neg_int_kft = uconvert(kip*u"ft", M_neg_int)
    M_pos_kft = uconvert(kip*u"ft", M_pos)
    
    Vu_max = uconvert(kip, qu * l2 * ln / 2)
    
    return MomentAnalysisResult(
        M0_kft,
        M_neg_ext_kft,
        M_neg_int_kft,
        M_pos_kft,
        qu, qD, qL,
        l1, l2, ln, c1_avg,
        column_moments,
        column_shears,
        unbalanced_moments,
        Vu_max;
        M_wall_ext = uconvert(kip*u"ft", env.M_wall_ext),
        M_wall_int = uconvert(kip*u"ft", env.M_wall_int),
        wall_faces = _factored_wall_faces(span_moments, sorted_columns, qu, qD, qL),
    )
end

