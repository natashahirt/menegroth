"""
    gen_medium_office(x, y, floor_height, x_bays, y_bays, n_stories;
                      irregular=:none, offset=0.0u"m", core=:none)

Generate a medium office building skeleton.

# Arguments
- `irregular::Symbol`: Column shift pattern for irregular bays
  - `:none` - Regular rectangular grid (default)
  - `:shift_x` - Shift interior columns in x by ±offset (alternating rows)
  - `:shift_y` - Shift interior columns in y by ±offset (alternating columns)
  - `:zigzag` - Alternating shift in both directions
  - `:trapezoid` - Shift interior x-columns by ±offset alternating by column index
    (creates true trapezoids: adjacent columns in the same row shift opposite
    directions, so every bay has unequal-length horizontal edges)
- `offset::Unitful.Length`: Amount to shift interior columns (default 0.0m)
- `core::Symbol`: Lateral-force-resisting core to add after the frame is built
  - `:none` - Bare frame, no shear walls (default)
  - `:center_box` - A closed box of shear walls around the central bay, braced
    over the full height. See [`add_center_core!`](@ref). Give the resulting
    skeleton a `DesignParameters.wall_thickness`; `:walls` edges require one.
"""
function gen_medium_office(x::Unitful.Length, y::Unitful.Length, floor_height::Unitful.Length, 
                           x_bays::Int64, y_bays::Int64, n_stories::Int64;
                           irregular::Symbol=:none, offset::Unitful.Length=0.0u"m",
                           core::Symbol=:none)::BuildingSkeleton
    # convert everything to meters internally
    x = uconvert(u"m", x)
    y = uconvert(u"m", y)
    floor_height = uconvert(u"m", floor_height)
    offset = uconvert(u"m", offset)

    T = typeof(x)
    skel = BuildingSkeleton{T}()
    
    # get bay spans
    x_span = round(ustrip(x/x_bays), digits=2) * unit(x)
    y_span = round(ustrip(y/y_bays), digits=2) * unit(y)

    # get stories_z (starting from 0.0)
    push!(skel.stories_z, round(ustrip(0.0*floor_height), digits=2) * unit(floor_height))
    for k in 1:n_stories
        push!(skel.stories_z, round(ustrip(k*floor_height), digits=2) * unit(floor_height))
    end

    # helper function with optional column shift for irregular grids
    function get_pt(i, j, k)
        base_x = i * x_span
        base_y = j * y_span
        
        # Only shift interior columns (not edges)
        is_interior_x = 0 < i < x_bays
        is_interior_y = 0 < j < y_bays
        
        dx = zero(x)
        dy = zero(y)
        
        if irregular == :shift_x && is_interior_x
            # Alternate direction based on row
            dx = iseven(j) ? offset : -offset
        elseif irregular == :shift_y && is_interior_y
            # Alternate direction based on column
            dy = iseven(i) ? offset : -offset
        elseif irregular == :zigzag && (is_interior_x || is_interior_y)
            # Checkerboard-style shift
            if is_interior_x
                dx = iseven(i + j) ? offset : -offset
            end
            if is_interior_y
                dy = iseven(i + j) ? offset : -offset
            end
        elseif irregular == :trapezoid && is_interior_x
            # Alternate direction based on column index — adjacent interior
            # columns shift opposite ways, creating true trapezoids where
            # opposite horizontal edges have different lengths.
            dx = iseven(i) ? offset : -offset
        end
        
        return Meshes.Point(base_x + dx, base_y + dy, skel.stories_z[k+1])
    end

    # get elements
    for k in 0:n_stories
        # Story 0 is the support level. Its faces stay in `:grade`. It is not
        # a floor, so it does not get a beam grid between the column bases.
        if k > 0
            # x direction beams
            for j in 0:y_bays, i in 0:(x_bays-1)
                p1 = get_pt(i, j, k)
                p2 = get_pt(i+1, j, k)
                add_element!(skel, Meshes.Segment(p1, p2), group=:beams, level_idx=k)
            end
            # y direction beams
            for i in 0:x_bays, j in 0:(y_bays-1)
                p1 = get_pt(i, j, k)
                p2 = get_pt(i, j+1, k)
                add_element!(skel, Meshes.Segment(p1, p2), group=:beams, level_idx=k)
            end
        end
        # columns
        for i in 0:x_bays, j in 0:y_bays
            if k > 0
                p_bot = get_pt(i, j, k-1)
                p_top = get_pt(i, j, k)
                add_element!(skel, Meshes.Segment(p_bot, p_top), group=:columns, level_idx=k)
            end
        end
    end

    # designate points (add_vertex! will assign known points to a group)
    for i in 0:x_bays, j in 0:y_bays
        # story 0 points are support nodes
        add_vertex!(skel, get_pt(i, j, 0), group=:support)
        # story n_stories points are the roof (no DOF implications but nice to have)
        add_vertex!(skel, get_pt(i, j, n_stories), group=:roof)
    end

    # postprocessing - find the faces
    find_faces!(skel)

    # find faces and categorize them based on their loading requirements
    for (level_idx, story) in skel.stories
        target_grp = if level_idx == 0
            :grade
        elseif level_idx == n_stories
            :roof
        else
            :floor
        end
        if !haskey(skel.groups_faces, target_grp)
            skel.groups_faces[target_grp] = Int[]
        end
        append!(skel.groups_faces[target_grp], story.faces)
    end

    # Lateral system. `find_faces!` has already populated each story's faces,
    # which the wall pier-height needs, so the core is added last.
    if core === :center_box
        add_center_core!(skel, get_pt, x_bays, y_bays, n_stories)
    elseif core !== :none
        throw(ArgumentError("gen_medium_office: unknown core :$core (expected :none or :center_box)"))
    end

    return skel
end

"""
    _claim_or_add_wall_edge!(skel, p1, p2, level_idx) -> Int

Ensure the plan edge `p1`–`p2` at `level_idx` belongs to the `:walls` group,
returning its edge index.

If an edge already spans those two points (a floor beam), it is moved into
`:walls` — removed from every other edge group so it cannot also become a
`Beam` (`initialize_members!` rejects an edge that is in two groups). If no such
edge exists (the grade level, where `gen_medium_office` lays no beams), a new
`:walls` edge is added between the points.
"""
function _claim_or_add_wall_edge!(skel::BuildingSkeleton, p1::Meshes.Point,
                                  p2::Meshes.Point, level_idx::Int)
    v1 = find_vertex(skel, p1)
    v2 = find_vertex(skel, p2)
    ei = (v1 === nothing || v2 === nothing) ? nothing : find_edge(skel, v1, v2)
    if ei === nothing
        return add_element!(skel, Meshes.Segment(p1, p2); group=:walls, level_idx=level_idx)
    end
    # Claim the existing edge: drop it from every non-wall group, add to :walls.
    for (g, members) in skel.groups_edges
        g === :walls && continue
        filter!(!=(ei), members)
    end
    walls = get!(skel.groups_edges, :walls, Int[])
    ei in walls || push!(walls, ei)
    return ei
end

"""
    add_center_core!(skel, get_pt, x_bays, y_bays, n_stories) -> skel

Add a closed box of shear walls around the central bay of a DOE office grid,
forming a lateral-force-resisting core braced over the full height.

The four plan edges of the central bay are put into the `:walls` group on every
story from grade through the story just below the roof. A `:walls` plan edge at
floor level `k` becomes a `Wall` with `story = k` spanning `z = k·h → (k+1)·h`
(`_push_wall!`), so edges on levels `0 … n_stories-1` brace physical stories
`1 … n_stories` — the entire height. The roof face stays a slab, and the four
box corners are existing column lines that already reach the roof, so no extra
roof vertices are needed (unlike an interior shaft core).

`get_pt(i, j, k)` is the grid point generator from [`gen_medium_office`](@ref),
so the core honours any `irregular` column shifts. The central bay is the one
whose lower-left corner is column `((x_bays-1)÷2, (y_bays-1)÷2)`; for an odd bay
count this is the exact middle, and for an even count it is the lower-middle bay.

ACI 318-11 §10.10: these walls give the frame a lateral system, so the stability
index `Q` (Eq. 10-10) and story drift can be evaluated — instead of a bare sway
frame with `ψ → ∞` crashing the Jackson–Moreland alignment chart.

The resulting skeleton has a non-empty `:walls` group, so a design run must
supply `DesignParameters.wall_thickness`.
"""
function add_center_core!(skel::BuildingSkeleton, get_pt, x_bays::Int, y_bays::Int,
                          n_stories::Int)
    ci = (x_bays - 1) ÷ 2
    cj = (y_bays - 1) ÷ 2
    # Corner column indices of the central bay, walked as a closed loop.
    corner_ij = ((ci, cj), (ci + 1, cj), (ci + 1, cj + 1), (ci, cj + 1))
    for k in 0:(n_stories - 1), e in 1:4
        (ai, aj) = corner_ij[e]
        (bi, bj) = corner_ij[mod1(e + 1, 4)]
        _claim_or_add_wall_edge!(skel, get_pt(ai, aj, k), get_pt(bi, bj, k), k)
    end
    return skel
end