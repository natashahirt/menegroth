const _WALL_PLAN_DZ_TOL_M = 1e-4

"""
    _chain_is_all_walls(edge_indices, wall_edges) -> Bool

`true` when every edge is in the `:walls` group. `false` when none are.
A mix throws `ArgumentError` so a `:walls` edge cannot become a `Beam`.
"""
function _chain_is_all_walls(edge_indices, wall_edges)::Bool
    n_wall = count(e -> e in wall_edges, edge_indices)
    n_wall == 0 && return false
    n_wall == length(edge_indices) && return true
    throw(ArgumentError(
        "initialize_members!: chain mixes :walls edges with other groups " *
        "($n_wall of $(length(edge_indices)) edges are :walls). " *
        "A :walls edge must not become a Beam."))
end

"""
    _require_wall_thickness(::Type{T}, wall_edges, wall_thickness) -> Union{T,Nothing}

`nothing` when `wall_edges` is empty (the thickness is not read). When the
`:walls` group is non-empty, `wall_thickness` must already be a positive `T`.
`nothing` throws `ArgumentError`. There is no default thickness and no unit
conversion.
"""
function _require_wall_thickness(::Type{T}, wall_edges, wall_thickness) where T
    isempty(wall_edges) && return nothing
    if isnothing(wall_thickness)
        throw(ArgumentError(
            "initialize_members!: groups_edges[:walls] is non-empty but " *
            "wall_thickness is nothing. Pass a wall thickness; there is no default."))
    end
    wall_thickness isa T || throw(ArgumentError(
        "initialize_members!: wall_thickness must be a $T, got " *
        "$(typeof(wall_thickness)) ($(repr(wall_thickness)))."))
    _length_positive(wall_thickness) || throw(ArgumentError(
        "initialize_members!: wall_thickness must be positive, got $wall_thickness"))
    return wall_thickness
end

"""True when `x` is a strictly positive length (bare number or Unitful length)."""
function _length_positive(x)
    x isa Unitful.Quantity && return ustrip(u"m", x) > 0
    x isa Real && return x > zero(x)
    return false
end

"""
True when two elevations of the same type agree within 1e-4 m
(the `_find_level_idx` exact-match tolerance).
"""
function _elevations_agree(a::T, b::T) where T
    d = abs(a - b)
    d_m = d isa Unitful.Quantity ? abs(ustrip(u"m", d)) : Float64(abs(d))
    return d_m <= 1e-4
end

"""
    _wall_pier_height(skel, story::Int) -> T

Pier height of a wall on 0-based `story`: elevation of the next higher story
whose `Story.faces` is non-empty, minus this story's elevation. Not the plan
edge length.

`rebuild_stories!` inserts a story for every unique vertex Z rounded to 1 cm,
including a vertex that belongs to no face. Starting at `story + 1`, skip
those stories. The story above is the next story index with a non-empty
`faces` vector.

Index rule, copied from `rebuild_stories!` and `_find_level_idx`:
`stories_z` is ascending and `stories_z[i]` is the floor of 0-based story
`i - 1` (`z_to_idx = i - 1`; `_find_level_idx` returns `i - 1`).
`skeleton.stories` uses that same key, and `stories[k].elevation` is that
floor. The cross-check uses the two story keys whose elevations are
subtracted — this story and the story above — not the next key:

- this floor = `stories[story].elevation` = `stories_z[story + 1]`
- the story above = `stories[above].elevation` = `stories_z[above + 1]`

If no higher story has faces, either elevation is missing, the two stores
disagree on an elevation that is used, or the height is not positive, throws
`ArgumentError`.
"""
function _wall_pier_height(skel::BuildingSkeleton{T}, story::Int) where T
    story >= 0 || throw(ArgumentError(
        "initialize_members!: wall story $story is negative"))
    haskey(skel.stories, story) || throw(ArgumentError(
        "initialize_members!: no skeleton Story at 0-based index $story"))
    # Next story index at or above story+1 whose faces are non-empty.
    # A vertex-only story is not a floor; pier stiffness scales as 1/H^3.
    above_key = nothing
    for k in sort!(collect(keys(skel.stories)))
        k <= story && continue
        if !isempty(skel.stories[k].faces)
            above_key = k
            break
        end
    end
    if isnothing(above_key)
        throw(ArgumentError(
            "initialize_members!: wall on 0-based story $story has no higher " *
            "story with faces. Pier height is this story's elevation to the " *
            "next story whose Story.faces is non-empty. Stories that contain " *
            "only vertices are skipped. The plan edge length is not used."))
    end
    floor_i = story + 1       # 1-based stories_z index of this floor
    above_i = above_key + 1   # 1-based stories_z index of the story above
    n = length(skel.stories_z)
    if floor_i < 1 || floor_i > n || above_i < 1 || above_i > n
        throw(ArgumentError(
            "initialize_members!: wall on 0-based story $story has no story-above " *
            "elevation (need stories_z[$floor_i] and stories_z[$above_i] for " *
            "stories $story and $above_key; stories_z has length $n). " *
            "Pier height is the vertical distance from this story's floor to " *
            "the next story with faces. The plan edge length is not used."))
    end
    z_floor = skel.stories[story].elevation
    z_above = skel.stories[above_key].elevation
    z_floor_vec = skel.stories_z[floor_i]
    z_above_vec = skel.stories_z[above_i]
    if !_elevations_agree(z_floor, z_floor_vec) || !_elevations_agree(z_above, z_above_vec)
        throw(ArgumentError(
            "initialize_members!: story elevations disagree between stories and " *
            "stories_z for the elevations used (0-based story $story → $above_key; " *
            "stories $z_floor → $z_above, stories_z[$floor_i]=$z_floor_vec, " *
            "stories_z[$above_i]=$z_above_vec). Refusing to guess the pier height."))
    end
    height = z_above - z_floor
    _length_positive(height) || throw(ArgumentError(
        "initialize_members!: non-positive pier height $height from story " *
        "$story to story $above_key"))
    return height
end

"""
Absolute difference [m] between a story elevation (`T`, possibly Unitful)
and a bare metre coordinate from `vertex_coords` column 3.
"""
function _abs_elev_diff_m(elev, z_m::Float64)
    elev_m = elev isa Unitful.Quantity ? Float64(ustrip(u"m", elev)) : Float64(elev)
    return abs(elev_m - z_m)
end

"""
    _wall_plan_z_m(skel, eidx, vc) -> Float64

Plan-line Z [m] of one `:walls` edge. Both ends already share Z within
`_WALL_PLAN_DZ_TOL_M`; the value used is their average.
"""
function _wall_plan_z_m(skel, eidx::Int, vc::Matrix{Float64})
    v1, v2 = skel.edge_indices[eidx]
    return (vc[v1, 3] + vc[v2, 3]) / 2
end

"""
    _story_nearest_plan_z(skel, z_m) -> Int

0-based story whose elevation is nearest `z_m` [m].

The story dict is not ordered by elevation, so this searches every story
and keeps the minimum distance. A nearest distance greater than
`_WALL_PLAN_DZ_TOL_M` (1e-4 m) throws `ArgumentError`. Two stories at that
same minimum also throw: dict order must not choose. The 0.1 m
[`edge_story`](@ref) window is not used.
"""
function _story_nearest_plan_z(skel::BuildingSkeleton, z_m::Float64)::Int
    isempty(skel.stories) && throw(ArgumentError(
        "initialize_members!: cannot assign Wall.story; the skeleton has no stories."))
    best_d = Inf
    for (_, story) in skel.stories
        d = _abs_elev_diff_m(story.elevation, z_m)
        d < best_d && (best_d = d)
    end
    if best_d > _WALL_PLAN_DZ_TOL_M
        throw(ArgumentError(
            "initialize_members!: wall plan-line Z $(z_m) m is $(best_d) m from " *
            "the nearest story elevation. Wall.story is the story whose elevation " *
            "is nearest that Z, and the distance must be ≤ $(_WALL_PLAN_DZ_TOL_M) m. " *
            "The 0.1 m edge_story window is not used."))
    end
    keys = Int[]
    for (k, story) in skel.stories
        _abs_elev_diff_m(story.elevation, z_m) == best_d && push!(keys, k)
    end
    if length(keys) != 1
        throw(ArgumentError(
            "initialize_members!: wall plan-line Z $(z_m) m is equally near " *
            "$(length(keys)) story elevations (0-based stories $(join(sort(keys), ", "))). " *
            "Refusing to pick one by story-dict order."))
    end
    return keys[1]
end

"""
    _push_wall!(struc, skel, seg_indices, edge_indices, thickness, vc)

Append one `Wall` for a plan edge or a shattered `:walls` chain.

`Wall.story` is the 0-based story whose elevation is nearest the plan-line
Z ([`_story_nearest_plan_z`](@ref)). Both ends already share that Z.
[`edge_story`](@ref) is not consulted. `base.L` is
[`_wall_pier_height`](@ref). Endpoints are the chain-end `vertex_coords`
columns 1–2 (metres), via [`_chain_endpoint_vertices`](@ref). `concrete`
stays `nothing`. A vertical edge (`|z2-z1|` above `_WALL_PLAN_DZ_TOL_M`)
throws `ArgumentError`.
"""
function _push_wall!(struc::BuildingStructure{T}, skel::BuildingSkeleton{T},
                     seg_indices::Vector{Int}, edge_indices, thickness,
                     vc::Matrix{Float64}) where T
    thickness isa T || throw(ArgumentError(
        "initialize_members!: wall thickness is missing or not a $T " *
        "(got $(repr(thickness)))"))
    for eidx in edge_indices
        v1, v2 = skel.edge_indices[eidx]
        dz = abs(vc[v1, 3] - vc[v2, 3])
        dz <= _WALL_PLAN_DZ_TOL_M || throw(ArgumentError(
            "initialize_members!: :walls edge $eidx is not a plan line " *
            "(|z2-z1| = $(dz) m). A vertical :walls edge is rejected; pier " *
            "height comes from story elevations, not the edge length."))
    end
    # Nearest plan-line elevation. edge_story's first hit inside 0.1 m can
    # assign a floor 5 cm away; pier stiffness then scales as 1/H^3.
    # Columns still use edge_story.
    story = nothing
    for eidx in edge_indices
        s = _story_nearest_plan_z(skel, _wall_plan_z_m(skel, eidx, vc))
        if story === nothing
            story = s
        elseif s != story
            throw(ArgumentError(
                "initialize_members!: wall chain edges do not share a story " *
                "(edge $(first(edge_indices)) is 0-based story $story, " *
                "edge $eidx is story $s). Wall.story is the story whose " *
                "elevation is nearest the plan-line Z."))
        end
    end
    story isa Int || throw(ArgumentError(
        "initialize_members!: wall has no edges, so Wall.story cannot be assigned."))
    height = _wall_pier_height(skel, story)
    va, vb = _chain_endpoint_vertices(skel, edge_indices)
    x1, y1 = vc[va, 1], vc[va, 2]
    x2, y2 = vc[vb, 1], vc[vb, 2]
    # Same numerical-degeneracy floor as `_WALLS_BRIDGE_DEGEN_TOL` (1e-9 m).
    hypot(x2 - x1, y2 - y1) > _WALLS_BRIDGE_DEGEN_TOL || throw(ArgumentError(
        "initialize_members!: wall plan line has zero length " *
        "($(x1), $(y1))–($(x2), $(y2)) m"))
    wall = Wall(seg_indices, height;
                thickness=thickness,
                x1=x1, y1=y1, x2=x2, y2=y2,
                story=story,
                concrete=nothing)
    push!(struc.walls, wall)
    return wall
end

"""
    link_wall_stack!(struc::BuildingStructure)

Populate `wall.wall_above` by matching the rounded plan center
([`wall_center`](@ref), [`COORD_DIGITS`](@ref)) and the next story.

`Wall.story` is the 0-based story index from the plan-line Z (nearest
elevation, not [`edge_story`](@ref)). The wall on story `s` links to the
wall with the same rounded center on story `s + 1`. This is not
`WallLine.story`: [`to_wall_line`](@ref) sets
`WallLine.story = Wall.story + 1` because `WallLine` is 1-based. Do not add
a further +1 here.

Two walls on the same story with the same rounded center throw
`ArgumentError` instead of overwriting the lookup. A wall with nothing
above keeps `wall_above = nothing`.

Called at the end of [`initialize_members!`](@ref).
"""
function link_wall_stack!(struc::BuildingStructure)
    WallT = eltype(struc.walls)
    lookup = Dict{Tuple{Float64, Float64, Int}, WallT}()
    for w in struc.walls
        cx, cy = wall_center(w)
        key = (round(cx; digits=COORD_DIGITS),
               round(cy; digits=COORD_DIGITS),
               w.story)
        if haskey(lookup, key)
            throw(ArgumentError(
                "link_wall_stack!: two walls on 0-based story $(w.story) share " *
                "plan center ($(key[1]), $(key[2])) m (rounded to $(COORD_DIGITS) " *
                "digits). Refusing to overwrite wall_above."))
        end
        lookup[key] = w
    end

    n_linked = 0
    for w in struc.walls
        cx, cy = wall_center(w)
        above_key = (round(cx; digits=COORD_DIGITS),
                     round(cy; digits=COORD_DIGITS),
                     w.story + 1)
        w.wall_above = get(lookup, above_key, nothing)
        !isnothing(w.wall_above) && (n_linked += 1)
    end

    @debug "Linked wall stack" total=length(struc.walls) linked=n_linked roof=(length(struc.walls) - n_linked)
end

# =============================================================================
# Member (Beam) Tributary Profiles — Layer 1 of the tributary pipeline
# =============================================================================
#
# Layer 0 (cells → cell edges) is `compute_cell_tributaries!`.
# Layer 1 (cells/panels → Level-0 beams) is `compute_member_tributaries!` below:
# it merges the per-cell edge tributaries that meet on each beam into a single
# variable `TributaryProfile` stored on the beam. The load path
# (`_create_cell_tributary_loads!`) still emits `Asap.TributaryLoad`s directly
# from the cell cache; these member profiles feed the design layer (effective
# flange width, and — in later phases — the level-to-level tributary cascade).

