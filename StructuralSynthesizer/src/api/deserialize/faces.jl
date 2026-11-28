
"""Rebuild stories then add explicit faces or find/auto-categorize faces."""
function _add_faces!(skel::BuildingSkeleton, input::APIInput, coord_unit, _to_m)
    if isempty(skel.vertices)
        error("Cannot rebuild stories: no vertices found in skeleton")
    end
    rebuild_stories!(skel)
    if isempty(skel.stories_z)
        error("rebuild_stories! failed to populate stories_z from $(length(skel.vertices)) vertices")
    end
    has_explicit = !isempty(input.faces) && any(!isempty(polys) for polys in values(input.faces))
    find_faces!(skel)
    _auto_categorize_faces!(skel)
    rebuild_geometry_cache!(skel)
    if has_explicit
        _apply_explicit_face_groups!(skel, input.faces, _to_m)
        # A face the polygons leave out is a void; its edges become slab edges.
        rebuild_geometry_cache!(skel)
    end
end
function _apply_explicit_face_groups!(skel::BuildingSkeleton{T}, face_groups::APIFaceGroups, _to_m) where T
    for (category, _) in face_groups
        skel.groups_faces[Symbol(category)] = Int[]
    end

    vc = skel.geometry.vertex_coords
    face_to_story = Dict{Int, Int}()
    for (story_idx, story) in skel.stories
        for face_idx in story.faces
            face_to_story[face_idx] = story_idx
        end
    end

    for (category, polylines) in face_groups
        group = Symbol(category)
        for (poly_idx, poly_coords) in enumerate(polylines)
            length(poly_coords) >= 3 || continue

            poly_xy = [(_to_m(c[1]) |> ustrip, _to_m(c[2]) |> ustrip) for c in poly_coords]
            z_val = _to_m(poly_coords[1][3])
            level_idx = _find_level_idx(skel, z_val)

            matched = Int[]
            for (face_idx, vis) in enumerate(skel.face_vertex_indices)
                get(face_to_story, face_idx, typemin(Int)) == level_idx || continue
                # The vertex average of an L or a U falls in the notch. A point
                # inside the face stays on the slab the polygon named.
                loop = NTuple{2, Float64}[(vc[vi, 1], vc[vi, 2]) for vi in vis]
                pin = _interior_point(loop)
                _point_in_polygon_2d(pin[1], pin[2], poly_xy) && push!(matched, face_idx)
            end

            if isempty(matched)
                throw(ArgumentError(
                    "Explicit face \"$category\"[$poly_idx] did not match any detected skeleton faces. " *
                    "Ensure selector geometry overlaps slab cells on the target story."))
            end
            append!(skel.groups_faces[group], matched)
        end
    end
end

"""Auto-categorise faces by story level (bottom → :grade, top → :roof, middle → :floor)."""
function _auto_categorize_faces!(skel::BuildingSkeleton{T}) where T
    isempty(skel.stories) && return

    sorted_levels = sort(collect(keys(skel.stories)))
    min_level = first(sorted_levels)
    max_level = last(sorted_levels)

    for (level_idx, story) in skel.stories
        target_grp = if level_idx == min_level
            :grade
        elseif level_idx == max_level
            :roof
        else
            :floor
        end
        if !haskey(skel.groups_faces, target_grp)
            skel.groups_faces[target_grp] = Int[]
        end
        append!(skel.groups_faces[target_grp], story.faces)
    end
end

"""Find the story level index for a given Z elevation. Returns a 0-indexed level,
or the nearest story if no exact match is found (with a warning)."""
function _find_level_idx(skel::BuildingSkeleton{T}, z_val) where T
    z_stripped = ustrip(z_val)
    best_idx = 0
    best_dist = Inf
    for (i, sz) in enumerate(skel.stories_z)
        dist = abs(ustrip(sz) - z_stripped)
        if dist < 1e-4
            return i - 1  # 0-indexed, exact match
        end
        if dist < best_dist
            best_dist = dist
            best_idx = i - 1
        end
    end
    @warn "Face at z=$z_val does not match any story elevation exactly; " *
          "snapping to nearest story (level $best_idx, distance=$(round(best_dist; digits=4)))"
    return best_idx
end

"""2D point-in-polygon test with boundary-inclusive tolerance."""
function _point_in_polygon_2d(x::Float64, y::Float64, poly::Vector{Tuple{Float64, Float64}})
    n = length(poly)
    n < 3 && return false

    inside = false
    j = n
    for i in 1:n
        xi, yi = poly[i]
        xj, yj = poly[j]
        if _point_on_segment_2d(x, y, xi, yi, xj, yj)
            return true
        end
        intersects = ((yi > y) != (yj > y)) &&
                     (x < (xj - xi) * (y - yi) / (yj - yi + 1e-16) + xi)
        inside = intersects ? !inside : inside
        j = i
    end
    return inside
end

"""Boundary check helper for 2D point-in-polygon."""
function _point_on_segment_2d(px, py, x1, y1, x2, y2; tol=1e-8)
    dx = x2 - x1
    dy = y2 - y1
    seg_len_sq = dx^2 + dy^2
    seg_len_sq <= tol^2 && return hypot(px - x1, py - y1) <= tol
    t = ((px - x1) * dx + (py - y1) * dy) / seg_len_sq
    (t < -tol || t > 1 + tol) && return false
    qx = x1 + clamp(t, 0.0, 1.0) * dx
    qy = y1 + clamp(t, 0.0, 1.0) * dy
    return hypot(px - qx, py - qy) <= tol
end
