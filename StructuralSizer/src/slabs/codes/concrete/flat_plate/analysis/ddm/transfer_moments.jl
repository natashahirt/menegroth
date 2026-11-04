function _eq137_support_class(struc, col, span_axis, idx, vertex_column, nsides::Int;
                              partway = nothing, tc = nothing, stage::String)
    pw = _eq137_partway_at(struc, col, vertex_column, partway)
    vi = col_vertex_idx(col)
    if vi in pw.merged
        # ENGINEERING JUDGMENT (`_EQ137_COINCIDE_M`): a face with a corner at
        # the column point adjoins the column whatever vertex index it uses,
        # so it enters the continuity test and Eq. (13-7) as a panel there.
        _eq137_trace_fallback(tc, col, :duplicate_vertex_merged; stage = stage,
                              event = :decision)
    end
    if !isempty(get(pw.near, vi, Int[]))
        # USER DECISION / ENGINEERING JUDGMENT: a face this close to the
        # column that does not adjoin it may be a panel hidden by a
        # T-junction or an unmerged vertex, or a slab across a joint.  The
        # skeleton has no joint flag, so neither can be shown.  Flexure takes
        # the larger of the §13.6.3.3 coefficients (corpus: aci-318-11,
        # page 254); transfer takes the larger of §13.6.3.6 0.3 M0 (page 255)
        # and Eq. (13-7) (§13.6.9.2, page 258) with the nearby faces counted
        # as adjoining (`_eq137_transfer_moment`).
        _eq137_warn_once(:ambiguous_neighbourhood_envelope,
            "A slab face near a column neither adjoins it nor continues its panels, so slab continuity there is uncertain; using the larger of the interior and exterior moments.")
        _eq137_trace_fallback(tc, col, :ambiguous_neighbourhood_envelope; stage = stage,
                              event = :decision)
        return :envelope
    end
    if nsides == 2 && _eq137_quadrant_count(struc, col, idx, span_axis) == 3
        # USER DECISION / ENGINEERING JUDGMENT: a re-entrant corner is
        # continuous on both sides in this direction and is also a plan
        # edge.  §13.6.3.3 (page 254) and R13.6.9 do not address an L-plan.
        # Flexure takes the larger coefficient; transfer takes the larger of
        # Eq. (13-7) and §13.6.3.6 0.3 M0 (corpus: aci-318-11, page 255).
        _eq137_trace_fallback(tc, col, :reentrant_corner; stage = stage, event = :decision)
        return :envelope
    end
    if nsides == 2 && _eq137_far_uncertain(struc, col, span_axis, idx, vertex_column, pw)
        # ENGINEERING JUDGMENT: slab on both sides, but a far support is not a
        # column the slab is shown to reach (`_eq137_far_support`: a slab
        # end, a gap shorter than the column neighbourhood, or a face near
        # the far column that neither adjoins it nor is explained).  Flexure
        # takes the larger §13.6.3.3 coefficient (corpus: aci-318-11,
        # page 254); transfer takes the larger of §13.6.3.6 0.3 M0
        # (page 255) and Eq. (13-7) (§13.6.9.2, page 258) over the admitted
        # clear spans (`_eq137_resolved_sides` `ln_range`).
        _eq137_warn_once(:uncertain_far_support,
            "A far support on this frame line is not a column the slab is shown to reach; using the larger of the interior and exterior moments and Eq. (13-7) over the admissible clear spans.")
        _eq137_trace_fallback(tc, col, :uncertain_far_support_envelope; stage = stage,
                              event = :decision)
        return :envelope
    end
    if nsides == 0 && !_eq137_edge_like(struc, col, span_axis, idx)
        # ENGINEERING JUDGMENT: geometry is present but no panel touches this
        # interior-tagged column, so it cannot be shown to be either kind of
        # support.  A column nudged off its panels may be an edge or corner.
        _eq137_warn_once(:zero_sides,
            "Eq. (13-7) found a column tagged interior but no panel on either side of the frame line; using the larger of the interior and exterior moments.")
        _eq137_trace_fallback(tc, col, :zero_sides; stage = stage)
        return :envelope
    end
    trust = _eq137_tag_trust(struc, col, span_axis, idx, vertex_column, nsides < 2;
                             partway = pw)
    if trust == :envelope
        # USER DECISION / ENGINEERING JUDGMENT: an adjoining face is not a
        # proper panel (another column lies partway along it), so its depth
        # and far support cannot be trusted.  Take the larger of the
        # interior and exterior moments.
        reason = _eq137_nonconforming_reason(col, span_axis, nsides)
        _eq137_warn_once(reason,
            "A panel at this column has another column partway along its edge, so slab continuity along this frame line is uncertain; using the larger of the interior and exterior moments.")
        _eq137_trace_fallback(tc, col, reason; stage = stage)
        return :envelope
    end
    if nsides == 2
        trust == :geometry && _eq137_trace_fallback(tc, col, :exterior_tag_two_sided; stage = stage)
        return :interior
    end
    if nsides == 1
        if trust == :geometry
            _eq137_warn_once(:one_sided_interior,
                "Interior column has slab on only one side of this frame line; treating it as an exterior support rather than repeating that panel.")
            _eq137_trace_fallback(tc, col, :one_sided_interior; stage = stage)
        end
    else
        # ACI 318-11 §13.6.3.6 (page 255) / §13.6.3.3 (page 254): an edge or
        # corner column nudged off its panels is still an exterior support.
        _eq137_warn_once(:exterior_no_panel,
            "Edge or corner column has no panel on either side of this frame line; treating it as an exterior support, not the equal-span pattern.")
        _eq137_trace_fallback(tc, col, :exterior_no_panel; stage = stage)
    end
    return :exterior
end

"""
Transfer moment at one column along `span_axis`.

The support is classified by `_eq137_support_class`.  `:interior`:
Eq. (13-7).  `:exterior`: §13.6.3.6, 0.3 M0 (the one panel is not
repeated).  `:envelope` with two sides (re-entrant corner, ambiguous
neighbourhood, uncertain far support, or exterior tag at a non-conforming
panel): the larger of Eq. (13-7) and 0.3 M0.  `:envelope` with fewer sides
(ambiguous neighbourhood, non-conforming panel, or a column tagged
interior that touches no panel): the larger of the equal-span pattern of
the panel in hand and 0.3 M0.  In an ambiguous neighbourhood either
envelope also takes Eq. (13-7) with the nearby faces counted as adjoining;
if those faces cannot be read as panels (`ArgumentError` from
`_eq137_resolved_sides`), NaN with a `:failure` trace event
(`near_faces_unresolved`), never an abort.  Likewise an `ArgumentError`
from resolving the adjoining sides themselves (ambiguous geometry,
§13.6.9.2) returns NaN with a `:failure` trace event
(`adjoining_spans_unresolved`).

Eq. (13-7) is evaluated at both ends of each side's admitted clear-span
range (`ln_range`, `_eq137_resolved_sides`) and the largest magnitude is
used; for a side whose far support is a column the slab reaches, the range
is the one clear span.

No geometry: the position fallback, and an interior equal-span pattern is
warned once.  Every fallback emits `:fallback`.

A non-finite coordinate at the column vertex, or at any slab-face corner
or column point on its storey (`_eq137_nonfinite_at`), returns NaN with a
`:failure` trace event (`non_finite_vertex`) before any geometry is read,
so `transfer_section_inadequate` rejects the connection.  A negative service `qD` / `qL`, or a negative side line load
from the adjoining cells, returns NaN with a `:failure` trace event
(`negative_service_load`; §13.6.1.5, corpus: aci-318-11, page 252).
"""
function _eq137_transfer_moment(struc, slab, col, span_axis,
                                qD::Pressure, qL::Pressure, l2::Length, ln::Length,
                                M0;
                                c_override=nothing, extra_columns=(),
                                index=nothing, vertex_column=nothing,
                                cell_slab=nothing, partway=nothing,
                                design_drop::Pressure=0.0psf,
                                γ=nothing, tc=nothing)
    stage = "_eq137_transfer_moment"
    _eq137_negative_input(qD, qL) && return _eq137_negative_load_failure(tc, col, stage)
    vcol = vertex_column === nothing ? _eq137_vertex_column_map(struc, extra_columns) : vertex_column
    cslab = cell_slab === nothing ? _eq137_cell_slab_map(struc) : cell_slab
    idx = index
    pw = nothing
    if _eq137_geometry_available(struc) && col_vertex_idx(col) > 0
        pw = _eq137_partway_at(struc, col, vcol, partway)
        idx === nothing && (idx = _eq137_vertex_cell_index(struc; partway = pw))
        if _eq137_nonfinite_at(pw, col)
            _eq137_trace_fallback(tc, col, :non_finite_vertex; stage = stage,
                                  event = :failure)
            return NaN * kip * u"ft"
        end
    end
    sides = try
        _eq137_resolved_sides(struc, slab, col, span_axis;
                              c_override=c_override, extra_columns=extra_columns,
                              index=idx, vertex_column=vcol, partway=pw, tc=tc)
    catch e
        e isa ArgumentError || rethrow()
        # ENGINEERING JUDGMENT: the adjoining spans cannot be read from the
        # geometry (§13.6.9.2 ambiguous geometry, corpus: aci-318-11,
        # page 258: a face across the frame line with no column line on
        # one side, coincident far columns with different faces, or column
        # faces that consume the span).  The connection is rejected (NaN)
        # rather than sized on a guess, and the design is not aborted.
        _eq137_trace_fallback(tc, col, :adjoining_spans_unresolved; stage = stage,
                              event = :failure)
        return NaN * kip * u"ft"
    end
    equal_span() = governing_interior_unbalanced_moment(qD, qL, l2, ln, qD, qL, l2, ln)
    if sides === nothing
        if _eq137_position_exterior(col, span_axis)
            _eq137_trace_fallback(tc, col, :no_geometry_exterior)
            return _eq137_edge_moment(M0)
        end
        _eq137_warn_once(:no_geometry,
            "Eq. (13-7) has no skeleton geometry for this column; using the equal-span pattern of the panel in hand.")
        _eq137_trace_fallback(tc, col, :no_geometry)
        return equal_span()
    end
    sw_trial = _eq137_sw_trial(struc, slab, qD)
    function two_sided(a, b)
        wD_a, wL_a = _eq137_side_lines(struc, slab, a, sw_trial, γ;
                                       cell_slab=cslab, design_drop=design_drop, tc=tc)
        wD_b, wL_b = _eq137_side_lines(struc, slab, b, sw_trial, γ;
                                       cell_slab=cslab, design_drop=design_drop, tc=tc)
        if _eq137_negative_input(wD_a, wL_a, wD_b, wL_b)
            return _eq137_negative_load_failure(tc, col, stage)
        end
        # Eq. (13-7) magnitude is convex in each ℓn², so over each side's
        # admitted clear spans (`ln_range`, `_eq137_resolved_sides`) the
        # largest value is at an end of the range.
        Mu = zero(1.0kip * u"ft")
        for la in unique(a.ln_range), lb in unique(b.ln_range)
            M = uconvert(kip * u"ft", _eq137_governing_line_loads(wD_a, wL_a, la, wD_b, wL_b, lb))
            isfinite(M) || return M
            Mu = max(Mu, M)
        end
        return Mu
    end
    edge = uconvert(kip * u"ft", _eq137_edge_moment(M0))
    # ENGINEERING JUDGMENT: a face near the column that does not adjoin it
    # (`_eq137_support_class`, ambiguous neighbourhood) may be the hidden far
    # side, so the envelope also takes Eq. (13-7) (corpus: aci-318-11,
    # page 258) with those faces counted as adjoining.
    # `_eq137_resolved_sides` reads the index only at the column vertex, so a
    # one-entry index is enough.
    function with_near(Mu_env)
        vi = col_vertex_idx(col)
        near = get(pw.near, vi, Int[])
        isempty(near) && return Mu_env
        near_idx = Dict(vi => union(get(idx, vi, Int[]), near))
        sides_near = try
            _eq137_resolved_sides(struc, slab, col, span_axis;
                                  c_override=c_override, extra_columns=extra_columns,
                                  index=near_idx, vertex_column=vcol,
                                  partway=pw, tc=tc)
        catch e
            e isa ArgumentError || rethrow()
            # ENGINEERING JUDGMENT: the nearby faces cannot be read as
            # panels (for example a face across the frame line with no
            # column line on one side), so the envelope's Eq. (13-7) reading
            # is undefined.  The connection is rejected (NaN) rather than
            # sized on the readings that could be evaluated, and the design
            # is not aborted.
            _eq137_trace_fallback(tc, col, :near_faces_unresolved; stage = stage,
                                  event = :failure)
            return NaN * kip * u"ft"
        end
        length(sides_near) == 2 || return Mu_env
        return max(Mu_env, uconvert(kip * u"ft", two_sided(sides_near[1], sides_near[2])))
    end
    if length(sides) < 2
        cls = _eq137_support_class(struc, col, span_axis, idx, vcol, length(sides);
                                   partway = pw, tc = tc, stage = stage)
        # ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255): the gravity
        # moment transferred between the slab and an edge column is 0.3 M0.
        # An uncertain support takes the larger of that, the equal-span
        # pattern of the panel in hand, and Eq. (13-7) with the nearby faces
        # (see `_eq137_support_class`).
        cls == :envelope || return _eq137_edge_moment(M0)
        return with_near(max(uconvert(kip * u"ft", equal_span()), edge))
    end

    Mu = two_sided(sides[1], sides[2])
    cls = _eq137_support_class(struc, col, span_axis, idx, vcol, 2;
                               partway = pw, tc = tc, stage = stage)
    # Re-entrant corner, ambiguous neighbourhood, or an exterior tag at a
    # non-conforming panel: the larger of Eq. (13-7) and §13.6.3.6 0.3 M0
    # (corpus: aci-318-11, page 255).
    cls == :envelope && return with_near(max(uconvert(kip * u"ft", Mu), edge))
    return Mu
end

"""
Negative flexural moment at one column along `span_axis`.

ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254): an end span takes the
exterior-negative moment at the exterior edge and the interior-negative
moment at the interior support.  The support is classified by the same
panel geometry as `_eq137_transfer_moment`, so the flexural and transfer
moments agree on which columns are continuous in this direction.

Slab on both sides: `M_neg_int`.  One side: `M_neg_ext`.  The rule,
including the re-entrant corner, the ambiguous neighbourhood (T-junction,
unmerged vertex, or nearby face across a gap), and a column touching no
panel, is `_eq137_support_class`; an `:envelope` class takes the larger of
the two.  No geometry: `is_exterior_support`.  Each of these choices is
traced.
"""
