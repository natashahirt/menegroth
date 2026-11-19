"""
    _column_Ec(columns, column_concrete, fc_slab, γ_slab) -> Pressure

Column modulus Ec (ACI 318-11 §8.5.1, aci-318-11 p. 115) for the analysis
stubs. The concrete is the first real column's own `concrete` when set, then
`column_concrete`, then the slab's f′c and density. Wall joints are skipped.
"""
function _column_Ec(columns, column_concrete, fc_slab, γ_slab)
    conc = column_concrete
    for col in columns
        hasproperty(col, :wall_fixed) && continue
        if hasproperty(col, :concrete) && col.concrete !== nothing
            conc = col.concrete
            break
        end
    end
    conc === nothing && return Ec(fc_slab, ustrip(pcf, γ_slab))
    return Ec(conc.fc′, ustrip(pcf, conc.ρ))
end

"""Story height of a real column. A wall joint copies that height and is skipped."""
function _get_column_height(columns)
    fallback = nothing
    for col in columns
        hasproperty(col, :base) && hasproperty(col.base, :L) || continue
        if hasproperty(col, :wall_fixed)
            fallback === nothing && (fallback = col.base.L)
            continue
        end
        return col.base.L
    end
    fallback === nothing || return fallback
    error("Cannot determine column height: columns[1].base.L not available. " *
          "Ensure column geometry is set before EFM analysis.")
end

"""Cross-section shape of a real column on the line."""
function _line_column_shape(columns)
    for col in columns
        hasproperty(col, :wall_fixed) && continue
        return col_shape(col)
    end
    return :rectangular
end

"""
Equivalent uniform pressure for one column under a per-span pattern.

ENGINEERING JUDGMENT: the column tributary is split equally between the
adjacent spans. ACI 318-11 §13.7.6.4 (corpus: aci-318-11, page 261) keeps
the all-panels full-load shear as a lower bound; the envelope applies that
bound, this split does not.
"""
function _pattern_shear_pressure(qu, qu_per_span, i::Int, n_cols::Int)
    qu_per_span === nothing && return qu
    i == 1 && return qu_per_span[1]
    i == n_cols && return qu_per_span[end]
    return (qu_per_span[i - 1] + qu_per_span[i]) / 2
end

function _raise_abs(current, candidate)
    return abs(candidate) > abs(current) ? candidate : current
end

# `_wall_support` always carries `wall_fixed`. A half-strip wall is a
# column joint (`wall_fixed` false) and still is not a floor column.
_is_wall_support(col) = hasproperty(col, :wall_fixed)

"""
    _with_face_moments(span_moments, spans, columns, qu_arg; drop_loads=nothing)

Add `M_face_left` and `M_face_right` to each span: the negative moment at
the critical section of ACI 318-11 §13.7.7.1 (corpus: aci-318-11, page 262),
from the span's statics under its own load (`qu_arg` is one pressure or one
per span, plus a flat slab's drop line load).

A wall support stays at its centerline. ENGINEERING JUDGMENT: §13.7.7.1
names interior supports and §13.7.7.2 covers exterior supports only with
brackets or capitals. Exterior flat-plate columns are still taken at the
face, with the same 0.175 l1 limit, as common EFM practice does.
"""
function _with_face_moments(span_moments, spans, columns, qu_arg; drop_loads = nothing)
    return map(span_moments) do sm
        s = sm.span_idx
        sp = spans[s]
        q = qu_arg isa AbstractVector ? qu_arg[s] : qu_arg
        x_left = _is_wall_support(columns[s]) ? zero(sp.l1) :
            efm_face_offset(sp.c1_left, sp.l1)
        x_right = _is_wall_support(columns[s + 1]) ? zero(sp.l1) :
            efm_face_offset(sp.c1_right, sp.l1)
        face_left, face_right = span_face_moments(
            sm.M_neg_left, sm.M_neg_right, q * sp.l2, sp.l1, x_left, x_right;
            drop = _span_drop(drop_loads, s))
        merge(sm, (M_face_left = face_left, M_face_right = face_right))
    end
end

"""
Negative moments over every span, classified by the support they land on.

An edge or corner column feeds `M_neg_ext`. An interior column feeds
`M_neg_int`. A wall feeds `M_wall_ext` at an end of the frame and
`M_wall_int` between columns. Positive moment is the largest midspan.

A span whose support moments exceed its static moment has a negative
midspan from `M0 − (Mleft + Mright) / 2` and stops the analysis.

`M_neg_ext_face` and `M_neg_int_face` envelope the same supports at their
critical sections when the spans carry `M_face_left`/`M_face_right`
(see `_with_face_moments`); otherwise they equal the centerline values.
"""
function _envelope_support_moments(span_moments, columns)
    T = typeof(span_moments[1].M_pos)
    z = zero(T)
    ext = int = pos = wall_ext = wall_int = z
    ext_face = int_face = z
    n = length(columns)
    for (s, sm) in enumerate(span_moments)
        _require_span_equilibrium(sm)
        pos = _raise_abs(pos, sm.M_pos)
        faces = (get(sm, :M_face_left, sm.M_neg_left), get(sm, :M_face_right, sm.M_neg_right))
        for (k, (idx, M)) in enumerate(((s, sm.M_neg_left), (s + 1, sm.M_neg_right)))
            col = columns[idx]
            if _is_wall_support(col)
                if idx == 1 || idx == n
                    wall_ext = _raise_abs(wall_ext, M)
                else
                    wall_int = _raise_abs(wall_int, M)
                end
            elseif hasproperty(col, :position) && col.position == :interior
                int = _raise_abs(int, M)
                int_face = _raise_abs(int_face, faces[k])
            else
                ext = _raise_abs(ext, M)
                ext_face = _raise_abs(ext_face, faces[k])
            end
        end
    end
    return (
        M_neg_ext = ext, M_neg_int = int, M_pos = pos,
        M_wall_ext = wall_ext, M_wall_int = wall_int,
        M_neg_ext_face = ext_face, M_neg_int_face = int_face,
    )
end

function _require_span_equilibrium(sm)
    ends = (abs(sm.M_neg_left) + abs(sm.M_neg_right)) / 2
    tol = max(0.01 * ends, uconvert(unit(ends), 1.0u"kip*ft"))
    sm.M_pos >= -tol && return nothing
    error("EFM span $(sm.span_idx) is not in equilibrium: the support " *
          "moments average $(ends) and the midspan moment is $(sm.M_pos). " *
          "M0 − (Mleft + Mright) / 2 is negative, so the ends exceed the " *
          "static moment of the span.")
end

function _raise_abs_vector!(dest, src)
    for i in eachindex(dest)
        abs(src[i]) > abs(dest[i]) && (dest[i] = src[i])
    end
    return dest
end

"""
    _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln;
                                qu_per_span=nothing, drop_shears=nothing)

Compute column-level demands from EFM span moments.

Uses tributary area for shear where available. `drop_shears` is the factored
drop-panel weight at each column ([`column_drop_panel_shears`](@ref)); the
drop is dead load and is the same under every pattern.
"""
function _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln;
                                     qu_per_span=nothing, drop_shears=nothing)
    n_cols = length(columns)
    MomentT = typeof(1.0kip*u"ft")
    ForceT  = typeof(1.0kip)
    column_moments     = Vector{MomentT}(undef, n_cols)
    column_shears      = Vector{ForceT}(undef, n_cols)
    unbalanced_moments = Vector{MomentT}(undef, n_cols)

    for (i, col) in enumerate(columns)
        if i == 1
            M = span_moments[1].M_neg_left
            Mub = M
        elseif i == n_cols
            M = span_moments[end].M_neg_right
            Mub = M
        else
            M_left = span_moments[i-1].M_neg_right
            M_right = span_moments[i].M_neg_left
            M = max(M_left, M_right)
            Mub = abs(M_left - M_right)
        end

        column_moments[i] = M
        unbalanced_moments[i] = Mub
        q_i = _pattern_shear_pressure(qu, qu_per_span, i, n_cols)
        column_shears[i] = _compute_column_shear(struc, col, q_i, l2, ln)
        isnothing(drop_shears) || (column_shears[i] += drop_shears[i])
    end

    return column_moments, column_shears, unbalanced_moments
end

"""
    _efm_demands_with_pattern(...) -> NamedTuple

Slab moments from every span of this frame line, classified by support,
plus column moments, shears, and unbalanced moments. When `use_pattern` is
true, each station is the larger absolute value of the full-load case and
the §13.7.6.3 patterns.

ACI 318-11 §13.7.6.4 (corpus: aci-318-11, page 261): a pattern cannot
reduce a full-load demand. Unbalanced moments are enveloped as a derived
quantity. Enveloping the two end moments first and then subtracting them
would hide the checkerboard transfer.
"""
function _efm_demands_with_pattern(span_moments, struc, columns, qu, qD, qL, l2, ln;
                                   use_pattern::Bool, solve_once, drop_shears=nothing,
                                   drop_loads=nothing)
    env = _envelope_support_moments(span_moments, columns)
    M_neg_ext = env.M_neg_ext
    M_neg_int = env.M_neg_int
    M_pos = env.M_pos
    M_wall_ext = env.M_wall_ext
    M_wall_int = env.M_wall_int
    M_neg_ext_face = env.M_neg_ext_face
    M_neg_int_face = env.M_neg_int_face
    column_moments, column_shears, unbalanced_moments = _compute_efm_column_demands(
        struc, columns, span_moments, qu, l2, ln; drop_shears,
    )
    if use_pattern
        n_spans = length(span_moments)
        for pattern in generate_load_patterns(n_spans)
            all(==(:dead_plus_live), pattern) && continue
            qu_ps = factored_pattern_loads(pattern, qD, qL)
            sm_pat = solve_once(qu_ps)
            pat = _envelope_support_moments(sm_pat, columns)
            M_neg_ext = _raise_abs(M_neg_ext, pat.M_neg_ext)
            M_neg_int = _raise_abs(M_neg_int, pat.M_neg_int)
            M_pos = _raise_abs(M_pos, pat.M_pos)
            M_wall_ext = _raise_abs(M_wall_ext, pat.M_wall_ext)
            M_wall_int = _raise_abs(M_wall_int, pat.M_wall_int)
            M_neg_ext_face = _raise_abs(M_neg_ext_face, pat.M_neg_ext_face)
            M_neg_int_face = _raise_abs(M_neg_int_face, pat.M_neg_int_face)
            cm_p, cs_p, ub_p = _compute_efm_column_demands(
                struc, columns, sm_pat, qu, l2, ln; qu_per_span=qu_ps, drop_shears,
            )
            _raise_abs_vector!(column_moments, cm_p)
            _raise_abs_vector!(column_shears, cs_p)
            _raise_abs_vector!(unbalanced_moments, ub_p)
        end
    end
    return (
        M_neg_ext = M_neg_ext,
        M_neg_int = M_neg_int,
        M_pos = M_pos,
        M_wall_ext = M_wall_ext,
        M_wall_int = M_wall_int,
        M_neg_ext_face = M_neg_ext_face,
        M_neg_int_face = M_neg_int_face,
        column_moments = column_moments,
        column_shears = column_shears,
        unbalanced_moments = unbalanced_moments,
        wall_faces = _efm_wall_faces(solve_once, columns, qD, qL, length(span_moments),
                                     use_pattern; has_drop = drop_loads !== nothing),
    )
end

"""
Signed moment at each side of each wall support.

A support without `wall_seg` is skipped. Two spans meeting at one wall are
two entries, in span order, so a later solve can be subtracted term by term.
"""
function _wall_sides(span_moments, columns)
    out = NamedTuple[]
    for (s, sm) in enumerate(span_moments)
        for (idx, M) in ((s, sm.M_neg_left), (s + 1, sm.M_neg_right))
            col = columns[idx]
            _is_wall_support(col) || continue
            seg = hasproperty(col, :wall_seg) ? col.wall_seg : nothing
            seg === nothing && continue
            push!(out, (key = _segment_key(seg), seg = seg, M = M))
        end
    end
    return out
end

"""
    _efm_wall_faces(solve_once, columns, qD, qL, n_spans, use_pattern; has_drop=true)

Dead and live moment at each wall on this frame line.

The frame adds the drop's line load to every solve, already multiplied by
the dead factor `γ` of the combination that sets `qu`
([`governing_dead_factor`](@ref)). A zero-pressure solve carries that drop
and nothing else. The live moment is the `qL` solve minus the zero solve.
The dead moment is the `qD` solve minus the zero solve, plus the zero solve
over `γ`, which is the drop's own unfactored weight. A line without a drop
has zero moment at zero pressure, so that solve is skipped. With pattern
loading the live moment is the largest of those differences. The two sides
of one wall keep the side with the larger `1.4D` / `1.2D+1.6L` hogging.
Several frame lines add their strips later.
"""
function _efm_wall_faces(solve_once, columns, qD, qL, n_spans, use_pattern;
                         has_drop::Bool = true)
    γ_drop = governing_dead_factor(qD, qL)
    any(_is_wall_support, columns) || return SlabWallFaceMoment[]
    dead = _wall_sides(solve_once(fill(qD, n_spans)), columns)
    isempty(dead) && return SlabWallFaceMoment[]
    base = has_drop ? _wall_sides(solve_once(fill(zero(qD), n_spans)), columns) :
                      [(side..., M = zero(side.M)) for side in dead]
    lives = Any[_wall_sides(solve_once(fill(qL, n_spans)), columns)]
    if use_pattern
        for pattern in generate_load_patterns(n_spans)
            all(==(:dead_plus_live), pattern) && continue
            q = [s === :dead_plus_live ? qL : zero(qL) for s in pattern]
            push!(lives, _wall_sides(solve_once(q), columns))
        end
    end
    (length(dead) == length(base) && all(c -> length(c) == length(base), lives)) ||
        return SlabWallFaceMoment[]
    best = Dict{NTuple{4,Int}, SlabWallFaceMoment}()
    env(D, L) = max(1.4 * D, 1.2 * D + 1.6 * L, 0.0)
    for i in eachindex(base)
        M0 = ustrip(u"N*m", base[i].M)
        D = ustrip(u"N*m", dead[i].M) - M0 + M0 / γ_drop
        L = maximum(c -> ustrip(u"N*m", c[i].M - base[i].M), lives)
        seg = base[i].seg
        face = SlabWallFaceMoment(D, L, seg[1][1], seg[1][2], seg[2][1], seg[2][2])
        key = base[i].key
        (!haskey(best, key) || env(D, L) > env(best[key].D, best[key].L)) &&
            (best[key] = face)
    end
    return collect(values(best))
end

"""
    _factored_wall_faces(span_moments, columns, qu, qD, qL)

Dead and live parts of a direct-design wall moment.

The coefficients apply to one factored pressure, so the support moment
splits by `qD / qu` and `qL / qu`. Each wall keeps its own support, the
larger side where two spans meet.
"""
function _factored_wall_faces(span_moments, columns, qu, qD, qL)
    qun = ustrip(u"Pa", qu)
    qun > 0 || return SlabWallFaceMoment[]
    dshare = ustrip(u"Pa", qD) / qun
    lshare = ustrip(u"Pa", qL) / qun
    best = Dict{NTuple{4,Int}, SlabWallFaceMoment}()
    for side in _wall_sides(span_moments, columns)
        M = ustrip(u"N*m", abs(side.M))
        face = SlabWallFaceMoment(M * dshare, M * lshare,
                                  side.seg[1][1], side.seg[1][2],
                                  side.seg[2][1], side.seg[2][2])
        key = side.key
        (!haskey(best, key) || M > best[key].D + best[key].L) && (best[key] = face)
    end
    return collect(values(best))
end

"""Add the strip moments of several frame lines that land on one wall."""
function _sum_wall_faces(lists)
    acc = Dict{NTuple{4,Int}, SlabWallFaceMoment}()
    for list in lists, face in list
        key = _segment_key(((face.x1, face.y1), (face.x2, face.y2)))
        if haskey(acc, key)
            old = acc[key]
            acc[key] = SlabWallFaceMoment(old.D + face.D, old.L + face.L,
                                          old.x1, old.y1, old.x2, old.y2)
        else
            acc[key] = face
        end
    end
    return collect(values(acc))
end

# _compute_column_shear is defined in common.jl (shared between DDM and EFM)

