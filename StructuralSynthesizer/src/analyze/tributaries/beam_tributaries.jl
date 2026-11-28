"""
    compute_member_tributaries!(struc; strategy::Symbol=:cell_merge) -> struc

Populate each `Beam`'s `tributary_profile` (Layer 1 of the tributary pipeline).

# Strategies
- `:cell_merge` (default): merge the per-cell edge tributaries that meet on each
  beam — the width contributions from the (up to two) adjacent cells are summed
  along the beam. Mirrors the geometry already used by
  `_create_cell_tributary_loads!`.
- `:shell_panels`: delegate to `Asap._shell_panels_to_tributary_loads` when the
  Asap model carries shell elements (multi-bay continuous-girder case). The
  synthesizer's design model is frame-only today, so when no shells are present
  this falls back to `:cell_merge` with a warning.

Beams with no adjacent tributary keep `tributary_profile == nothing`.
"""
function compute_member_tributaries!(struc::BuildingStructure; strategy::Symbol=:cell_merge)
    if strategy === :cell_merge
        return _compute_member_tributaries_cell_merge!(struc)
    elseif strategy === :shell_panels
        return _compute_member_tributaries_shell_panels!(struc)
    else
        throw(ArgumentError(
            "compute_member_tributaries!: unknown strategy $(strategy); use :cell_merge or :shell_panels"))
    end
end

"""Convert a length in meters (Float64) to the structure's length type `T`."""
_meters_to_T(::Type{T}, x_m::Float64) where {T} = convert(T, x_m)
_meters_to_T(::Type{T}, x_m::Float64) where {T<:Unitful.Quantity} = convert(T, x_m * u"m")

"""Frame elements of an Asap model (handles frame-only vs mixed models)."""
_frame_elements(::Nothing) = []
_frame_elements(model::Asap.Model) = model.frame_elements
_frame_elements(model::Asap.FrameModel) = model.elements

"""Shell elements of an Asap model, or an empty vector for a frame-only model."""
function _asap_shell_elements(model)
    isnothing(model) && return []
    hasproperty(model, :shell_elements) && return model.shell_elements
    return []
end

"""Clamped piecewise-linear interpolation of `w` sampled at `pos` evaluated at `s`."""
function _interp_linear(pos::Vector{Float64}, w::Vector{Float64}, s::Float64)
    s <= pos[1] && return w[1]
    s >= pos[end] && return w[end]
    idx = clamp(searchsortedlast(pos, s), 1, length(pos) - 1)
    p0, p1 = pos[idx], pos[idx + 1]
    p1 == p0 && return w[idx + 1]
    return w[idx] + (w[idx + 1] - w[idx]) * (s - p0) / (p1 - p0)
end

"""
Ordered vertex sequence `[v0, v1, ..., vn]` traversed by a chain of `edges`, so
edge `k` connects `verts[k]` → `verts[k+1]`. For a single edge, returns the edge
in its canonical (`edge_indices`) orientation.
"""
function _ordered_chain_vertices(skel, edges::Vector{Int})
    n = length(edges)
    verts = Vector{Int}(undef, n + 1)
    if n == 1
        a, b = skel.edge_indices[edges[1]]
        verts[1] = a
        verts[2] = b
        return verts
    end
    e1 = skel.edge_indices[edges[1]]
    e2 = skel.edge_indices[edges[2]]
    # Start of edge 1 is its endpoint not shared with edge 2.
    start_v = (e1[1] == e2[1] || e1[1] == e2[2]) ? e1[2] : e1[1]
    verts[1] = start_v
    cur = start_v
    for (k, e) in enumerate(edges)
        a, b = skel.edge_indices[e]
        nxt = a == cur ? b : a
        verts[k + 1] = nxt
        cur = nxt
    end
    return verts
end

"""Extend a `[?, ?]`-spanning (positions, widths) profile to span `[0, 1]` by flat
extension of the boundary widths."""
function _span_unit_interval(pos::Vector{Float64}, w::Vector{Float64})
    isempty(pos) && return ([0.0, 1.0], [0.0, 0.0])
    p = copy(pos)
    ww = copy(w)
    if p[1] > 1e-9
        pushfirst!(p, 0.0)
        pushfirst!(ww, ww[1])
    else
        p[1] = 0.0
    end
    if p[end] < 1.0 - 1e-9
        push!(p, 1.0)
        push!(ww, ww[end])
    else
        p[end] = 1.0
    end
    return (p, ww)
end

"""
Accumulate per-cell edge tributary width profiles, keyed by global edge index and
stored in the canonical edge orientation (`edge_indices[e] = (v1, v2)`, i.e.
`s = 0` at `v1`). Widths are in meters.
"""
function _accumulate_edge_width_profiles(struc::BuildingStructure)
    skel = struc.skeleton
    pair_edge = Dict{NTuple{2, Int}, Int}()
    for (e, (a, b)) in enumerate(skel.edge_indices)
        pair_edge[(a, b)] = e
        pair_edge[(b, a)] = e
    end
    ProfT = Tuple{Vector{Float64}, Vector{Float64}}
    edge_profiles = Dict{Int, Vector{ProfT}}()
    # A grillage owns its panel, so those cells do not also paint a cell tributary.
    grill_cells = _grillage_cells(struc)
    for (cell_idx, cell) in enumerate(struc.cells)
        cell_idx in grill_cells && continue
        tribs = cell_edge_tributaries(struc, cell_idx)
        isnothing(tribs) && _omit_missing_tributary_cache(cell, cell_idx) && continue
        face_edges = skel.face_edge_indices[cell.face_idx]
        face_verts = skel.face_vertex_indices[cell.face_idx]
        (isempty(face_edges) || isempty(face_verts)) && continue
        n_verts = length(face_verts)
        ring_pairs = Tuple{Int, Int}[]
        for ring in get(skel.face_hole_vertices, cell.face_idx, Vector{Int}[])
            for i in eachindex(ring)
                push!(ring_pairs, (ring[i], ring[mod1(i + 1, length(ring))]))
            end
        end
        for trib in tribs
            trib.area < 1e-12 && continue
            positions, widths_m = _extract_width_profile(trib)
            length(positions) < 2 && continue
            local_idx = trib.local_edge_idx
            if 1 <= local_idx <= length(face_edges)
                global_edge = face_edges[local_idx]
                expected_v1 = face_verts[local_idx]
                expected_v2 = face_verts[mod1(local_idx + 1, n_verts)]
            elseif n_verts < local_idx <= n_verts + length(ring_pairs)
                expected_v1, expected_v2 = ring_pairs[local_idx - n_verts]
                global_edge = get(pair_edge, (expected_v1, expected_v2), nothing)
                global_edge === nothing && continue
            else
                continue
            end
            actual_v1, actual_v2 = skel.edge_indices[global_edge]
            if actual_v1 == expected_v2 && actual_v2 == expected_v1
                positions = reverse(1.0 .- positions)
                widths_m = reverse(widths_m)
            end
            push!(get!(Vector{ProfT}, edge_profiles, global_edge), (positions, widths_m))
        end
    end
    return edge_profiles
end

"""`∫ w ds` of a piecewise-linear profile."""
_profile_integral(pos, w) = Asap._trapezoid(pos, w)

"""Sum the (≤ 2) cell width profiles that share an edge onto the union of their
breakpoints, keeping steps. Widths in meters, canonical edge orientation."""
function _merge_edge_profiles(profiles::Vector{Tuple{Vector{Float64}, Vector{Float64}}})
    isempty(profiles) && return (Float64[], Float64[])
    length(profiles) == 1 && return profiles[1]
    pos, w = Asap._sum_profiles(profiles)
    want = sum(_profile_integral(p, ww) for (p, ww) in profiles)
    got = _profile_integral(pos, w)
    abs(got - want) <= 1e-9 * max(want, 1.0) || error(
        "Merging an edge's cell tributaries changed its load: ∫w ds went from $want to $got m.")
    return (pos, w)
end

"""
Assign `beam.tributary_profile` from a dict of per-edge width profiles (canonical
orientation, meters). Concatenates each beam's segments in chain order, mapping
each segment's local `[0, 1]` onto the beam's global `[0, 1]` by physical length.
Beams whose edges carry no tributary are left untouched.
"""
function _assign_beam_profiles_from_edges!(struc::BuildingStructure{T},
        edge_merged::Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}) where {T}
    skel = struc.skeleton

    # (Phase 10) Sub-edge → chain-head lookup. When a Level-0 host has been
    # subdivided by `_split_host_edge!` (Phase 5 landings on the boundary, or
    # Phase 10 higher-level landings on lower-level joists), the cell tributary
    # profile is still stored under the ORIGINAL (chain-head) edge index in
    # `edge_merged`, parameterized in `[0, 1]` over the FULL original edge —
    # not over the shorter head sub-edge alone. The per-sub-edge loop below
    # naively treats that profile as local to the head sub-edge, compressing an
    # 8 m trapezoid into 2 m and losing 3/4 of the tributary area. Detect the
    # chain here and treat the head-stored profile as the WHOLE-BEAM profile
    # instead (head's `[0, 1]` is already the beam's `[0, 1]` because a
    # host-chain beam covers exactly the original edge end-to-end).
    edge_to_chain = Dict{Int, Vector{Int}}()
    for (_, sub_edges) in skel.edge_chains
        length(sub_edges) < 2 && continue
        for e in sub_edges
            edge_to_chain[e] = sub_edges
        end
    end

    for beam in struc.beams
        segs = segment_indices(beam)
        isempty(segs) && continue
        edges = [struc.segments[si].edge_idx for si in segs]
        verts = _ordered_chain_vertices(skel, edges)

        seg_len_m = Float64[]
        for si in segs
            L = struc.segments[si].L
            push!(seg_len_m, L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L))
        end
        total = sum(seg_len_m)
        total <= 0 && continue

        # (Phase 10) Whole-beam fast path for host-chain beams. The beam's
        # edges must exactly equal a single chain in `skel.edge_chains` for
        # this to apply — otherwise fall through to the per-sub-edge loop.
        head_chain = get(edge_to_chain, edges[1], nothing)
        if head_chain !== nothing && head_chain == edges &&
           haskey(edge_merged, head_chain[1])
            head = head_chain[1]
            pos_c, w_c = edge_merged[head]
            a, _ = skel.edge_indices[head]
            # Head sub-edge orientation: canonical edge_indices[head] = (a, _),
            # but after `_split_host_edge!` the head IS the first sub-edge
            # `(chain_vs[1], chain_vs[2])`. The beam is ordered `verts[1] →
            # verts[end]`; the head profile is [0, 1] over `v_a → v_b` of the
            # ORIGINAL edge (see `_accumulate_edge_width_profiles`). Since
            # `_split_host_edge!` preserves the original v1→v2 orientation as
            # the beam's chain direction (v1 == verts[1], v2 == verts[end]),
            # the head profile is naturally in the beam's forward direction if
            # `verts[1] == a`; reverse otherwise.
            if verts[1] != a
                pos_c = reverse(1.0 .- pos_c)
                w_c = reverse(w_c)
            end
            positions_all, widths_all_m = _span_unit_interval(pos_c, w_c)
            if maximum(widths_all_m) > 0
                _assert_beam_carries(beam, positions_all, widths_all_m, total,
                                     _profile_integral(pos_c, w_c) * total)
                widths_T = T[_meters_to_T(T, w) for w in widths_all_m]
                beam.tributary_profile = TributaryProfile{T}(positions_all, widths_T, nothing)
            end
            continue
        end

        positions_all = Float64[]
        widths_all_m = Float64[]
        offset = 0.0
        any_trib = false
        expected_m2 = 0.0
        for k in eachindex(edges)
            e = edges[k]
            if haskey(edge_merged, e)
                pos_c, w_c = edge_merged[e]
                expected_m2 += _profile_integral(pos_c, w_c) * seg_len_m[k]
                # Canonical orientation is edge_indices[e] = (a, b) with s = 0 at a.
                # The beam traverses verts[k] → verts[k+1]; reverse if it disagrees.
                a, _ = skel.edge_indices[e]
                if verts[k] != a
                    pos_c = reverse(1.0 .- pos_c)
                    w_c = reverse(w_c)
                end
                pos_c, w_c = _span_unit_interval(pos_c, w_c)
                maximum(w_c) > 0 && (any_trib = true)
            else
                pos_c = [0.0, 1.0]
                w_c = [0.0, 0.0]
            end
            Lk = seg_len_m[k]
            for j in eachindex(pos_c)
                push!(positions_all, (offset + pos_c[j] * Lk) / total)
                push!(widths_all_m, w_c[j])
            end
            offset += Lk
        end

        any_trib || continue

        positions_all[1] = 0.0
        positions_all[end] = 1.0
        for i in 2:length(positions_all)
            positions_all[i] < positions_all[i - 1] && (positions_all[i] = positions_all[i - 1])
        end
        _assert_beam_carries(beam, positions_all, widths_all_m, total, expected_m2)
        widths_T = T[_meters_to_T(T, w) for w in widths_all_m]
        beam.tributary_profile = TributaryProfile{T}(positions_all, widths_T, nothing)
    end
    return struc
end

"""
Throw unless a beam's assembled profile carries the tributary area of the edges
it spans. A shortfall is floor load the beam would not be designed for.
"""
function _assert_beam_carries(beam, pos::Vector{Float64}, w_m::Vector{Float64},
                              length_m::Float64, expected_m2::Float64)
    got = _profile_integral(pos, w_m) * length_m
    abs(got - expected_m2) <= 1e-6 * max(expected_m2, 1.0) || error(
        "Beam on segments $(segment_indices(beam)) carries $got m² of tributary but its edges " *
        "hold $expected_m2 m².")
    return nothing
end

"""`:cell_merge` strategy — merge per-cell edge tributaries onto each beam."""
function _compute_member_tributaries_cell_merge!(struc::BuildingStructure)
    edge_profiles = _accumulate_edge_width_profiles(struc)
    # The grillage skeleton replaces the skipped cells, one profile per rib edge.
    for slab in struc.slabs
        fl = _grillage_level(slab)
        fl === nothing && continue
        for (e, prof) in grillage_edge_profiles(struc, slab, fl)
            push!(get!(Vector{Tuple{Vector{Float64}, Vector{Float64}}}, edge_profiles, e), prof)
        end
    end
    edge_merged = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}()
    for (e, profs) in edge_profiles
        edge_merged[e] = _merge_edge_profiles(profs)
    end
    return _assign_beam_profiles_from_edges!(struc, edge_merged)
end

"""`:shell_panels` strategy — delegate to `Asap._shell_panels_to_tributary_loads`
when shells are present, else fall back to `:cell_merge`.

Shells are grouped into per-bay panels by their `id` tag (Phase 7): shells built
per slab (e.g. `:slab_1`, `:slab_2` from `build_analysis_model!`) form separate
panels, so a girder shared by two bays receives its tributary from **both** and
`Asap._shell_panels_to_tributary_loads` sums the depths across panels — the
multi-bay continuous-girder case that function was written for. A single shared
tag collapses to one panel (the earlier behavior). Only host members (non-joist
beams) are handed to the Asap matcher, since it requires every beam to lie on a
panel boundary; interior joists are served by `:cell_merge`. If the frame-only
design model carries no shells, or the panel geometry does not match the beams,
this falls back to `:cell_merge` with a warning."""
function _compute_member_tributaries_shell_panels!(struc::BuildingStructure)
    shells = _asap_shell_elements(struc.asap_model)
    if isempty(shells)
        @warn "compute_member_tributaries!(strategy=:shell_panels): no shell elements in the Asap model (design model is frame-only); falling back to :cell_merge."
        return _compute_member_tributaries_cell_merge!(struc)
    end

    frame_els = _frame_elements(struc.asap_model)
    isempty(frame_els) && return struc

    # Map each HOST (non-joist) beam edge to its Asap frame element. The Asap
    # multi-panel matcher requires every beam to sit on a panel boundary, so only
    # boundary/host members are eligible; interior joists route via :cell_merge.
    edge_to_el = Dict{Int, Asap.FrameElement}()
    el_to_edge = Dict{Asap.FrameElement, Int}()
    for beam in struc.beams
        is_joist(beam) && continue
        for si in segment_indices(beam)
            e = struc.segments[si].edge_idx
            (e >= 1 && e <= length(frame_els)) || continue
            el = frame_els[e]
            edge_to_el[e] = el
            el_to_edge[el] = e
        end
    end
    isempty(edge_to_el) && return struc

    beam_elements = collect(Asap.FrameElement, values(edge_to_el))
    # Per-bay panels keyed by shell id (see the docstring). Pressure is a unit
    # dummy — only the geometric widths from the returned loads are consumed.
    by_id = Dict{Symbol, Vector{Asap.ShellElement}}()
    for sh in shells
        push!(get!(() -> Asap.ShellElement[], by_id, sh.id), sh)
    end
    panels = collect(values(by_id))

    local loads
    try
        loads = Asap._shell_panels_to_tributary_loads(panels, beam_elements, 1.0u"Pa")
    catch err
        @warn "compute_member_tributaries!(strategy=:shell_panels): shell panels did not match the host beams; falling back to :cell_merge." exception=(err, catch_backtrace())
        return _compute_member_tributaries_cell_merge!(struc)
    end

    edge_merged = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}()
    for ld in loads
        el = ld.element
        haskey(el_to_edge, el) || continue
        widths_m = [ustrip(u"m", w) for w in ld.widths]
        edge_merged[el_to_edge[el]] = (copy(ld.positions), widths_m)
    end
    return _assign_beam_profiles_from_edges!(struc, edge_merged)
end

