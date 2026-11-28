"""Column fields read by Eq. (13-7) and §13.6.3.3 classification."""
const _NLP_EQ137_COLUMN_FIELDS = (:vertex_idx, :position, :c1, :c2, :θ, :shape,
                                  :structural_offset, :boundary_edge_dirs, :story)

"""Cell fields read by Eq. (13-7) (face and service loads)."""
const _NLP_EQ137_CELL_FIELDS = (:face_idx, :sdl, :live_load, :self_weight)

"""Immutable copy of the `fields` that `obj` has (arrays copied)."""
function _nlp_freeze(obj, fields)
    ks = Tuple(k for k in fields if hasproperty(obj, k))
    vals = map(ks) do k
        v = getproperty(obj, k)
        v isa AbstractArray ? copy(v) : v
    end
    return NamedTuple{ks}(vals)
end

"""True when `obj` has exactly the `fields` frozen in `fz`, with equal values."""
function _nlp_frozen_matches(obj, fz, fields)::Bool
    n = 0
    for k in fields
        hasproperty(obj, k) || continue
        n += 1
        haskey(fz, k) || return false
        isequal(getproperty(obj, k), fz[k]) || return false
    end
    return n == length(fz)
end

"""
Frozen view of what Eq. (13-7) reads from `struc` and `columns`:
`(view, frozen_columns)`.

`view` has the duck-typed `struc` interface the Eq. (13-7) helpers use:
`cells` (face index and loads), `slabs` (the same slab objects, so slab
identity and a neighbour's live `result` thickness still work), `columns`
(frozen sizes, positions, vertices) and, when present, `skeleton` (copied
vertex coordinates and face lists).  A column that appears in both
`struc.columns` and `columns` is frozen once, so identity checks agree.
"""
function _nlp_eq137_snapshot(struc, columns)
    memo = IdDict{Any,Any}()
    freeze(col) = get!(() -> _nlp_freeze(col, _NLP_EQ137_COLUMN_FIELDS), memo, col)
    view = (
        cells = hasproperty(struc, :cells) ?
                Any[_nlp_freeze(c, _NLP_EQ137_CELL_FIELDS) for c in struc.cells] : Any[],
        slabs = hasproperty(struc, :slabs) ? collect(Any, struc.slabs) : Any[],
        columns = hasproperty(struc, :columns) ? Any[freeze(c) for c in struc.columns] : Any[],
    )
    if _eq137_geometry_available(struc)
        skel = struc.skeleton
        view = merge(view, (skeleton = (
            geometry = (vertex_coords = copy(skel.geometry.vertex_coords),),
            face_vertex_indices = [copy(f) for f in skel.face_vertex_indices],
        ),))
    end
    return view, Any[freeze(c) for c in columns]
end

"""Each slab's cell list (copied), for the staleness check."""
_nlp_slab_cells(struc) = hasproperty(struc, :slabs) ?
    [hasproperty(sl, :cell_indices) ? copy(sl.cell_indices) : nothing for sl in struc.slabs] :
    Any[]

"""The design slab's drop panel (`nothing` without one or without a slab)."""
_nlp_drop_panel(slab) =
    (slab !== nothing && hasproperty(slab, :drop_panel)) ? slab.drop_panel : nothing

"""
Fresh Eq. (13-7) maps for `NLPEq137Maps`, built from a frozen copy of the
geometry (`_nlp_eq137_snapshot`) and carrying that copy, plus the design
slab's drop panel at that time (`drop_panel`), so a grid point reads the
drop from the same snapshot as the geometry.
"""
function _nlp_eq137_build(struc, columns, slab = nothing)
    view, cols = _nlp_eq137_snapshot(struc, columns)
    return merge(_eq137_context(view, cols),
                 (struc = view, columns = cols, slab_cells = _nlp_slab_cells(struc),
                  drop_panel = _nlp_drop_panel(slab)))
end

"""
One snapshot of the Eq. (13-7) maps and geometry of `p`, or `nothing`
without geometry.

From `NLPEq137Maps` (one atomic read) when present, else the maps carried
directly by a hand-built `eq137` (missing ones are `nothing`) with its live
`struc` and `columns`.  Callers take one snapshot per `evaluate` and pass
it down, so every column and both directions at a grid point use the same
maps and the same geometry.
"""
function _nlp_eq137_maps(p::FlatPlateNLPProblem)
    eq = p.eq137
    isnothing(eq) && return nothing
    hasproperty(eq, :maps) && return @atomic eq.maps.ctx
    field(k) = hasproperty(eq, k) ? getproperty(eq, k) : nothing
    return (index = field(:index), cell_slab = field(:cell_slab),
            vertex_column = field(:vertex_column), partway = field(:partway),
            struc = eq.struc, columns = eq.columns, slab_cells = nothing,
            drop_panel = _nlp_drop_panel(field(:slab)))
end

"""
True when `struc` / `columns` (and the design `slab`'s drop panel, when
`slab` is given) no longer match the frozen copy in `ctx`.

Compares every slab (identity and cell list), cell (face and loads),
column (frozen fields), vertex coordinate and face list, and the drop
panel, with `isequal`.
This is exact (no hash collisions) and stops at the first difference; with
nothing changed it is one allocation-free pass over those arrays.

The loops run over the frozen copy and check each live index before
reading it (`checkbounds`), so a live array that shrinks during the pass
reads as changed (stale, rebuilt) rather than throwing `BoundsError`.  One
that grows is caught by the length check of the next call.
"""
function _nlp_eq137_differs(ctx, struc, columns, slab = nothing)::Bool
    if slab !== nothing
        isequal(_nlp_drop_panel(slab), get(ctx, :drop_panel, nothing)) || return true
    end
    snap = ctx.struc
    slabs = hasproperty(struc, :slabs) ? struc.slabs : ()
    length(slabs) == length(snap.slabs) == length(ctx.slab_cells) || return true
    for k in eachindex(snap.slabs)
        checkbounds(Bool, slabs, k) || return true
        sl = slabs[k]
        sl === snap.slabs[k] || return true
        cells_k = hasproperty(sl, :cell_indices) ? sl.cell_indices : nothing
        isequal(cells_k, ctx.slab_cells[k]) || return true
    end
    cells = hasproperty(struc, :cells) ? struc.cells : ()
    length(cells) == length(snap.cells) || return true
    for k in eachindex(snap.cells)
        checkbounds(Bool, cells, k) || return true
        _nlp_frozen_matches(cells[k], snap.cells[k], _NLP_EQ137_CELL_FIELDS) || return true
    end
    scols = hasproperty(struc, :columns) ? struc.columns : ()
    for (live, frozen) in ((scols, snap.columns), (columns, ctx.columns))
        length(live) == length(frozen) || return true
        for k in eachindex(frozen)
            checkbounds(Bool, live, k) || return true
            _nlp_frozen_matches(live[k], frozen[k], _NLP_EQ137_COLUMN_FIELDS) || return true
        end
    end
    has_geo = _eq137_geometry_available(struc)
    has_geo == hasproperty(snap, :skeleton) || return true
    if has_geo
        skel = struc.skeleton
        isequal(skel.geometry.vertex_coords, snap.skeleton.geometry.vertex_coords) || return true
        isequal(skel.face_vertex_indices, snap.skeleton.face_vertex_indices) || return true
    end
    return false
end

"""True when the stored Eq. (13-7) maps no longer match `struc`."""
function _nlp_eq137_stale(p::FlatPlateNLPProblem)::Bool
    eq = p.eq137
    (isnothing(eq) || !hasproperty(eq, :maps)) && return false
    return _nlp_eq137_differs(@atomic(eq.maps.ctx), eq.struc, eq.columns, eq.slab)
end

"""
Replace the stored Eq. (13-7) maps when `struc` changed after the problem
was built (`_nlp_eq137_stale`).

Builds a complete new map set and stores it with one atomic write; the old
maps are never mutated, so a thread still holding the previous snapshot
reads consistent (if superseded) data.  Must be called under
`p.trace_lock`, which re-checks staleness there, so one thread rebuilds
while the others wait and then find the maps current.  A problem without
`maps` (hand-built `eq137`) is left as is.  Emits a `:decision` trace
event (`eq137_maps_rebuilt`).
"""
function _nlp_refresh_eq137!(p::FlatPlateNLPProblem, tc)
    _nlp_eq137_stale(p) || return nothing
    eq = p.eq137
    @atomic eq.maps.ctx = _nlp_eq137_build(eq.struc, eq.columns, eq.slab)
    emit!(tc, :slab, "_nlp_refresh_eq137!", "", :decision;
          reason = "eq137_maps_rebuilt")
    return nothing
end

TRACE_REGISTRY[(:_nlp_refresh_eq137!, :slab)] = TracedFunctionMeta(
    :_nlp_refresh_eq137!, :slab, [:decision], nothing, @__FILE__, @__LINE__,
)

"""
Per-call staleness check of `evaluate`.

Skipped while a frozen sweep runs (`_nlp_frozen_sweep`).  Otherwise the
exact comparison (`_nlp_eq137_stale`) runs without the lock: it only reads
`struc` and the atomically published snapshot, so grid-search threads run
it in parallel.  Only when it finds a difference is `p.trace_lock` taken,
where `_nlp_refresh_eq137!` checks again and rebuilds once.
"""
function _nlp_check_eq137!(p::FlatPlateNLPProblem, tc)
    eq = p.eq137
    (isnothing(eq) || !hasproperty(eq, :maps)) && return nothing
    @atomic(eq.maps.sweeps) > 0 && return nothing
    _nlp_eq137_stale(p) || return nothing
    lock(p.trace_lock) do
        _nlp_refresh_eq137!(p, tc)
    end
    return nothing
end

"""
    _nlp_frozen_sweep(f, p::FlatPlateNLPProblem)

Run the grid sweep `f()` with the Eq. (13-7) maps checked once.

Stale maps are rebuilt before the sweep (`_nlp_refresh_eq137!`); during it
`evaluate` skips the per-call check, so the threaded search does no
O(cells + columns) comparison per grid point.  The geometry (`struc`
slabs, cells, columns, skeleton, and the problem's columns) must not be
mutated while the sweep runs.  The exact check runs again afterwards: a
mutation during the sweep means its points were evaluated against
superseded geometry, so a `:failure` trace event
(`eq137_geometry_mutated_during_sweep`) is emitted and an `ErrorException`
is thrown rather than returning that result.  Without `maps` this is
`f()`.
"""
function _nlp_frozen_sweep(f, p::FlatPlateNLPProblem)
    eq = p.eq137
    (isnothing(eq) || !hasproperty(eq, :maps)) && return f()
    buf = isnothing(p.tc) ? nothing :
          TraceCollector(TraceEvent[], p.tc.enabled, p.tc.start_time)
    lock(p.trace_lock) do
        _nlp_refresh_eq137!(p, buf)
    end
    _nlp_flush_trace!(p, buf)
    @atomic eq.maps.sweeps += 1
    result = try
        f()
    finally
        @atomic eq.maps.sweeps -= 1
    end
    if _nlp_eq137_stale(p)
        lock(p.trace_lock) do
            emit!(p.tc, :slab, "_nlp_frozen_sweep", "", :failure;
                  reason = "eq137_geometry_mutated_during_sweep")
        end
        error("FlatPlateNLPProblem: building geometry changed during the grid sweep; " *
              "its Eq. (13-7) results used superseded geometry and are discarded.")
    end
    return result
end

TRACE_REGISTRY[(:_nlp_frozen_sweep, :slab)] = TracedFunctionMeta(
    :_nlp_frozen_sweep, :slab, [:failure], nothing, @__FILE__, @__LINE__,
)

