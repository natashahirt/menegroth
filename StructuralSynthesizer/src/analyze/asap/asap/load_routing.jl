"""
    _omit_missing_tributary_cache(cell, cell_idx) -> Bool

`compute_cell_tributaries!` stores nothing for a grade face, or for an
unknown face that carries no slab load. Returns true so the caller omits
that cell. A faced floor, or an unknown face with SDL, self-weight, or live
load, would otherwise be designed with that load missing, so this throws.
"""
function _omit_missing_tributary_cache(cell, cell_idx::Integer)
    cell.floor_type == :grade && return true
    loaded = any(p -> !iszero(ustrip(p)), (cell.sdl, cell.self_weight, cell.live_load))
    cell.floor_type == :unknown && !loaded && return true
    error("Cell $cell_idx (floor_type=$(cell.floor_type)) has no tributary cache, " *
          "so its slab load cannot be applied. Run compute_cell_tributaries! first.")
end

"""
    _require_face_edges(face_edges, face_idx) -> face_edges

A loaded cell whose face has no edges has nowhere to send its slab load.
Throws instead of returning no loads, which would design with that load missing.
"""
function _require_face_edges(face_edges, face_idx::Integer)
    isempty(face_edges) && error("Cell face $face_idx has no edges, so its slab load " *
                                 "cannot be routed to framing. Check the skeleton geometry.")
    return face_edges
end

"""
Create TributaryLoads for a single cell from its tributary polygons.

When `split_dead_live=true`, returns `(dead_loads, live_loads)` with separate
pressures for pattern loading. When `false` (default), returns combined loads
with enveloped pressure, as a single vector.
"""
function _create_cell_tributary_loads!(
    loads::Vector{Asap.AbstractLoad},
    elements::Vector{<:Asap.Element},
    skel::BuildingSkeleton,
    struc::BuildingStructure,
    cell::Cell,
    cell_idx::Int,
    params::DesignParameters=DesignParameters();
    split_dead_live::Bool=false,
    combo::LoadCombination=governing_combo(params)
)
    dead_loads = Asap.TributaryLoad[]
    live_loads = Asap.TributaryLoad[]
    
    # Get tributaries from cache
    tribs = cell_edge_tributaries(struc, cell_idx)
    if isnothing(tribs)
        _omit_missing_tributary_cache(cell, cell_idx)
        return split_dead_live ? (dead_loads, live_loads) : dead_loads
    end
    
    face_edges = _require_face_edges(skel.face_edge_indices[cell.face_idx], cell.face_idx)
    face_verts = skel.face_vertex_indices[cell.face_idx]

    # Compute pressures
    if split_dead_live
        dead_pressure = uconvert(u"Pa", combo.D * (cell.sdl + cell.self_weight))
        live_pressure = uconvert(u"Pa", combo.L * cell.live_load)
    else
        combos = params.load_combinations
        dead = cell.sdl + cell.self_weight
        live = cell.live_load
        combined_pressure = uconvert(u"Pa", envelope_pressure(combos, dead, live))
    end
    
    n_verts = length(face_verts)
    
    for trib in tribs
        # Skip empty tributaries
        trib.area < 1e-12 && continue
        length(trib.s) < 2 && continue
        
        # Extract width profile from tributary polygon
        positions, widths_m = _extract_width_profile(trib)
        length(positions) < 2 && continue
        
        # Map local edge index to global edge/element
        local_idx = trib.local_edge_idx
        global_edge_idx = face_edges[local_idx]
        el = elements[global_edge_idx]
        
        # Check if edge direction matches face CCW order
        expected_v1 = face_verts[local_idx]
        expected_v2 = face_verts[mod1(local_idx + 1, n_verts)]
        actual_v1, actual_v2 = skel.edge_indices[global_edge_idx]
        edge_reversed = (actual_v1 == expected_v2 && actual_v2 == expected_v1)
        
        if edge_reversed
            positions = reverse(1.0 .- positions)
            widths_m = reverse(widths_m)
        end
        
        widths = [w * u"m" for w in widths_m]
        
        if split_dead_live
            dtload = Asap.TributaryLoad(el, positions, widths, dead_pressure, (0.0, 0.0, -1.0))
            ltload = Asap.TributaryLoad(el, copy(positions), copy(widths), live_pressure, (0.0, 0.0, -1.0))
            push!(loads, dtload)
            push!(loads, ltload)
            push!(dead_loads, dtload)
            push!(live_loads, ltload)
        else
            tload = Asap.TributaryLoad(el, positions, widths, combined_pressure, (0.0, 0.0, -1.0))
            push!(loads, tload)
            push!(dead_loads, tload)
        end
    end
    
    return split_dead_live ? (dead_loads, live_loads) : dead_loads
end

"""
Extract a sorted width profile from a TributaryPolygon.

The polygon vertices trace the boundary, but TributaryLoad needs positions
sorted along the beam with corresponding widths.

Returns (positions, widths) where positions are in [0,1] sorted order.
"""
function _extract_width_profile(trib::TributaryPolygon)
    isempty(trib.s) && return (Float64[], Float64[])
    
    # Collect (s, |d|) pairs and sort by s
    pairs = [(trib.s[i], abs(trib.d[i])) for i in eachindex(trib.s)]
    sort!(pairs, by=first)
    
    # Remove duplicates (keep max width at each position)
    merged = Tuple{Float64, Float64}[]
    for (s, w) in pairs
        if isempty(merged) || abs(s - merged[end][1]) > 1e-9
            push!(merged, (s, w))
        else
            # Same position - keep max width
            merged[end] = (merged[end][1], max(merged[end][2], w))
        end
    end
    
    # Extract separate vectors
    positions = [p[1] for p in merged]
    widths = [p[2] for p in merged]
    
    # Ensure positions are clamped to [0, 1]
    positions = clamp.(positions, 0.0, 1.0)
    
    return (positions, widths)
end

# =============================================================================
# Slab → edge load interface
# =============================================================================

"""
    push_asap_loads!(loads, element, spec)

Convert a backend-agnostic edge load spec into ASAP loads.
Assumes `spec` magnitudes are base SI (N, N/m).

# Fallback Behavior
Unrecognized `AbstractEdgeLoadSpec` subtypes issue a warning and are skipped,
allowing the model to proceed with available loads rather than failing.
"""
function push_asap_loads!(loads::Vector{Asap.AbstractLoad}, el::Asap.Element, spec::AbstractEdgeLoadSpec)
    @warn "No ASAP conversion for $(typeof(spec)) — load skipped" maxlog=1
    return loads
end

function push_asap_loads!(loads::Vector{Asap.AbstractLoad}, el::Asap.Element, spec::EdgeLineLoadSpec)
    # Convert Float64 line load (assumed SI N/m) to Unitful — no intermediate collect.
    # Tag `:vault_thrust` so `sync_asap!` (`_sync_vault_thrust_line_loads!`) can find
    # exactly these structural-effect edge loads and refresh their magnitude from the
    # current `governing_combo(params)` — the id is metadata only and does not affect
    # the solve.
    w_unitful = [spec.w[1] * u"N/m", spec.w[2] * u"N/m", spec.w[3] * u"N/m"]
    push!(loads, Asap.LineLoad(el, w_unitful, :vault_thrust))
    return loads
end

"""
    slab_face_edge_ids(struc, slab) -> Vector{Int}

Return the unique set of skeleton edges referenced by the slab's faces.
"""
function slab_face_edge_ids(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton

    edge_set = Set{Int}()
    for cell_idx in slab.cell_indices
        face_idx = struc.cells[cell_idx].face_idx
        for e_idx in skel.face_edge_indices[face_idx]
            push!(edge_set, e_idx)
        end
    end

    edge_ids = collect(edge_set)
    sort!(edge_ids)  # deterministic ordering (useful for reproducibility/debug)
    return edge_ids
end

"""Internal helper: structural effects as `EdgeLineLoadSpec` (e.g. vault thrust)."""
function slab_edge_line_loads(struc::BuildingStructure, slab::Slab, 
                               params::DesignParameters=DesignParameters())::Vector{EdgeLineLoadSpec}
    effects = StructuralSizer.structural_effects(slab.result)
    isempty(effects) && return EdgeLineLoadSpec[]

    loads = EdgeLineLoadSpec[]

    for eff in effects
        if eff isa StructuralSizer.LateralThrust
            append!(loads, vault_thrust_line_loads(struc, slab, eff, params))
        end
    end

    return loads
end

# --- Vault thrust → edge line loads (simple implementation) ---
function vault_thrust_line_loads(struc::BuildingStructure, slab::Slab, 
                                  eff::StructuralSizer.LateralThrust,
                                  params::DesignParameters=DesignParameters())::Vector{EdgeLineLoadSpec}
    # Factored thrust using governing (primary) load combination from params
    combo = governing_combo(params)
    thrust_factored = eff.dead * combo.D + eff.live * combo.L
    mag_N_m = ustrip(u"N/m", uconvert(u"N/m", thrust_factored))

    # Span axis from slab spans
    span_vec = [slab.spans.axis[1], slab.spans.axis[2], 0.0]

    # Vault slabs are enforced as single rectangular faces; thrust acts on that perimeter.
    face_idx = struc.cells[first(slab.cell_indices)].face_idx
    skel = struc.skeleton
    boundary_edges = skel.face_edge_indices[face_idx]

    vc = skel.geometry.vertex_coords
    f_vis = skel.face_vertex_indices[face_idx]
    f_mid = [sum(vc[vi, k] for vi in f_vis) / length(f_vis) for k in 1:3]

    out = EdgeLineLoadSpec[]
    for e_idx in boundary_edges
        ev1, ev2 = skel.edge_indices[e_idx]
        v = [vc[ev2, k] - vc[ev1, k] for k in 1:3]
        v_len = sqrt(sum(v .^ 2))
        v_norm = v / v_len
        abs(sum(v_norm .* span_vec)) < 0.1 || continue

        mid = [(vc[ev1, k] + vc[ev2, k]) / 2 for k in 1:3]
        out_vec = mid .- f_mid
        proj = sum(out_vec .* span_vec)
        dir = proj > 0 ? span_vec : -span_vec

        w = (dir[1] * mag_N_m, dir[2] * mag_N_m, dir[3] * mag_N_m)
        push!(out, EdgeLineLoadSpec(Int(e_idx), w))
    end

    return out
end

"""Extract the end-release symbol (`:fixedfixed`, etc.) from an `Asap.Element` type parameter."""
function _get_release_symbol(el::Asap.Element{R}) where R
    R === Asap.FixedFixed && return :fixedfixed
    R === Asap.FixedFree && return :fixedfree
    R === Asap.FreeFixed && return :freefixed
    R === Asap.FreeFree && return :freefree
    R === Asap.Joist && return :joist
    return :fixedfixed  # fallback
end

"""
    _build_edge_release_map(struc, params) -> Dict{Int, Symbol}

Map each skeleton edge index owned by a `Beam` to the Asap element-release symbol
resolved by [`resolve_edge_releases`](@ref) from the beam's per-segment release
fields, `torsion_released`, and the `(role, material, lateral_role)` dispatch.
Each beam's material is [`_beam_member_material`](@ref): its recorded material,
else the material the beams are sized in.

Edges not owned by a beam (columns, struts, walls, unmodeled edges) are absent
from the map; callers default those to `:fixedfixed`.
"""
function _build_edge_release_map(struc::BuildingStructure, params::DesignParameters)
    edge_release = Dict{Int, Symbol}()
    n_seg = length(struc.segments)
    for beam in struc.beams
        seg_idxs = segment_indices(beam)
        isempty(seg_idxs) && continue
        all(si -> 1 <= si <= n_seg, seg_idxs) || continue
        chain = [struc.segments[si] for si in seg_idxs]
        releases = resolve_edge_releases(beam, chain, _beam_member_material(beam, params))
        for (seg, rel) in zip(chain, releases)
            edge_release[seg.edge_idx] = rel
        end
    end
    return edge_release
end

# =============================================================================
# Phase 7 — joist-on-girder seat eccentricity (Element.eccentricity)
# =============================================================================
# The seat-offset tuple itself is NOT derived here: it comes verbatim from
# `StructuralSizer.default_seat_eccentricity(role, material, host_depth,
# member_depth)` (Phase 3 dispatch). For a steel joist that resolves to
# `(0, 0, (host_depth + member_depth)/2, 0)` — the top-of-girder seat modeled as
# a rigid transverse centroid offset (see StructuralSizer/src/materials/steel.jl
# :joist ENGINEERING JUDGMENT marker; StructuralSizer/src/members/defaults.jl,
# and the transform in external/Asap/src/Elements/K.jl §eccentricity_transformation!).
# All other (role, material) combinations return zeros. Depths come from the
# already-sized member sections; when a section is not yet assigned the depth is
# 0, so the eccentricity is naturally zero on the pre-sizing pass.

"""Structural material recorded on a `Beam` (Phase 5 stamps the framing-level
material as a zero-volume `MaterialVolumes` entry; sizing records the sized
material), else [`beam_sizing_material`](@ref). Rebar entries are skipped."""
function _beam_member_material(beam::Beam, params::DesignParameters)
    for mat in keys(volumes(beam))
        mat isa Union{StructuralSizer.StructuralSteel, StructuralSizer.Concrete,
                      StructuralSizer.Timber} && return mat
    end
    return beam_sizing_material(params)
end

"""Overall depth of a member's assigned section as a length in metres, or
`0.0u"m"` when the member has not been sized yet."""
function _member_section_depth_m(beam::Beam)
    sec = section(beam)
    sec === nothing && return 0.0u"m"
    return uconvert(u"m", StructuralSizer.section_depth(sec))
end

"""
Map each skeleton vertex to the indices of the non-joist `Beam`s (candidate
hosts) that touch it. A joist seats on the members it lands on; after Phase 5's
`edge_chains` subdivision the host girder owns a sub-edge incident to the joist's
landing vertex, so incidence at the joist endpoints identifies the host.
"""
function _host_beams_by_vertex(struc::BuildingStructure)
    skel = struc.skeleton
    m = Dict{Int, Vector{Int}}()
    n_edges = length(skel.edge_indices)
    for (bi, beam) in enumerate(struc.beams)
        is_joist(beam) && continue          # hosts are the members joists land on
        for si in segment_indices(beam)
            si <= length(struc.segments) || continue
            e = struc.segments[si].edge_idx
            (e >= 1 && e <= n_edges) || continue
            v1, v2 = skel.edge_indices[e]
            push!(get!(Vector{Int}, m, v1), bi)
            push!(get!(Vector{Int}, m, v2), bi)
        end
    end
    return m
end

"""
Representative host depth (metres) for `joist`: the maximum sized-section depth
among the lower-level members incident to the joist's endpoints. Returns
`0.0u"m"` when no sized host is found (e.g. before girder sizing). The maximum is
used so that when the two seating girders differ, the seat height that clears the
deeper girder governs — a deterministic choice for the single seat-offset value
the element carries.
"""
function _joist_host_depth_m(struc::BuildingStructure, joist::Beam, joist_idx::Int,
                             host_by_vertex::Dict{Int, Vector{Int}})
    skel = struc.skeleton
    n_edges = length(skel.edge_indices)
    jlvl = level_of(joist)
    best = 0.0u"m"
    for si in segment_indices(joist)
        si <= length(struc.segments) || continue
        e = struc.segments[si].edge_idx
        (e >= 1 && e <= n_edges) || continue
        v1, v2 = skel.edge_indices[e]
        for v in (v1, v2)
            for bi in get(host_by_vertex, v, Int[])
                bi == joist_idx && continue
                host = struc.beams[bi]
                level_of(host) < jlvl || continue   # host must sit below the joist
                d = _member_section_depth_m(host)
                d > best && (best = d)
            end
        end
    end
    return best
end

"""
    _build_edge_eccentricity_map(struc, params) -> Dict{Int, NTuple{4, Float64}}

Skeleton edge → Asap `Element.eccentricity` (metres) for auto-generated joists
whose `(role, material)` seat offset is non-zero. The offset is taken verbatim
from `StructuralSizer.default_seat_eccentricity` (Phase 3); this function only
supplies the current host/member depths and tags the joist's edges. Edges absent
from the map default to zero eccentricity at the construction site.
"""
function _build_edge_eccentricity_map(struc::BuildingStructure, params::DesignParameters)
    edge_ecc = Dict{Int, NTuple{4, Float64}}()
    isempty(struc.beams) && return edge_ecc
    host_by_vertex = _host_beams_by_vertex(struc)
    for (bi, beam) in enumerate(struc.beams)
        is_joist(beam) || continue
        mat = _beam_member_material(beam, params)
        mat === nothing && continue
        member_d = _member_section_depth_m(beam)
        host_d = _joist_host_depth_m(struc, beam, bi, host_by_vertex)
        # Phase 3 dispatch — do NOT re-derive the seat-offset formula here.
        ecc = StructuralSizer.default_seat_eccentricity(getfield(beam, :role), mat,
                                                        host_d, member_d)
        all(iszero, ecc) && continue
        for si in segment_indices(beam)
            si <= length(struc.segments) || continue
            edge_ecc[struc.segments[si].edge_idx] = ecc
        end
    end
    return edge_ecc
end

# =============================================================================
# Phase 7 — slab-pressure routing (shell AreaLoad vs per-cell tributary)
# =============================================================================

"""
Resolve the effective `load_routing` mode given the requested symbol and the
diaphragm shells built for this model. `:auto` picks `:shell_area` only when
shells exist; `:shell_area` falls back to `:cell_tributary` (with a warning) when
no shells were built; `:cell_tributary` is always honored.
"""
function _resolve_load_routing(load_routing::Symbol, shell_elements)
    if load_routing === :cell_tributary
        return :cell_tributary
    elseif load_routing === :shell_area
        if isempty(shell_elements)
            @warn "to_asap!(load_routing=:shell_area): no diaphragm shells built " *
                  "(need diaphragms=:shell and non-empty slabs); " *
                  "falling back to :cell_tributary."
            return :cell_tributary
        end
        return :shell_area
    else  # :auto
        return isempty(shell_elements) ? :cell_tributary : :shell_area
    end
end

"""
    _create_shell_area_loads!(loads, frame_elements, struc, nodes, params) -> loads

Route each slab's gravity pressure through the slab mesh via
`Asap.AreaLoad(shells, pressure; distribute_to=beams, interior_beams=joists,
axis=spans.axis)` (Phase 7). The diaphragm shells are built per slab purely as
tributary geometry — they are not added to the frame-only design model; the
`AreaLoad` splits the panel along the interior joist lines (`interior_beams`) and
distributes the enveloped SDL+LL+self-weight pressure to the boundary girders and
interior joists as `TributaryLoad`s.

!!! note "Envelope pressure (no live-pattern split)"
    This path applies the enveloped (SDL+LL) pressure per slab. Checkerboard live
    patterning (`params.pattern_loading`) remains served by the per-cell
    tributary path; a shell-mesh pattern split is a later-phase refinement.
"""
function _create_shell_area_loads!(loads::Vector{Asap.AbstractLoad},
                                   frame_elements::Vector{<:Asap.Element},
                                   struc::BuildingStructure,
                                   nodes::Vector{Asap.Node},
                                   params::DesignParameters)
    combos = params.load_combinations
    for slab in struc.slabs
        isempty(slab.cell_indices) && continue
        cell0 = struc.cells[first(slab.cell_indices)]
        cell0.floor_type == :grade && continue

        geom = _slab_area_load_geometry(struc, slab, frame_elements, nodes)
        geom === nothing && continue

        pressure = uconvert(u"Pa", envelope_pressure(combos,
                    cell0.sdl + cell0.self_weight, cell0.live_load))

        push!(loads, Asap.AreaLoad(geom.shells, pressure;
                                   distribute_to = geom.distribute,
                                   interior_beams = geom.interior,
                                   axis = slab.spans.axis,
                                   direction = (0.0, 0.0, -1.0)))
    end
    return loads
end

"""
    _slab_area_load_geometry(struc, slab, frame_elements, nodes)
        -> Union{Nothing, NamedTuple}

Shared geometry for the shell-based slab-pressure distribution (Phase 7 and the
joist-framed cell-tributary path). Builds the slab's diaphragm shells (used
purely as tributary geometry — never added to the frame-only design model) and
resolves the frame elements that share the panel:

- `shells`      — the slab's `Asap.ShellElement` mesh (panel geometry).
- `distribute`  — boundary girders (`slab_face_edge_ids`) ++ every framing-level
  member edge (secondary beams + joists), the full `distribute_to` set.
- `interior`    — the `:joist` framing edges only. `Asap.AreaLoad.interior_beams`
  idealizes pinned-end one-way joist strips; role=:beam framing members
  (secondary girders / transfer beams) carry moment and stay in `distribute`
  only (Phase 7 v2 filter).

Returns `nothing` when the slab has no shells or an empty `distribute` set, so
callers fall back to the per-cell tributary path. Pure geometry / bookkeeping —
no code provision applies.
"""
function _slab_area_load_geometry(struc::BuildingStructure, slab::Slab,
                                  frame_elements::Vector{<:Asap.Element},
                                  nodes::Vector{Asap.Node})
    n_el = length(frame_elements)
    slab_shells = create_slab_diaphragm_shells(struc, slab, nodes)
    isempty(slab_shells) && return nothing

    # Boundary girders = the slab's face edges; framing members = the beams of
    # this slab's materialized framing levels (Phase 5). Joist edges (role=:joist)
    # additionally become the one-way strip `interior_beams`.
    boundary_edges = slab_face_edge_ids(struc, slab)
    framing_edges = Int[]
    joist_edges = Int[]
    for fl in slab.framing_levels
        fl.group_id === nothing && continue
        grp = get(struc.member_groups, fl.group_id, nothing)
        grp === nothing && continue
        for mi in grp.member_indices
            (mi >= 1 && mi <= length(struc.beams)) || continue
            beam = struc.beams[mi]
            for si in segment_indices(beam)
                si <= length(struc.segments) || continue
                edge = struc.segments[si].edge_idx
                push!(framing_edges, edge)
                beam.role === :joist && push!(joist_edges, edge)
            end
        end
    end

    boundary_els = Asap.FrameElement[frame_elements[e] for e in boundary_edges
                                     if 1 <= e <= n_el]
    framing_els = Asap.FrameElement[frame_elements[e] for e in unique(framing_edges)
                                    if 1 <= e <= n_el]
    interior_els = Asap.FrameElement[frame_elements[e] for e in unique(joist_edges)
                                     if 1 <= e <= n_el]
    distribute = vcat(boundary_els, framing_els)
    isempty(distribute) && return nothing

    return (shells = slab_shells, distribute = distribute, interior = interior_els)
end

"""
    _slab_has_joist_framing(struc, slab) -> Bool

`true` iff `slab` carries ≥ 1 materialized framing level contributing ≥ 1
`:joist` frame element — i.e. auto-generated joists actually span the bay. This
is the gate for routing the slab's pressure onto its joists (see
[`_create_framed_slab_loads!`](@ref)): slabs without materialized joists keep the
historical per-cell tributary loads byte-for-byte.
"""
function _slab_has_joist_framing(struc::BuildingStructure, slab::Slab)
    for fl in slab.framing_levels
        fl.group_id === nothing && continue
        grp = get(struc.member_groups, fl.group_id, nothing)
        grp === nothing && continue
        for mi in grp.member_indices
            (mi >= 1 && mi <= length(struc.beams)) || continue
            struc.beams[mi].role === :joist && return true
        end
    end
    return false
end

"""Absolute area (m²) of a simple planar polygon given as ordered `(x, y)` meter
pairs, via the shoelace formula. Used to verify one-way strip load conservation
against the true slab area (see [`_framed_slab_strip_geometry`](@ref)). Pure
geometry — no code clause."""
function _polygon_area_m2(poly::Vector{NTuple{2, Float64}})
    n = length(poly)
    n < 3 && return 0.0
    a2 = 0.0
    for i in 1:n
        x1, y1 = poly[i]
        x2, y2 = poly[mod1(i + 1, n)]
        a2 += x1 * y2 - x2 * y1
    end
    return abs(a2) / 2
end

"""Absolute area (m²) of the simple planar polygon `poly` (ordered `(x, y)` meter
pairs) clipped to the across-joist band `n_lo ≤ (p − origin)·axis ≤ n_hi`, where
`axis` is the unit across-joist direction `n̂` and `n = (p − origin)·axis` is a
vertex's signed position along it. The polygon is clipped against the two
half-planes `n ≥ n_lo` and `n ≤ n_hi` by Sutherland–Hodgman, then its shoelace
area is returned. This is the TRUE per-member slab tributary area the one-way
strip gate in [`_framed_slab_strip_geometry`](@ref) checks its emitted
`width·length` against.

PRECONDITION — `poly` must be CONVEX (hence simple). A single-half-plane
Sutherland–Hodgman clip is area-correct only for a convex subject; on a non-convex
boundary the clip can bridge disjoint pieces with coincident edges and return a
WRONG area. Every caller must gate on convexity first (see the convexity early-out
in [`_framed_slab_strip_geometry`](@ref)). As defense-in-depth against a future
reordering/reuse ahead of that gate, a non-convex (or degenerate) `poly` returns
`0.0` rather than asserting: on a safety-critical load path graceful degradation to
the load-conserving per-cell fallback is strictly better than either crashing the
design run (an `AssertionError` may be elided at some optimization levels anyway) or
silently returning a wrong clip area. Callers treat a `0.0` band area as "cannot
route via strips" and fall back. Pure geometry — no code clause."""
function _polygon_band_area_m2(poly::Vector{NTuple{2, Float64}},
                               axis::NTuple{2, Float64},
                               origin::NTuple{2, Float64},
                               n_lo::Float64, n_hi::Float64)
    length(poly) < 3 && return 0.0
    # Defense-in-depth: a non-convex subject would make the single-half-plane clip
    # area-incorrect; return 0.0 so the caller falls back to the per-cell path.
    Asap.is_convex_polygon(poly) || return 0.0
    ax, ay = axis
    ox, oy = origin
    nof(p) = (p[1] - ox) * ax + (p[2] - oy) * ay      # signed position along n̂

    # Sutherland–Hodgman clip of a simple polygon against ONE half-plane. `keep_ge`
    # selects the kept side (`n ≥ bound` when true, else `n ≤ bound`). A boundary
    # crossing (interior status differs between successive vertices) contributes the
    # linearly-interpolated intersection point; `ncur ≠ nprv` is guaranteed there,
    # so the interpolation never divides by zero.
    function clip(subject::Vector{NTuple{2, Float64}}, keep_ge::Bool, bound::Float64)
        isempty(subject) && return subject
        clipped = NTuple{2, Float64}[]
        m = length(subject)
        for i in 1:m
            cur = subject[i]
            prv = subject[mod1(i - 1, m)]
            ncur = nof(cur); nprv = nof(prv)
            incur = keep_ge ? (ncur >= bound) : (ncur <= bound)
            inprv = keep_ge ? (nprv >= bound) : (nprv <= bound)
            if incur != inprv
                t = (bound - nprv) / (ncur - nprv)
                push!(clipped, (prv[1] + t * (cur[1] - prv[1]),
                                prv[2] + t * (cur[2] - prv[2])))
            end
            incur && push!(clipped, cur)
        end
        return clipped
    end

    band = clip(poly, true, n_lo)          # keep n ≥ n_lo
    band = clip(band, false, n_hi)         # keep n ≤ n_hi
    return _polygon_area_m2(band)
end

"""
    _member_emitted_length_m(struc, beam, frame_elements) -> Float64

Total length (m) of a member's segment chain measured on the SAME basis
[`_emit_strip_loads!`](@ref) integrates a tributary strip over. The emitter posts
one `TributaryLoad` per segment on that segment's Asap frame element, and
`Asap.q_local(::TributaryLoad)` integrates the strip over `element.length` (see
external/Asap/src/Loads/fixed_end_forces.jl §q_local). So when `frame_elements` is
supplied we sum the length of each segment's frame element, applying the SAME
bounds guards as the emitter/peers (`si` in range of `struc.segments`, `edge_idx`
in range of `frame_elements`).

The element-length is taken via `Asap.length(element)` — the node-to-node
distance recomputed from node positions — NOT the `element.length` FIELD. The
field is initialized to `0.0u"m"` at element construction and only populated later
by `Asap.length!` during `Asap.Model` assembly (external/Asap/src/Elements/
utilities.jl §length!); this gate runs at load-BUILD time, BEFORE the model is
assembled, so the field is still zero here. `Asap.length(element)` returns exactly
the value `length!` will store into the field — hence exactly the length
`q_local` will later integrate over — so the gate basis provably equals the
emitted-load basis. (Asap models seat eccentricity as a transverse stiffness
transform, not a node move, so this node-to-node length is the load-integration
length regardless of eccentricity.)

`frame_elements === nothing` selects the raw skeleton `Segment.L` fallback (used
by the 2-arg [`_framed_slab_strip_geometry`](@ref) probe in tests); for a
horizontal slab the two bases coincide. A bare-float `Segment.L` is assumed to
already be in METRES (the skeleton's native unit); a unitful length is stripped to
metres. Pure geometry — no code clause."""
function _member_emitted_length_m(struc::BuildingStructure, beam,
                                  frame_elements::Union{Nothing, Vector{<:Asap.Element}})
    total = 0.0
    n_seg = length(struc.segments)
    for si in segment_indices(beam)
        si <= n_seg || continue                        # peer guard (e.g. §_host_beams_by_vertex)
        if frame_elements === nothing
            L = struc.segments[si].L
            # Bare float ⇒ assume metres (skeleton native unit); strip if unitful.
            total += L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
        else
            e = struc.segments[si].edge_idx
            (1 <= e <= length(frame_elements)) || continue   # emitter guard (§_emit_strip_loads!)
            # Asap.length(element) = node-to-node distance from positions; equals
            # the field `element.length` set later by `length!`, but available now
            # (the field is 0 until model assembly). See docstring.
            total += ustrip(u"m", Asap.length(frame_elements[e]))
        end
    end
    return total
end

"""
    _framed_slab_strip_geometry(struc, slab [, frame_elements])
        -> Union{Nothing, Vector{Tuple{Int, Float64}}}

One-way tributary strip widths (m) for the members that carry a single-level
joist-framed `slab`: every level-1 joist plus the perimeter girders that run
PARALLEL to the joists (the slab's one-way edge supports). Returns a vector of
`(beam_index, strip_width_m)` pairs, or `nothing` when the routing does not apply
(no joists, more than one framing level, degenerate geometry, a joist-parallel
one-way support the strip layout would silently starve, or an interior boundary
that is not a rectangle aligned to the joist frame) so the caller falls back to
the load-conserving per-cell tributary path.

`frame_elements` (optional) supplies the Asap frame model so the gate measures
member lengths on the SAME basis the emitter integrates over
(`frame_elements[edge_idx].length`, see [`_member_emitted_length_m`](@ref)). When
omitted (the 2-arg test probe) the raw skeleton `Segment.L` is used, which equals
the element length for a horizontal, offset-free slab.

Mechanics — standard one-way slab tributary (statics; no code clause applies):
the slab spans one way across the joists. Projecting every support line (the
joists and the two joist-parallel edge girders) onto the across-joist axis `n̂`,
each support's tributary runs to the MIDPOINT of the gap to its neighbours, and
to the slab edge for the two outermost supports. The strip widths partition the
slab's across-joist EXTENT `[n_min, n_max]` into bands; each member's emitted load
is its band width `w_i` applied over its FULL length `L_i`.

`_emit_strip_loads!` posts a UNIFORM `TributaryLoad` (a constant intensity), whose
`q_local` integrates to a resultant pinned to the member's MID-SPAN ⇒ a 50/50
end-reaction split. That is per-MEMBER exact — the correct joist internal moment
AND the correct girder point loads the joist end-reactions become — ONLY for a
true RECTANGLE aligned to the joist frame, where the constant tributary width
makes the load uniform and its centroid mid-span. For ANY band sheared relative to
its member (every non-rectangular parallelogram, trapezoid, triangle, diamond,
kite, …) the TRUE tributary centroid is off mid-span, so the uniform strip gets the
joist end-reactions — and the landing-girder point loads — per-member WRONG even
when totals conserve and per-band AREAS match.

The strip path is therefore taken ONLY when the AUTHORITATIVE rectangle-alignment
gate confirms `interior_poly` is exactly a rectangle aligned to the joist frame:

    | area(interior_poly) − n_extent · t_extent | / (n_extent · t_extent) ≤ rtol

where `n_extent`/`t_extent` are the polygon's extents along the across-joist axis
`n̂` and the joist-span axis `t̂`. A CONVEX polygon (guaranteed by the convexity
early-out below) equals its joist-frame bounding-box area IFF it IS exactly that
axis-aligned rectangle, so this admits EXACTLY joist-frame-aligned rectangles and
returns `nothing` for every other shape. This is not over-restrictive: for a
rectangle the joists span between one pair of opposite sides and are parallel to
the other pair, so a valid rectangle is always joist-frame-aligned.

The cheaper CONVEXITY, CONSTANT-MEMBER-LENGTH, TOTAL-AREA-MATCH and per-band
tributary-area checks are retained only as EARLY-OUTS (they short-circuit the
common fallback shapes cheaply) and DEFENSE-IN-DEPTH (a redundant guard against a
future reordering); none of them, even jointly, is the correctness guarantee,
because none implies per-member correctness on a sheared band:

  * A sheared (non-rectangular) parallelogram is CONVEX, has CONSTANT support
    lengths, matches TOTAL area, and passes the per-band AREA check (every chord
    parallel to a side equals that side's length) — yet its uniform strip pins the
    joist reaction to mid-span while the true tributary centroid is off mid-span,
    so its landing-girder point loads are per-member wrong by ~8–15 %. ONLY the
    rectangle-alignment gate rejects it.

  * The convex KITE (4,0),(0,6),(−4,0),(0,−2), span axis (1,0) passes CONVEXITY +
    EQUAL-LENGTH + TOTAL-AREA (Σ width·length = 32 = the true shoelace area, ratio
    1.0) yet its per-band true areas (≈15.33, ≈16.67 m²) differ from the applied
    strip areas (12, 20 m²); the per-band gate catches it, and the
    rectangle-alignment gate rejects it earlier (a kite is not a rectangle).

  * The convex wide-middle hexagon and the NON-convex compensating-bulge decagon
    conserve TOTAL area exactly (ratio 1.0) yet mis-size individual members; the
    equal-length / convexity early-outs trip first, and the rectangle-alignment
    gate rejects both regardless.

Every non-rectangular shape defers to the per-cell fallback, which conserves BOTH
total load AND per-member distribution on any polygon. Girders PERPENDICULAR to
the joists (the ones the joists land on) receive no strip — they pick up the joist
end-reactions through the frame solve, which is the whole point of defect #1/#2.

PLANAR-XY ASSUMPTION: the rectangle-alignment gate, the total-area early-out and
the per-band check all assume a HORIZONTAL slab — the extents/areas are 2D XY
quantities, whereas the emitted `TributaryLoad`s integrate 3D element lengths. For
a pitched slab the two differ (Σ applied > true_area — conservative), so the slab
falls back to the per-cell path. All areas are m².

Restricted to slabs with exactly ONE framing level: a multi-level joist grid is a
two-way support lattice that this single-axis projection cannot represent, so
such slabs fall back to the historical per-cell path (no regression; flagged in
the runner NOTES).
"""
function _framed_slab_strip_geometry(struc::BuildingStructure, slab::Slab,
                                     frame_elements::Union{Nothing, Vector{<:Asap.Element}} = nothing)
    # Two-way joist grids (≥ 2 framing levels) are out of scope for the one-way
    # projection below — fall back to the per-cell path.
    length(slab.framing_levels) == 1 || return nothing

    # P0 (per-member load distribution): the midpoint-rule strips built below
    # partition the across-joist EXTENT and are applied over each member's FULL
    # length. Per-member correctness is enforced by the AUTHORITATIVE
    # rectangle-alignment gate below (the uniform strip is per-member exact only for
    # a rectangle aligned to the joist frame); the convexity check here, and the
    # constant-length + total-area + per-band checks below, are only cheap
    # EARLY-OUTS / defense-in-depth for the common fallback shapes. Fetch the true
    # interior polygon now (built from the boundary vertices via
    # `_slab_interior_polygon_m`, CCW, concave-safe) and its shoelace area (m²); an
    # unresolvable or degenerate boundary returns `nothing`, deferring to the
    # load-conserving per-cell path. Pure geometry — no code clause.
    interior_poly = _slab_interior_polygon_m(struc, slab)
    interior_poly === nothing && return nothing
    true_area_m2 = _polygon_area_m2(interior_poly)          # true slab area, m²
    true_area_m2 <= 0 && return nothing

    # EARLY-OUT GATE — CONVEXITY. A cheap short-circuit for non-convex bays
    # (L/T/U, the compensating-bulge decagon) before the per-band clip cost; NOT
    # the correctness guarantee. Sutherland–Hodgman clipping in the per-band gate
    # below is only well-defined bandwise on a simple polygon, and a non-convex
    # boundary is the classic shape whose midpoint bands mis-size individual
    # members while total area still matches — so decline it here. Pure geometry —
    # no code clause.
    Asap.is_convex_polygon(interior_poly) || return nothing

    skel = struc.skeleton

    # Level-1 joist beams for this slab.
    joist_beams = Int[]
    for fl in slab.framing_levels
        fl.group_id === nothing && continue
        grp = get(struc.member_groups, fl.group_id, nothing)
        grp === nothing && continue
        for mi in grp.member_indices
            (1 <= mi <= length(struc.beams)) || continue
            struc.beams[mi].role === :joist && push!(joist_beams, mi)
        end
    end
    isempty(joist_beams) && return nothing

    # Vertices touched by any joist chain. A genuine joist-PARALLEL edge girder
    # shares NONE of them: joists land on the PERPENDICULAR girders, subdividing
    # them at the landing vertices. Used below to reject a mis-oriented girder
    # that a joist actually lands on from also receiving a one-way strip — that
    # would double-count against the joist end-reactions the frame solve already
    # delivers onto it.
    joist_vertices = Set{Int}()
    for bi in joist_beams
        for si in segment_indices(struc.beams[bi])
            e = struc.segments[si].edge_idx
            v1, v2 = skel.edge_indices[e]
            push!(joist_vertices, v1, v2)
        end
    end

    """Planar midpoint (x, y) in meters of beam `bi`'s segment chain endpoints."""
    function beam_mid_xy(bi)
        w1, w2 = _member_end_vertices(struc, struc.beams[bi])
        p1 = _vertex_xy_m(skel, w1); p2 = _vertex_xy_m(skel, w2)
        return ((p1[1] + p2[1]) / 2, (p1[2] + p2[2]) / 2)
    end

    # Joist run direction t̂ (unit) from the first joist; across-joist axis n̂ ⟂ t̂.
    v1, v2 = _member_end_vertices(struc, struc.beams[joist_beams[1]])
    a = _vertex_xy_m(skel, v1); b = _vertex_xy_m(skel, v2)
    tx = b[1] - a[1]; ty = b[2] - a[2]
    tlen = hypot(tx, ty)
    tlen <= 0 && return nothing
    tx /= tlen; ty /= tlen
    nx = -ty; ny = tx                       # across-joist unit axis
    proj(x, y) = nx * x + ny * y            # signed position along n̂

    # AUTHORITATIVE GATE — RECTANGLE ALIGNED TO THE JOIST FRAME. The uniform
    # midpoint strip posted by `_emit_strip_loads!` integrates a CONSTANT intensity,
    # so its tributary centroid is pinned to each member's mid-span ⇒ a 50/50
    # end-reaction split. That is per-MEMBER exact — correct joist internal moment
    # AND the girder point loads the joist end-reactions become — ONLY for a true
    # rectangle whose sides are parallel to the joist span axis t̂ and the
    # across-joist axis n̂ (constant tributary width ⇒ uniform load ⇒ centroid at
    # mid-span). For ANY band sheared relative to its member — every
    # non-rectangular parallelogram, trapezoid, triangle, diamond, … — the TRUE
    # tributary centroid is off mid-span, so the joist end-reactions (and the
    # girder point loads they become) are per-member wrong even when totals
    # conserve and per-band AREAS match. Gate on the exact-rectangle test: project
    # every `interior_poly` vertex onto n̂ and t̂ and require the polygon area to
    # equal its joist-frame bounding-box area `n_extent · t_extent` within `rtol`.
    # A CONVEX polygon (guaranteed by the convexity early-out above) equals its
    # axis-aligned bounding-box area IFF it IS exactly that axis-aligned rectangle,
    # so this admits EXACTLY joist-frame-aligned rectangles and returns `nothing`
    # for every other shape → the per-member-conserving per-cell fallback. Not
    # over-restrictive: for a rectangle the joists span between one pair of opposite
    # sides and are therefore parallel to the other pair, so a valid rectangle is
    # always joist-frame-aligned. The cheaper convexity / constant-length /
    # total-area / per-band checks are retained below only as early-outs and
    # defense-in-depth. Pure geometry — no code clause.
    rtol = 1e-3
    n_lo_v =  Inf; n_hi_v = -Inf
    t_lo_v =  Inf; t_hi_v = -Inf
    for (px, py) in interior_poly
        np = nx * px + ny * py              # position along n̂ (across-joist)
        tp = tx * px + ty * py              # position along t̂ (joist span)
        np < n_lo_v && (n_lo_v = np); np > n_hi_v && (n_hi_v = np)
        tp < t_lo_v && (t_lo_v = tp); tp > t_hi_v && (t_hi_v = tp)
    end
    n_extent = n_hi_v - n_lo_v
    t_extent = t_hi_v - t_lo_v
    (n_extent > 0 && t_extent > 0) || return nothing
    abs(true_area_m2 / (n_extent * t_extent) - 1.0) <= rtol || return nothing

    # Perimeter girders (level 0) touching the slab boundary; keep the ones
    # PARALLEL to the joists (|t̂·ĝ| ≈ 1) — they are the slab's one-way edge
    # supports. Perpendicular girders (the joist landings) get no strip.
    boundary_edges = Set(slab_face_edge_ids(struc, slab))
    parallel_girders = Int[]
    for (bi, beam) in enumerate(struc.beams)
        level_of(beam) == 0 || continue
        any(struc.segments[si].edge_idx in boundary_edges
            for si in segment_indices(beam)) || continue
        gv1, gv2 = _member_end_vertices(struc, beam)
        ga = _vertex_xy_m(skel, gv1); gb = _vertex_xy_m(skel, gv2)
        gx = gb[1] - ga[1]; gy = gb[2] - ga[2]; gl = hypot(gx, gy)
        gl <= 0 && continue
        # Parallel to the joists within 22.5° (cos 22.5° ≈ 0.9239) — a stricter
        # gate than the old 0.7071 (45°), which was brittle for a girder near 45°.
        abs((gx * tx + gy * ty) / gl) >= 0.9239 || continue
        # A joist that LANDS on this girder shares a chain vertex with it; such a
        # girder receives the joist end-reactions through the solve and must NEVER
        # also get a one-way strip (double count). Skip it.
        shares_joist_vertex = false
        for si in segment_indices(beam)
            e = struc.segments[si].edge_idx
            v1, v2 = skel.edge_indices[e]
            if v1 in joist_vertices || v2 in joist_vertices
                shares_joist_vertex = true
                break
            end
        end
        shares_joist_vertex && continue
        push!(parallel_girders, bi)
    end

    # P2-a GUARD — never silently starve a joist-parallel one-way support. The
    # detection above captures a joist-parallel girder only when it touches a slab
    # BOUNDARY edge. A level-0 girder that runs parallel to the joists and lies
    # on/within the slab but is NOT captured — an INTERIOR parallel girder (no
    # boundary edge), or one the boundary-edge test missed — is a real one-way
    # support that would get NEITHER a strip NOR a joist end-reaction (the joists
    # run PARALLEL to it, so they never land on it), leaving it silently
    # under-loaded while the remaining strip members stay equal length and total
    # area still matches. Conservatively fall back to the per-cell path (which
    # conserves BOTH total and per-member load) whenever such an uncaptured
    # joist-parallel girder exists. The convexity gate above guarantees
    # `interior_poly` is convex, so a girder whose endpoints AND midpoint are all
    # on/within the polygon lies entirely inside it. Over-falling-back is
    # acceptable; starving a support is not. Pure geometry — no code clause.
    on_or_in_slab(px, py) = _point_in_polygon_xy(px, py, interior_poly) ||
                            _point_on_polygon_boundary(px, py, interior_poly)
    captured_supports = Set(parallel_girders)
    for (bi, beam) in enumerate(struc.beams)
        level_of(beam) == 0 || continue
        bi in captured_supports && continue
        gv1, gv2 = _member_end_vertices(struc, beam)
        ga = _vertex_xy_m(skel, gv1); gb = _vertex_xy_m(skel, gv2)
        gx = gb[1] - ga[1]; gy = gb[2] - ga[2]; gl = hypot(gx, gy)
        gl <= 0 && continue
        # Within the joist-parallel 22.5° cone. Use the EXACT threshold
        # `cosd(22.5)` (strict `>`), NOT the rounded literal 0.9239: a girder at
        # 22.499° has |cosθ| = 0.923886… < 0.9239 yet lies INSIDE the cone, so a
        # `>= 0.9239` test would miss it and let the strip path silently starve a
        # real one-way support. Over-capturing here only widens the conservative
        # fall-back, so the inclusive `> cosd(22.5)` is the safe choice.
        abs((gx * tx + gy * ty) / gl) > cosd(22.5) || continue
        gmx = 0.5 * (ga[1] + gb[1]); gmy = 0.5 * (ga[2] + gb[2])
        (on_or_in_slab(ga...) && on_or_in_slab(gb...) && on_or_in_slab(gmx, gmy)) || continue
        return nothing                                        # uncaptured parallel support
    end

    # Slab across-joist extent [n_min, n_max] from the true boundary polygon.
    boundary_vis, _ = _get_slab_boundary_vertices(struc, slab)
    isempty(boundary_vis) && return nothing
    ps = Float64[proj(_vertex_xy_m(skel, v)...) for v in boundary_vis]
    n_min, n_max = minimum(ps), maximum(ps)
    n_max - n_min <= 0 && return nothing

    # Support lines (joists + parallel edge girders), positioned along n̂.
    supports = Tuple{Float64, Int}[]        # (position_along_n, beam_index)
    for bi in joist_beams
        push!(supports, (proj(beam_mid_xy(bi)...), bi))
    end
    for bi in parallel_girders
        push!(supports, (proj(beam_mid_xy(bi)...), bi))
    end
    sort!(supports, by = first)

    # Midpoint-rule tributary: each support runs to the midpoint of the gap to its
    # neighbours, and to the slab edge for the extremes ⇒ the emitted band bounds
    # partition [n_min, n_max] (Σ widths = n_max - n_min). `bands[i] = (b_{i-1}, b_i)`
    # records member i's band along n̂ so the authoritative per-band tributary gate
    # below can clip `interior_poly` to exactly that band.
    n = length(supports)
    out = Tuple{Int, Float64}[]
    bands = Tuple{Float64, Float64}[]
    for i in 1:n
        pos_i = supports[i][1]
        left  = i == 1 ? n_min : 0.5 * (supports[i - 1][1] + pos_i)
        right = i == n ? n_max : 0.5 * (pos_i + supports[i + 1][1])
        w = right - left
        if w > 0
            push!(out, (supports[i][2], w))
            push!(bands, (left, right))
        end
    end
    isempty(out) && return nothing

    # EARLY-OUT GATE A — CONSTANT MEMBER LENGTH. A cheap short-circuit for the
    # common fallback shapes (it is NOT the correctness guarantee — the
    # rectangle-alignment gate above is). The midpoint strip is per-MEMBER-correct
    # only for a constant span-direction width, i.e. when every strip support member
    # (all joists AND both joist-parallel edge girders) has the SAME emitted length.
    # We measure each member's length on the SAME basis `_emit_strip_loads!`
    # integrates over (`frame_elements[edge_idx].length` when supplied, else the
    # skeleton `Segment.L` for the horizontal test probe — see
    # `_member_emitted_length_m`) and require them all equal within `rtol`; otherwise
    # return `nothing` so the slab uses the load-conserving per-cell fallback (which
    # conserves BOTH total load AND per-member distribution on any polygon). This
    # rejects the convex hexagon (6 ≠ 3), trapezoids, triangles and diamonds before
    # the per-band clip cost. Pure geometry — no code clause.
    strip_lengths_m = Float64[_member_emitted_length_m(struc, struc.beams[bi], frame_elements)
                              for (bi, _) in out]
    isempty(strip_lengths_m) && return nothing
    L_ref = first(strip_lengths_m)
    L_ref > 0 || return nothing
    all(L -> abs(L / L_ref - 1.0) <= rtol, strip_lengths_m) || return nothing

    # EARLY-OUT GATE B — TOTAL-AREA MATCH + planar-XY guard (another cheap
    # short-circuit, NOT the correctness guarantee). When the applied tributary
    # area Σ(width·length) does not match the true 2D XY shoelace area within
    # `rtol` the shape cannot be a valid one-way rectangle, so fall back before the
    # per-band clip. This also rejects a PITCHED slab: `true_area_m2` is a 2D XY
    # area while the emitted loads integrate 3D element lengths, so for a pitched
    # plate Σ applied > true_area (conservative) and we fall back. Reuses the
    # per-strip lengths already computed above. Both m².
    strip_area_m2 = sum(w_m * L for ((_, w_m), L) in zip(out, strip_lengths_m))
    abs(strip_area_m2 / true_area_m2 - 1.0) > rtol && return nothing

    # DEFENSE-IN-DEPTH GATE — PER-BAND PER-MEMBER TRIBUTARY AREA. A redundant
    # per-member check kept behind the authoritative rectangle-alignment gate above
    # (which already restricts the strip path to joist-frame rectangles, where every
    # band area is exact). It guards against a future reordering that might reach
    # here on a non-rectangle: e.g. the convex KITE (4,0),(0,6),(−4,0),(0,−2) passes
    # convexity + equal-length + total-area at ratio 1.0 yet its per-band true areas
    # (≈15.33, ≈16.67 m²) differ from the applied strip areas (12, 20 m²).
    # For each emitted strip we compare the APPLIED area (width·length, on the SAME
    # `_member_emitted_length_m` basis the emitter integrates over) against the TRUE
    # area of `interior_poly` clipped to that member's across-joist band
    # { b_{i-1} ≤ (p − origin)·n̂ ≤ b_i }. If ANY member's applied area deviates
    # from its true band area by more than `rtol` — or a member has a ~zero true
    # area under nonzero applied load — the strips would mis-distribute load, so
    # fall back to the load-conserving per-cell path. `origin` is (0, 0): `proj`
    # (hence n_min/n_max and the band bounds) measures position as the bare dot
    # product with n̂. Pure geometry — no code clause.
    origin = (0.0, 0.0)
    for (i, ((_, w_m), L)) in enumerate(zip(out, strip_lengths_m))
        b_lo, b_hi = bands[i]
        applied_i = w_m * L
        true_i = _polygon_band_area_m2(interior_poly, (nx, ny), origin, b_lo, b_hi)
        true_i <= rtol * true_area_m2 && return nothing        # ~zero true band
        abs(applied_i / true_i - 1.0) > rtol && return nothing
    end
    return out
end

"""Emit a uniform `Asap.TributaryLoad` of width `w_m` (meters) at `pressure` on
every frame element of each `(beam_index, w_m)` strip, appending to both `loads`
(the model load list) and `dest` (the per-cell bookkeeping vector)."""
function _emit_strip_loads!(loads::Vector{Asap.AbstractLoad},
                            dest::Vector{Asap.TributaryLoad},
                            frame_elements::Vector{<:Asap.Element},
                            struc::BuildingStructure,
                            strips::Vector{Tuple{Int, Float64}},
                            pressure::Unitful.Quantity,
                            dir::NTuple{3, Float64})
    for (bi, w_m) in strips
        w = w_m * u"m"
        for si in segment_indices(struc.beams[bi])
            e = struc.segments[si].edge_idx
            (1 <= e <= length(frame_elements)) || continue
            tl = Asap.TributaryLoad(frame_elements[e], [0.0, 1.0], [w, w], pressure, dir)
            push!(loads, tl)
            push!(dest, tl)
        end
    end
    return dest
end

"""
    _create_framed_slab_loads!(loads, frame_elements, struc, params;
                               use_patterns, combo) -> Set{Int}

Route the gravity pressure of every single-level joist-framed slab (see
[`_framed_slab_strip_geometry`](@ref)) onto its joists + joist-parallel edge
girders as one-way tributary strips, so the elastic frame solve produces the
supporting girders' demand envelope from the concentrated joist reactions
(defect #1/#2). Returns the set of cell indices whose load was handled here — the
caller skips those in the per-cell tributary loop so a framed slab's pressure is
applied exactly ONCE (no double counting). A slab whose geometry does not resolve
to a valid, load-conserving one-way strip layout (no joists, multi-level grid,
degenerate, or a strip layout that fails the runtime conservation check) is left
for the per-cell path (its cells are NOT added to the returned set) — that path
conserves load on any polygon, so nothing is dropped.

The emitted objects are raw `Asap.TributaryLoad`s (not an `Asap.AreaLoad`): a raw
`TributaryLoad` carries a `.element`, so `Asap.get_elemental_loads` — and hence
`member_group_demands` → `Asap.ElementForceAndDisplacement` — sees the joist
loads, whereas an `AreaLoad`'s lazily-expanded child loads never reach the
elemental-loads map and would leave the joist span demands understated.

The strip fast-path is used ONLY for a RECTANGLE aligned to the joist frame —
enforced inside [`_framed_slab_strip_geometry`](@ref) by the authoritative
rectangle-alignment gate (`interior_poly`'s area equals its joist-frame
bounding-box area `n_extent · t_extent` within `rtol`). The uniform midpoint strip
`_emit_strip_loads!` posts is a constant intensity ⇒ its resultant is pinned to
each member's mid-span, which is provably exact — correct joist internal moment
AND correct girder end-reactions — ONLY for such a rectangle (constant tributary
width ⇒ uniform load ⇒ mid-span centroid). EVERY other bay — non-rectangular
parallelograms (whose sheared bands throw the true tributary centroid off
mid-span, so their landing-girder point loads are per-member wrong even though
totals and per-band areas match), trapezoids, triangles, diamonds, kites,
hexagons, and non-convex L/T/U/decagon shapes — falls back to the per-cell path,
which conserves BOTH total load AND per-member distribution on any polygon. The
cheaper CONVEXITY, CONSTANT-MEMBER-LENGTH, TOTAL-AREA-MATCH and per-band
tributary-area checks are retained only as early-outs and defense-in-depth behind
that gate; none of them, even jointly, guarantees per-member correctness on a
sheared band. The member lengths are measured on the
`frame_elements[edge_idx].length` basis — the SAME length the emitted
`TributaryLoad`s integrate over — so the gate's basis provably equals the applied
basis. The reasoning assumes a HORIZONTAL (planar-XY) slab: the extents/areas are
2D XY quantities while the emitted loads integrate 3D element lengths; for a
pitched slab they differ (conservative ⇒ falls back).

Multi-cell framed slabs load the whole panel once under the FIRST cell's pressure
and zero the other cells' records, so the strip path is taken only when every cell
of the slab carries the SAME pressure; a multi-cell slab whose cells have
non-uniform `sdl` / `self_weight` / `live_load` falls back to the per-cell path
(which loads each cell at its own pressure). See the heterogeneous-pressure guard
below.

Pressure/pattern handling mirrors [`_create_cell_tributary_loads!`] and is stored
under the slab's FIRST cell index, so `sync_asap!`'s existing per-cell pressure
refresh keeps these loads current after sizing (`use_patterns` ⇒ split dead/live
into `cell_dead_loads`/`cell_live_loads`; else the combined envelope in
`cell_tributary_loads`). The other cells of a multi-cell framed slab record empty
load vectors.
"""
function _create_framed_slab_loads!(loads::Vector{Asap.AbstractLoad},
                                    frame_elements::Vector{<:Asap.Element},
                                    struc::BuildingStructure,
                                    params::DesignParameters;
                                    use_patterns::Bool,
                                    combo::LoadCombination)
    handled = Set{Int}()
    combos = params.load_combinations
    dir = (0.0, 0.0, -1.0)
    for slab in struc.slabs
        _slab_has_joist_framing(struc, slab) || continue
        isempty(slab.cell_indices) && continue
        c0 = first(slab.cell_indices)
        cell0 = struc.cells[c0]
        cell0.floor_type == :grade && continue

        # One-way strip geometry. Pass `frame_elements` so the member-length gate
        # measures lengths on the SAME basis the emitter integrates over. `nothing`
        # ⇒ leave this slab to the per-cell path (slab NOT marked handled) so no
        # load is dropped.
        strips = _framed_slab_strip_geometry(struc, slab, frame_elements)
        strips === nothing && continue

        # C3 DEFENSE-IN-DEPTH — uniform-pressure guard for multi-cell slabs. The
        # strip path below applies cell0's pressure (sdl / self_weight / live_load)
        # across the WHOLE slab and zeros the other cells' load records. That is
        # load-correct only when every cell of the slab carries the SAME pressure.
        # If any cell's sdl / self_weight / live_load differs from cell0's beyond
        # `rtol`, fall back to the per-cell path (which loads each cell at its own
        # pressure). Single-cell slabs are trivially uniform. Pure bookkeeping — no
        # code clause.
        if length(slab.cell_indices) > 1
            prtol = 1e-3
            pa(p) = ustrip(u"Pa", uconvert(u"Pa", p))
            near(a, b) = abs(a - b) <= prtol * max(abs(a), abs(b))
            p0_sdl = pa(cell0.sdl); p0_sw = pa(cell0.self_weight); p0_ll = pa(cell0.live_load)
            uniform = true
            for ci in slab.cell_indices
                ci == c0 && continue
                cell = struc.cells[ci]
                if !(near(pa(cell.sdl), p0_sdl) && near(pa(cell.self_weight), p0_sw) &&
                     near(pa(cell.live_load), p0_ll))
                    uniform = false
                    break
                end
            end
            uniform || continue
        end

        if use_patterns
            # ACI 318-19 §6.4.3 / §5.3.1 factored dead & live kept separate so the
            # pattern-loading multi-case solve (see `_create_cell_tributary_loads!`)
            # can vary the live term per bay.
            dead_p = uconvert(u"Pa", combo.D * (cell0.sdl + cell0.self_weight))
            live_p = uconvert(u"Pa", combo.L * cell0.live_load)
            dead_loads = Asap.TributaryLoad[]
            live_loads = Asap.TributaryLoad[]
            _emit_strip_loads!(loads, dead_loads, frame_elements, struc, strips, dead_p, dir)
            _emit_strip_loads!(loads, live_loads, frame_elements, struc, strips, live_p, dir)
            struc.cell_dead_loads[c0] = dead_loads
            struc.cell_live_loads[c0] = live_loads
            struc.cell_tributary_loads[c0] = vcat(dead_loads, live_loads)
        else
            combined_p = uconvert(u"Pa", envelope_pressure(combos,
                            cell0.sdl + cell0.self_weight, cell0.live_load))
            combined_loads = Asap.TributaryLoad[]
            _emit_strip_loads!(loads, combined_loads, frame_elements, struc, strips, combined_p, dir)
            struc.cell_dead_loads[c0] = Asap.TributaryLoad[]
            struc.cell_live_loads[c0] = Asap.TributaryLoad[]
            struc.cell_tributary_loads[c0] = combined_loads
        end

        # Mark all of the slab's cells handled; give the non-cell0 cells of a
        # multi-cell framed slab empty load records (the whole panel is loaded
        # once, under cell0).
        for ci in slab.cell_indices
            push!(handled, ci)
            if ci != c0
                struc.cell_dead_loads[ci] = Asap.TributaryLoad[]
                struc.cell_live_loads[ci] = Asap.TributaryLoad[]
                struc.cell_tributary_loads[ci] = Asap.TributaryLoad[]
            end
        end
    end
    return handled
end
