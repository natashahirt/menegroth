function gen_medium_office(x::Unitful.Length, y::Unitful.Length, floor_height::Unitful.Length, x_bays::Int64, y_bays::Int64, n_floors::Int64)::StructureSkeleton
    # expect linear values
    # convert everything to meters internally
    x = uconvert(u"m", x)
    y = uconvert(u"m", y)
    floor_height = uconvert(u"m", floor_height)

    T = typeof(x)
    skel = StructureSkeleton{T}()
    
    # get bay spans
    x_span, y_span = x/x_bays, y/y_bays

    # helper function
    get_pt(i, j, k) = Meshes.Point(i*x_span, j*y_span, k*floor_height)

    # get elements
    for k in 1:n_floors
        # x direction beams
        for j in 0:y_bays, i in 0:(x_bays-1)
            p1 = get_pt(i, j, k)
            p2 = get_pt(i+1, j, k)
            add_element!(skel, Meshes.Segment(p1, p2), :beams)
        end
        # y direction beams
        for i in 0:x_bays, j in 0:(y_bays-1)
            p1 = get_pt(i, j, k)
            p2 = get_pt(i, j+1, k)
            add_element!(skel, Meshes.Segment(p1, p2), :beams)
        end
        # columns
        for i in 0:x_bays, j in 0:y_bays
            p_bot = get_pt(i, j, k-1)
            p_top = get_pt(i, j, k)
            add_element!(skel, Meshes.Segment(p_bot, p_top), :columns)
        end
    end

    # designate points (add_vertex! will assign known points to a group)
    for i in 0:x_bays, j in 0:y_bays
        # level 0 points are the foundation
        add_vertex!(skel, get_pt(i, j, 0), group=:foundation)
        # level n_floors points are the roof
        add_vertex!(skel, get_pt(i, j, n_floors), group=:roof)
    end

    return skel
end