function _ddm_support_moment(struc, col, span_axis, M_neg_ext, M_neg_int;
                             index = nothing, vertex_column = nothing,
                             partway = nothing, tc = nothing)
    cls = _ddm_support_class(struc, col, span_axis; index = index,
                             vertex_column = vertex_column, partway = partway, tc = tc)
    cls === nothing && return is_exterior_support(col, span_axis) ? M_neg_ext : M_neg_int
    cls == :interior && return M_neg_int
    cls == :exterior && return M_neg_ext
    return max(M_neg_ext, M_neg_int)
end

"""
§13.6.3.3 support class of `col` along `span_axis` (`_eq137_support_class`
on the vertex-adjacent panels), or `nothing` with a `:fallback` trace event
(`no_geometry`) when the skeleton cannot place the column.

Shared by the single-panel DDM (`_ddm_support_moment`) and the multi-span
FrameLine DDM (`run_moment_analysis(::DDM, frame_line, ...)`), so both
classify a column the same way and emit the same trace events.

A non-finite coordinate at the column, or at any slab-face corner or
column point on its storey (`_eq137_nonfinite_at`), gives `:envelope` with
a `:failure` trace event (`non_finite_vertex`) before any geometry is read.
"""
function _ddm_support_class(struc, col, span_axis;
                            index = nothing, vertex_column = nothing,
                            partway = nothing, tc = nothing)
    stage = "_ddm_support_moment"
    if !_eq137_geometry_available(struc) || col_vertex_idx(col) <= 0
        _eq137_trace_fallback(tc, col, :no_geometry; stage = stage)
        return nothing
    end
    pw = _eq137_partway_at(struc, col, vertex_column, partway)
    if _eq137_nonfinite_at(pw, col)
        # ENGINEERING JUDGMENT: a non-finite vertex cannot be placed, so the
        # class cannot be read.  Flexure takes the larger of the §13.6.3.3
        # interior and exterior moments (corpus: aci-318-11, page 254); the
        # transfer moment at this column is NaN (`_eq137_transfer_moment`),
        # which rejects the connection.
        _eq137_trace_fallback(tc, col, :non_finite_vertex; stage = stage, event = :failure)
        return :envelope
    end
    idx = index === nothing ? _eq137_vertex_cell_index(struc; partway = pw) : index
    panels = _eq137_side_panels(struc, col, span_axis, idx)
    if panels === nothing
        _eq137_trace_fallback(tc, col, :no_geometry; stage = stage)
        return nothing
    end
    nsides = length(unique(p.side for p in panels))
    return _eq137_support_class(struc, col, span_axis, idx, vertex_column, nsides;
                                partway = pw, tc = tc, stage = stage)
end

"""
Eq. (13-7) at one column.  `M0` is required for the edge and re-entrant
transfers; without it those cases return 0.  Two continuous sides do not
use `M0`.
"""
function _interior_mub_for_column(struc, slab, col, span_axis,
                                  qD::Pressure, qL::Pressure, l2::Length, ln::Length;
                                  c_override=nothing, extra_columns=(),
                                  M0=nothing, γ=nothing, index=nothing,
                                  vertex_column=nothing, cell_slab=nothing,
                                  partway=nothing,
                                  design_drop::Pressure=0.0psf, tc=nothing)
    return _eq137_transfer_moment(
        struc, slab, col, span_axis, qD, qL, l2, ln, M0;
        c_override=c_override, extra_columns=extra_columns, γ=γ, index=index,
        vertex_column=vertex_column, cell_slab=cell_slab, partway=partway,
        design_drop=design_drop, tc=tc,
    )
end


"""
    _compute_column_demands_ddm(struc, columns, M_neg_ext, M_neg_int, M_pos,
                                 qu, qD, qL, l2, ln, span_axis, M0;
                                 slab=nothing, c_override=nothing)

Compute column-level demands for simplified DDM (single panel approach).

For each column:
- Exterior columns: design moment = M_neg_ext (ACI 318-11 §13.6.3.3 end-span
  coefficient × M0, e.g. 0.26 M0 for a flat plate without edge beam).
  Unbalanced *transfer* moment = 0.3 M0 per ACI 318-11 §13.6.3.6.
- Interior columns: design moment = M_neg_int; the *unbalanced* moment
  for punching shear is the live-load-pattern moment from
  ACI 318-11 §13.6.9.2 Eq. (13-7):

      Mu = 0.07·[(qDu + 0.5·qLu)·ℓ2·ℓn² − qDu'·ℓ2'·(ℓn')²]                (13-7)

  where the primed quantities refer to the *shorter* of the two adjacent
  spans.  Each interior column is evaluated from the panels that actually
  share that support along `span_axis` (`_interior_mub_for_column`).
  Eq. (13-7) is taken as the larger of §9.2.1 Eq. (9-1) and Eq. (9-2)
  (`governing_interior_unbalanced_moment`).  Equal adjoining spans
  collapse to Mu = 0.07·0.5·q_Lu·ℓ2·ℓn² under Eq. (9-2).  Two candidate
  panels on the same side that disagree throw `ArgumentError`.

`M0` is the total factored static moment already computed for this panel
from the same `qu`, `l2`, `ln` via ACI 318-11 §13.6.2.2 Eq. (13-4)
(M0 = qu ℓ2 ℓn² / 8).  It is reused, not recomputed.

# Interpretation (column design moment vs transfer moment)

ACI 318-11 §13.6.3.6 states: "The gravity load moment to be transferred
between slab and edge column in accordance with 13.5.3.1 shall be 0.3 Mo."
§13.5.3.1 is the slab-column *connection* transfer (γf by flexure, γv by
eccentric shear / punching).  PCA Notes (EB712, Part 16 p.483 and Part 19
p.555) apply 0.3 Mo only to that transfer check, while slab flexure remains
the §13.6.3.3 exterior-negative coefficient (0.26 Mo without edge beam).

ENGINEERING JUDGMENT: `column_moments` (column/slab flexural design) is
kept as M_neg_ext per §13.6.3.3.  `unbalanced_moments` (connection transfer
/ punching) is 0.3 M0 per §13.6.3.6.  Interior Eq. (13-7) is unchanged.
Do **not** use 0.3 Mo for interior columns (exterior §13.6.3.6 only).

# References
- ACI 318-11 §13.6.2.2 / Eq. (13-4) (corpus: aci-318-11, page 253)
- ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254)
- ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255)
- ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250)
- ACI 318-11 §13.6.9.2 / Eq. (13-7) (corpus: aci-318-11, page 258)
- PCA EB712 Part 16 (corpus: pca-eb712, page 483) and Part 19 (page 555)
"""
function _compute_column_demands_ddm(struc, columns, M_neg_ext, M_neg_int, M_pos,
                                     qu, qD, qL, l2, ln, span_axis, M0;
                                     slab = nothing,
                                     c_override = nothing,
                                     γ = nothing,
                                     design_drop::Pressure = 0.0psf,
                                     tc = nothing,
                                     ctx = nothing)
    column_moments = Vector{typeof(1.0kip*u"ft")}()
    column_shears = Vector{typeof(1.0kip)}()
    unbalanced_moments = Vector{typeof(1.0kip*u"ft")}()

    # Cell→slab and vertex→column maps, once per analysis call.
    context = ctx === nothing ? _eq137_context(struc, columns) : ctx
    partway = hasproperty(context, :partway) ? context.partway : nothing

    for col in columns
        # Flexural (§13.6.3.3) and transfer moments share one continuity
        # test along `span_axis` (`_eq137_support_class`): interior-negative
        # and Eq. (13-7) where the slab continues on both sides,
        # exterior-negative and 0.3 M0 where it does not.
        M = _ddm_support_moment(struc, col, span_axis, M_neg_ext, M_neg_int;
                                index = context.index,
                                vertex_column = context.vertex_column,
                                partway = partway, tc = tc)
        Mub = _eq137_transfer_moment(
            struc, slab, col, span_axis, qD, qL, l2, ln, M0;
            c_override = c_override, extra_columns = columns,
            index = context.index, vertex_column = context.vertex_column,
            cell_slab = context.cell_slab, partway = partway,
            design_drop = design_drop, γ = γ, tc = tc,
        )

        push!(column_moments, uconvert(kip*u"ft", M))
        push!(unbalanced_moments, uconvert(kip*u"ft", Mub))

        Vu = _compute_column_shear(struc, col, qu, l2, ln)
        push!(column_shears, Vu)
    end

    return column_moments, column_shears, unbalanced_moments
end

"""
    _compute_column_demands_from_spans(struc, sorted_columns, column_is_exterior,
                                        span_moments, qu, qD, qL, l2)

Compute column-level demands from per-span DDM moments (multi-span version).

The flexural moments come from `span_moments`, whose span-end coefficients
the caller chose from each support's class (`_ddm_support_class` in the
FrameLine `run_moment_analysis`), so a column gets the exterior- or
interior-negative moment by the same rule as the single-panel DDM.

The transfer moment follows each support's class, as in the cell path
(`_eq137_transfer_moment`).  `column_is_exterior` holds the classes
(`:interior`, `:exterior`, `:envelope`); a `Bool` entry is read as
`:exterior` (true) or `:interior` (false).

For each column:
- End columns: design moment = M_neg from the adjacent span (§13.6.3.3).
  `:exterior`: transfer moment = 0.3 M0 of that adjacent end span
  (ACI 318-11 §13.6.3.6), where M0 is the span's already-computed
  Eq. (13-4) static moment (`span_moments[i].M0`).  `:interior` or
  `:envelope`: the slab continues beyond the frame end, and the span beyond
  is resolved from panel geometry (`_frameline_end_transfer`); without
  geometry the result is NaN with a `:failure` trace event.
- Columns between two spans: design moment = max of M_neg from the two
  adjacent spans.  `:exterior`: 0.3 M0 (`_frameline_middle_edge_moment`).
  `:envelope`: the larger of Eq. (13-7) and 0.3 M0.  `:interior`:
  unbalanced moment per ACI 318-11 §13.6.9.2 Eq. (13-7) using the actual ℓn
  of the longer / shorter adjacent span.  Service `qD`/`qL` are factored
  under both §9.2.1 Eq. (9-1) and Eq. (9-2) and the larger Mu is kept
  (`governing_interior_unbalanced_moment`):

      Mu = 0.07·[(qDu + 0.5·qLu)·ℓ2·ℓn² − qDu'·ℓ2'·(ℓn')²]               (13-7)

  where the primed quantities refer to the *shorter* of the two adjacent
  spans.  In this multi-span path ℓ2 is constant across spans (one tributary
  width is used for the whole frame) but ℓn may vary; both bays carry the
  frame's `qD`/`qL`.  Do not pass only the combination that maximises `q_u`.
- A column flagged non-finite by the neighbourhood index
  (`_eq137_nonfinite_at`) gets a NaN transfer moment with a `:failure`
  trace event (`non_finite_vertex`), as in the cell path.

# Interpretation

Same split as `_compute_column_demands_ddm`: `column_moments` stay the
§13.6.3.3 flexural assignment; `unbalanced_moments` at exterior columns
are the §13.6.3.6 transfer moment 0.3 M0.  See that function's docstring.
Do **not** use 0.3 Mo for interior columns.

# Arguments
- `struc`: BuildingStructure (for tributary area lookup)
- `sorted_columns`: Columns ordered along span axis
- `column_is_exterior`: support class (or Bool) for each column (already applied to `span_moments`)
- `span_moments`: Vector of per-span moment results (includes `M0`)
- `qu`, `qD`, `qL`: Factored total, service dead, and service live pressures
- `l2`: Tributary width
- `span_axis`: frame direction (needed to resolve geometry); `ctx`: `_eq137_context`
  or `nothing` without geometry; `tc`: optional trace collector
- `γ`: concrete density for neighbour self-weight and drop panels beyond a
  continuous frame end (`_frameline_end_transfer`); `design_drop`: the design
  slab's service drop pressure already included in `qD`
- A negative service `qD` or `qL` is invalid input (§13.6.1.5, gravity
  loads): every transfer moment is NaN with a `:failure` trace event
  (`negative_service_load`)
- A negative or non-finite span `ln` is invalid input: the transfer moment
  of every column adjoining that span (end or middle) is NaN with a
  `:failure` trace event (`negative_span`)

# References
- ACI 318-11 §13.6.2.2 / Eq. (13-4) (corpus: aci-318-11, page 253)
- ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255)
- ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250)
- ACI 318-11 §13.6.9.2 / Eq. (13-7) (corpus: aci-318-11, page 258)
"""
function _compute_column_demands_from_spans(struc, sorted_columns, column_is_exterior,
                                            span_moments, qu, qD, qL, l2;
                                            span_axis = nothing, ctx = nothing,
                                            γ = nothing,
                                            design_drop::Pressure = 0.0psf,
                                            tc = nothing)
    n_cols = length(sorted_columns)
    column_moments = Vector{typeof(1.0kip*u"ft")}()
    column_shears = Vector{typeof(1.0kip)}()
    unbalanced_moments = Vector{typeof(1.0kip*u"ft")}()
    classes = [c isa Symbol ? c : (c ? :exterior : :interior) for c in column_is_exterior]
    stage = "_compute_column_demands_from_spans"
    negative_load = _eq137_negative_input(qD, qL)

    function nonfinite_failure(col)
        (ctx === nothing || ctx.partway === nothing) && return false
        _eq137_nonfinite_at(ctx.partway, col) || return false
        _eq137_trace_fallback(tc, col, :non_finite_vertex; stage = stage, event = :failure)
        return true
    end

    # A negative or non-finite clear span is invalid frame input; every
    # column it adjoins gets a NaN transfer moment (`transfer_section_inadequate`).
    bad_span(sm) = !isfinite(ustrip(u"ft", sm.ln)) || sm.ln < zero(sm.ln)
    function span_failure(col, spans...)
        any(bad_span, spans) || return false
        _eq137_trace_fallback(tc, col, :negative_span; stage = stage, event = :failure)
        return true
    end

    for (i, col) in enumerate(sorted_columns)
        cls = classes[i]
        bad_geometry = nonfinite_failure(col)
        if i == 1 || i == n_cols
            # End column.  Its frame span lies on side +1 of `span_axis` for
            # the first column and −1 for the last (columns are sorted
            # along the frame direction).
            sm = i == 1 ? span_moments[1] : span_moments[end]
            M = i == 1 ? sm.M_neg_left : sm.M_neg_right
            bad_geometry |= span_failure(col, sm)
            Mub = if negative_load
                _eq137_negative_load_failure(tc, col, stage)
            elseif bad_geometry
                NaN * kip * u"ft"
            elseif cls == :exterior
                # ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255):
                # 0.3 M0 of the adjacent end span.
                0.3 * sm.M0
            else
                _frameline_end_transfer(struc, col, span_axis, i == 1 ? 1 : -1,
                                        qD, qL, l2, sm.ln, sm.M0, sorted_columns, ctx;
                                        γ = γ, design_drop = design_drop, tc = tc)
            end
            ln_for_shear = sm.ln
        else
            # span_moments[i-1] is the span to the LEFT (side −1),
            # span_moments[i] to the RIGHT (side +1).
            M_from_left_span  = span_moments[i-1].M_neg_right
            M_from_right_span = span_moments[i].M_neg_left
            M = max(M_from_left_span, M_from_right_span)

            ln_left  = span_moments[i-1].ln
            ln_right = span_moments[i].ln
            bad_geometry |= span_failure(col, span_moments[i-1], span_moments[i])
            # ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258)
            # under both §9.2.1 Eq. (9-1) and Eq. (9-2) (page 123).
            Mu137() = governing_interior_unbalanced_moment(
                qD, qL, l2, ln_left, qD, qL, l2, ln_right)
            Mub = if negative_load
                _eq137_negative_load_failure(tc, col, stage)
            elseif bad_geometry
                NaN * kip * u"ft"
            elseif cls == :interior
                Mu137()
            elseif cls == :exterior
                _frameline_middle_edge_moment(struc, col, span_axis,
                                              span_moments[i-1].M0, span_moments[i].M0,
                                              ctx; tc = tc)
            else
                # `:envelope` (re-entrant corner or ambiguous neighbourhood), as
                # in `_eq137_transfer_moment`: the larger of Eq. (13-7) and
                # §13.6.3.6 0.3 M0 (corpus: aci-318-11, page 255).
                # ENGINEERING JUDGMENT: the exterior side is not known, so
                # 0.3 M0 is taken from the larger adjoining span.
                max(uconvert(kip * u"ft", Mu137()),
                    uconvert(kip * u"ft", 0.3 * max(span_moments[i-1].M0, span_moments[i].M0)))
            end

            ln_for_shear = (ln_left + ln_right) / 2
        end

        push!(column_moments, uconvert(kip*u"ft", M))
        push!(unbalanced_moments, uconvert(kip*u"ft", Mub))

        Vu = _compute_column_shear(struc, col, qu, l2, ln_for_shear)
        push!(column_shears, Vu)
    end

    return column_moments, column_shears, unbalanced_moments
end

TRACE_REGISTRY[(:_compute_column_demands_from_spans, :slab)] = TracedFunctionMeta(
    :_compute_column_demands_from_spans, :slab, [:fallback, :failure], nothing,
    @__FILE__, @__LINE__,
)

"""
§13.6.3.6 transfer at a FrameLine middle column classed `:exterior`
(ACI 318-11, corpus: aci-318-11, page 255): 0.3 M0 of the frame span on
the side where the vertex-adjacent panels lie (`_eq137_side_panels`).
"""
function _frameline_middle_edge_moment(struc, col, span_axis, M0_left, M0_right, ctx;
                                       tc = nothing)
    if span_axis !== nothing && ctx !== nothing && ctx.index !== nothing
        axis = (Float64(span_axis[1]), Float64(span_axis[2]))
        panels = _eq137_side_panels(struc, col, axis, ctx.index)
        if panels !== nothing
            sides = unique(p.side for p in panels)
            length(sides) == 1 && return 0.3 * (only(sides) == 1 ? M0_right : M0_left)
        end
    end
    # ENGINEERING JUDGMENT: panel geometry does not say which frame span the
    # slab is on, so 0.3 M0 is taken from the larger adjoining span.
    _eq137_trace_fallback(tc, col, :frameline_exterior_side_unknown;
                          stage = "_compute_column_demands_from_spans")
    return 0.3 * max(M0_left, M0_right)
end

"""
Transfer moment at a FrameLine end column classed `:interior` or
`:envelope`: the slab continues beyond the frame end, so the span beyond is
not in the FrameLine.

With skeleton geometry this is the cell path (`_eq137_transfer_moment`) at
that column along `span_axis`, so both adjoining spans are resolved from the
panels exactly as in the single-panel DDM, with the frame span's `qD`,
`ℓ2`, `ℓn` and `M0` as the panel in hand.  `inner` is the side (+1 / −1) of
`span_axis` on which the frame span lies; the owning slab of those cells is
the design slab (a stand-in holding only those cells when no slab owns
them), so their trial self-weight comes from `qD`.  `γ` (concrete density)
and `design_drop` (the design slab's service drop pressure, already in
`qD`) are passed through as in the cell path, so a neighbour slab beyond
the frame end is charged its own result thickness and drop panel
(`_eq137_neighbour_sw`, `_eq137_neighbour_drop`).

Without geometry that places the column, the span beyond cannot be
resolved: a `:failure` trace event (`frameline_end_beyond_span_unresolved`)
is emitted and NaN is returned, which `transfer_section_inadequate` rejects.
Geometry that places the column but whose sides are ambiguous
(`ArgumentError` from `_eq137_resolved_sides`) likewise returns NaN with a
`:failure` trace event (`adjoining_spans_unresolved`).
"""
function _frameline_end_transfer(struc, col, span_axis, inner::Int,
                                 qD, qL, l2, ln, M0, frame_columns, ctx;
                                 γ = nothing, design_drop::Pressure = 0.0psf,
                                 tc = nothing)
    sides = nothing
    axis = nothing
    if span_axis !== nothing && ctx !== nothing && ctx.index !== nothing
        axis = (Float64(span_axis[1]), Float64(span_axis[2]))
        sides = try
            _eq137_resolved_sides(struc, nothing, col, axis;
                                  extra_columns = frame_columns, index = ctx.index,
                                  vertex_column = ctx.vertex_column,
                                  partway = ctx.partway)
        catch e
            e isa ArgumentError || rethrow()
            # Ambiguous geometry (§13.6.9.2, corpus: aci-318-11, page 258):
            # rejected as in `_eq137_transfer_moment`, never an abort.
            _eq137_trace_fallback(tc, col, :adjoining_spans_unresolved;
                                  stage = "_compute_column_demands_from_spans",
                                  event = :failure)
            return NaN * kip * u"ft"
        end
    end
    if sides === nothing
        # ENGINEERING JUDGMENT: neither §13.6.3.6 (0.3 M0, an edge column) nor
        # Eq. (13-7) with an assumed span beyond is grounded for a column the
        # slab continues past, so the transfer demand is left undefined and
        # the connection is rejected rather than sized on a guess.
        _eq137_warn_once(:frameline_end_unresolved,
            "FrameLine end column is classed continuous but the span beyond the frame end cannot be resolved without skeleton geometry; its transfer moment is undefined and the connection is rejected.")
        _eq137_trace_fallback(tc, col, :frameline_end_beyond_span_unresolved;
                              stage = "_compute_column_demands_from_spans",
                              event = :failure)
        return NaN * kip * u"ft"
    end
    k = findfirst(s -> s.side == inner, sides)
    slab = nothing
    if !isempty(sides)
        own = sides[something(k, 1)]
        slab = something(_eq137_owning_slab(ctx.cell_slab, struc, own.cell_index),
                         (cell_indices = own.cell_indices,))
    end
    return _eq137_transfer_moment(
        struc, slab, col, axis, qD, qL, l2, ln, M0;
        extra_columns = frame_columns, index = ctx.index,
        vertex_column = ctx.vertex_column, cell_slab = ctx.cell_slab,
        partway = ctx.partway, design_drop = design_drop, γ = γ, tc = tc,
    )
end

# _compute_column_shear is defined in common.jl (shared between DDM and EFM)

