"""
    gen_medium_office(x, y, floor_height, x_bays, y_bays, n_stories; irregular=:none, offset=0.0u"m")

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
"""
function gen_medium_office(x::Unitful.Length, y::Unitful.Length, floor_height::Unitful.Length, 
                           x_bays::Int64, y_bays::Int64, n_stories::Int64;
                           irregular::Symbol=:none, offset::Unitful.Length=0.0u"m")::BuildingSkeleton
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

    return skel
end