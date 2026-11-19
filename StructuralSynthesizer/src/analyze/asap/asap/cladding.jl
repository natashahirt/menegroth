# Curtain-wall dead load on perimeter beams.
#
# ASCE 7-22 §3.1.1 (corpus: asce-7-22, PDF page 72) includes cladding in the
# dead load. §12.7.2 (PDF page 184) includes that dead load in the seismic
# weight above the base. §12.8.6.1 and §12.8.7 (PDF pages 187–188) carry the
# same dead load into Px at a factor no greater than 1.0.
#
# ENGINEERING JUDGMENT. Those clauses do not define the façade surface or
# which floor supports a band. The band on one perimeter edge is `wall_SDL`
# times the story height times the edge length. Half of that weight is a line
# load on the beam at each end of the story, the same split already used for
# wall self-weight. A band with no beam at its lower end hangs from the upper
# beam. An edge that is a structural wall, or that a wall pier covers, is
# omitted so the wall shell is not also given curtain-wall weight.

"""Stories from the bottom up, as `(index, elevation_m)`."""
function _stories_bottom_up(skel)
    rows = Tuple{Int, Float64}[]
    for (idx, story) in skel.stories
        push!(rows, (idx, Asap.to_meters(story.elevation)))
    end
    sort!(rows; by=last)
    for i in 2:length(rows)
        dz = rows[i][2] - rows[i - 1][2]
        dz > 1e-3 || throw(ArgumentError(
            "cladding: story $(rows[i][1]) at $(rows[i][2]) m is within 1 mm of " *
            "story $(rows[i - 1][1]) at $(rows[i - 1][2]) m. A façade band needs " *
            "a story height."))
    end
    return rows
end

"""
Horizontal edges at elevation `z_m` that belong to one slab face.

A boundary edge is one graph edge in exactly one slab face. Each entry is
`(edge, x1, y1, x2, y2, length)`, in metres.
"""
function _perimeter_edges_at(skel, z_m::Float64)
    geo = skel.geometry
    geo === nothing && throw(ArgumentError(
        "cladding: skeleton.geometry is missing, so the perimeter cannot be " *
        "found. Build the geometry cache before to_asap!."))
    vc = geo.vertex_coords
    efc = geo.edge_face_counts
    edges = Tuple{Int, Float64, Float64, Float64, Float64, Float64}[]
    for (e, (a, b)) in enumerate(skel.edge_indices)
        get(efc, e, 0) == 1 || continue
        za, zb = vc[a, 3], vc[b, 3]
        abs(za - zb) > 0.01 && continue
        abs(za - z_m) > 0.02 && continue
        x1, y1 = vc[a, 1], vc[a, 2]
        x2, y2 = vc[b, 1], vc[b, 2]
        L = hypot(x2 - x1, y2 - y1)
        L > 1e-6 || continue
        push!(edges, (e, x1, y1, x2, y2, L))
    end
    return edges
end

"""Horizontal edge at `z_m` with the same plan ends, or `nothing`."""
function _edge_matching_plan(skel, x1, y1, x2, y2, z_m)
    vc = skel.geometry.vertex_coords
    for (e, (a, b)) in enumerate(skel.edge_indices)
        abs(vc[a, 3] - z_m) > 0.02 && continue
        abs(vc[b, 3] - z_m) > 0.02 && continue
        ax, ay = vc[a, 1], vc[a, 2]
        bx, by = vc[b, 1], vc[b, 2]
        same = (hypot(ax - x1, ay - y1) <= 1e-3 && hypot(bx - x2, by - y2) <= 1e-3) ||
               (hypot(ax - x2, ay - y2) <= 1e-3 && hypot(bx - x1, by - y1) <= 1e-3)
        same && return e
    end
    return nothing
end

"""True when the wall pier covers at least half of this façade band."""
function _pier_covers_band(span, x1, y1, x2, y2, z_lo, z_hi)
    height = z_hi - z_lo
    height > 0 || return false
    overlap_z = min(span.z_top, z_hi) - max(span.z_bot, z_lo)
    overlap_z >= 0.5 * height || return false
    dx, dy = span.x2 - span.x1, span.y2 - span.y1
    L = hypot(dx, dy)
    L <= 1e-9 && return false
    ux, uy = dx / L, dy / L
    # Perpendicular distance to the wall centerline. `tol` reaches the wall
    # face plus a small placement gap, so a beam on that pier is the wall's
    # edge and not a second curtain wall.
    tol = max(span.t_m * 0.5 + 0.05, 0.15)
    dist(x, y) = abs((x - span.x1) * uy - (y - span.y1) * ux)
    (dist(x1, y1) <= tol && dist(x2, y2) <= tol) || return false
    along(x, y) = (x - span.x1) * ux + (y - span.y1) * uy
    a1, a2 = minmax(along(x1, y1), along(x2, y2))
    overlap = min(a2, L) - max(a1, 0.0)
    return overlap >= 0.5 * hypot(x2 - x1, y2 - y1)
end

"""
Façade bands above the base.

Each band is the perimeter edge at the top of a story. `lower_edge` is the
beam at the bottom with the same plan line. `nothing` means that beam does
not exist, and the whole band hangs from `upper_edge`.
"""
function _cladding_bands(struc::BuildingStructure)
    ustrip(struc.cladding_SDL) > 0 || return NamedTuple[]
    skel = struc.skeleton
    stories = _stories_bottom_up(skel)
    length(stories) >= 2 || return NamedTuple[]
    wall_edges = Set(get(skel.groups_edges, :walls, Int[]))
    spans = [_wall_pier_geometry(wall, skel) for wall in struc.walls]
    bands = NamedTuple[]
    for i in 2:length(stories)
        z_hi = stories[i][2]
        z_lo = stories[i - 1][2]
        for (e, x1, y1, x2, y2, L) in _perimeter_edges_at(skel, z_hi)
            lower = _edge_matching_plan(skel, x1, y1, x2, y2, z_lo)
            if e in wall_edges || (lower !== nothing && lower in wall_edges)
                continue
            end
            covered = false
            for span in spans
                if _pier_covers_band(span, x1, y1, x2, y2, z_lo, z_hi)
                    covered = true
                    break
                end
            end
            covered && continue
            push!(bands, (
                upper_edge = e,
                lower_edge = lower,
                length_m = L,
                height_m = z_hi - z_lo,
                x_m = 0.5 * (x1 + x2),
                y_m = 0.5 * (y1 + y2),
                z_upper_m = z_hi,
                z_lower_m = z_lo,
            ))
        end
    end
    return bands
end

"""Unfactored downward line intensity [N/m] on each skeleton edge."""
function _cladding_edge_intensity(struc::BuildingStructure)
    acc = Dict{Int, Float64}()
    p = ustrip(u"Pa", struc.cladding_SDL)
    p > 0 || return acc
    for band in _cladding_bands(struc)
        # N/m² times the story height is the full-band intensity.
        w = p * band.height_m
        if band.lower_edge === nothing
            acc[band.upper_edge] = get(acc, band.upper_edge, 0.0) + w
        else
            half = 0.5 * w
            acc[band.upper_edge] = get(acc, band.upper_edge, 0.0) + half
            acc[band.lower_edge] = get(acc, band.lower_edge, 0.0) + half
        end
    end
    return acc
end

"""Store `params.loads.wall_SDL` on the structure. A negative pressure throws."""
function _assign_cladding_pressure!(struc::BuildingStructure, params::DesignParameters)
    p = uconvert(unit(struc.cladding_SDL), params.loads.wall_SDL)
    ustrip(p) < 0 && throw(ArgumentError(
        "cladding: wall_SDL is $(params.loads.wall_SDL). Curtain-wall dead " *
        "load cannot be negative."))
    struc.cladding_SDL = p
    return p
end

"""
Append factored `:cladding` line loads, one per loaded perimeter edge.

`patterned` selects the same dead factor as wall self-weight. The stored
pressure stays unfactored. A zero `wall_SDL` appends nothing.
"""
function append_cladding_loads!(loads, elements, struc::BuildingStructure,
                               params::DesignParameters; patterned::Bool)
    _assign_cladding_pressure!(struc, params)
    ustrip(struc.cladding_SDL) > 0 || return loads
    factor = _self_weight_dead_factor(params; patterned)
    for (edge, wz) in _cladding_edge_intensity(struc)
        (1 <= edge <= length(elements)) || throw(ArgumentError(
            "cladding: perimeter edge $edge is outside the frame " *
            "(1:$(length(elements)))."))
        w = factor * wz
        push!(loads, Asap.LineLoad(elements[edge],
            [0.0u"N/m", 0.0u"N/m", -w * u"N/m"], :cladding))
    end
    return loads
end

"""Unfactored `:cladding` line loads for the dead case and the service solve."""
function unfactored_cladding_loads(struc::BuildingStructure, elements)
    loads = Asap.LineLoad[]
    ustrip(struc.cladding_SDL) > 0 || return loads
    for (edge, wz) in _cladding_edge_intensity(struc)
        (1 <= edge <= length(elements)) || throw(ArgumentError(
            "cladding: perimeter edge $edge is outside the frame " *
            "(1:$(length(elements)))."))
        push!(loads, Asap.LineLoad(elements[edge],
            [0.0u"N/m", 0.0u"N/m", -wz * u"N/m"], :cladding))
    end
    return loads
end

"""
Replace `:cladding` line loads from the current `wall_SDL` and dead factor.

Called from `sync_asap!` so a combination change rescales the façade with the
slab dead load.
"""
function _sync_cladding_line_loads!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return
    filter!(ld -> !(ld isa Asap.LineLoad && ld.id === :cladding), model.loads)
    append_cladding_loads!(model.loads, model.frame_elements, struc, params;
                           patterned = _pattern_dead_split(struc, params))
    return
end

"""
Lump façade weight onto story elevations.

Half of each band goes to the floor at each end. A band with no lower beam
goes entirely to the upper floor. The share that lands on the base is still
counted in `total` and is left out of W by the caller, the same way as a wall.
"""
function _deposit_cladding!(acc, struc, elevs, allowed)
    p = ustrip(u"kN/m^2", struc.cladding_SDL)
    p > 0 || return 0.0
    total = 0.0
    for band in _cladding_bands(struc)
        w = p * band.height_m * band.length_m
        if band.lower_edge === nothing
            k = _elf_elevation_key(band.z_upper_m, elevs)
            _elf_deposit!(acc, k, w, band.x_m, band.y_m, allowed)
        else
            ku = _elf_elevation_key(band.z_upper_m, elevs)
            kl = _elf_elevation_key(band.z_lower_m, elevs)
            _elf_deposit!(acc, ku, 0.5 * w, band.x_m, band.y_m, allowed)
            _elf_deposit!(acc, kl, 0.5 * w, band.x_m, band.y_m, allowed)
        end
        total += w
    end
    return total
end
