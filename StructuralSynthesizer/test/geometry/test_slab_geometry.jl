# =============================================================================
# Tests for Slab Geometry
# =============================================================================
#
# Tests convexity detection, face detection on awkward beam layouts, and frame
# line creation.
#
# =============================================================================

using Test
using Unitful

# Add the project to the load path (standalone execution)
push!(LOAD_PATH, joinpath(@__DIR__, "..", "..", ".."))
using StructuralSynthesizer

"""Square of beams (or `group` members) with its lower-left corner at `(x0, y0)`."""
function _member_square!(skel, x0, y0, L, z; group = :beams)
    vs = [add_vertex!(skel, [x0, y0, z]), add_vertex!(skel, [x0 + L, y0, z]),
          add_vertex!(skel, [x0 + L, y0 + L, z]), add_vertex!(skel, [x0, y0 + L, z])]
    for i in 1:4
        add_element!(skel, vs[i], vs[mod1(i + 1, 4)]; group = group)
    end
    return vs
end

function _faces_of!(skel)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    return skel
end

@testset "Slab Geometry" begin
    
    # =========================================================================
    # Convexity Tests
    # =========================================================================
    @testset "Convexity Detection" begin
        
        @testset "Convex polygons" begin
            # Square (convex)
            square = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
            @test is_convex_polygon(square) == true
            
            # Rectangle (convex)
            rect = [(0.0, 0.0), (2.0, 0.0), (2.0, 1.0), (0.0, 1.0)]
            @test is_convex_polygon(rect) == true
            
            # Triangle (convex)
            triangle = [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)]
            @test is_convex_polygon(triangle) == true
            
            # Pentagon (convex, regular-ish)
            pentagon = [
                (0.5, 0.0), (1.0, 0.4), (0.8, 1.0), 
                (0.2, 1.0), (0.0, 0.4)
            ]
            @test is_convex_polygon(pentagon) == true
            
            # Hexagon (convex)
            hexagon = [
                (0.5, 0.0), (1.0, 0.25), (1.0, 0.75),
                (0.5, 1.0), (0.0, 0.75), (0.0, 0.25)
            ]
            @test is_convex_polygon(hexagon) == true
        end
        
        @testset "Concave polygons" begin
            # L-shape (concave)
            l_shape = [
                (0.0, 0.0), (2.0, 0.0), (2.0, 1.0),
                (1.0, 1.0), (1.0, 2.0), (0.0, 2.0)
            ]
            @test is_convex_polygon(l_shape) == false
            
            # U-shape (concave)
            u_shape = [
                (0.0, 0.0), (3.0, 0.0), (3.0, 2.0),
                (2.0, 2.0), (2.0, 1.0), (1.0, 1.0),
                (1.0, 2.0), (0.0, 2.0)
            ]
            @test is_convex_polygon(u_shape) == false
            
            # T-shape (concave)
            t_shape = [
                (0.0, 1.0), (0.0, 2.0), (3.0, 2.0),
                (3.0, 1.0), (2.0, 1.0), (2.0, 0.0),
                (1.0, 0.0), (1.0, 1.0)
            ]
            @test is_convex_polygon(t_shape) == false
            
            # Star (very concave)
            star = [
                (0.5, 0.0), (0.6, 0.4), (1.0, 0.4),
                (0.7, 0.6), (0.8, 1.0), (0.5, 0.75),
                (0.2, 1.0), (0.3, 0.6), (0.0, 0.4),
                (0.4, 0.4)
            ]
            @test is_convex_polygon(star) == false
            
            # Pac-man shape (concave)
            pacman = [
                (0.5, 0.5), (1.0, 0.0), (1.0, 0.4),
                (0.6, 0.5), (1.0, 0.6), (1.0, 1.0),
                (0.0, 1.0), (0.0, 0.0)
            ]
            @test is_convex_polygon(pacman) == false
        end
        
        @testset "Edge cases" begin
            # Single point
            @test is_convex_polygon([(0.0, 0.0)]) == true
            
            # Two points (line)
            @test is_convex_polygon([(0.0, 0.0), (1.0, 1.0)]) == true
            
            # Empty
            @test is_convex_polygon(Tuple{Float64, Float64}[]) == true
            
            # Collinear points (degenerate polygon)
            collinear = [(0.0, 0.0), (1.0, 0.0), (2.0, 0.0)]
            @test is_convex_polygon(collinear) == true  # Degenerate but "convex"
        end
        
        @testset "Different input formats" begin
            # Using vectors instead of tuples
            square_vec = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
            @test is_convex_polygon(square_vec) == true
        end
    end

    # =========================================================================
    # Face detection on awkward member layouts
    # =========================================================================
    @testset "Face detection" begin
        z = 3.0

        @testset "A beam ending inside a bay throws" begin
            skel = BuildingSkeleton{Float64}()
            vs = _member_square!(skel, 0.0, 0.0, 6.0, z)
            tip = add_vertex!(skel, [3.0, 2.0, z])
            add_element!(skel, vs[1], tip; group = :beams)
            rebuild_stories!(skel)
            err = try
                find_faces!(skel)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("bound no face", err.msg)
            @test occursin("(3.0, 2.0) m", err.msg)
        end

        @testset "A beam floating in a bay throws" begin
            skel = BuildingSkeleton{Float64}()
            _member_square!(skel, 0.0, 0.0, 6.0, z)
            a = add_vertex!(skel, [2.0, 2.0, z])
            b = add_vertex!(skel, [4.0, 2.0, z])
            add_element!(skel, a, b; group = :beams)
            rebuild_stories!(skel)
            @test_throws ArgumentError find_faces!(skel)
        end

        @testset "A free-standing beam ring is a hole of the outer face" begin
            skel = _faces_of!(let s = BuildingSkeleton{Float64}()
                _member_square!(s, 0.0, 0.0, 10.0, z)
                _member_square!(s, 4.0, 4.0, 2.0, z)
                s
            end)
            @test length(skel.face_vertex_indices) == 2
            outer = argmax(f -> ustrip(u"m^2", face_area(skel, f)), 1:2)
            inner = 3 - outer
            @test length(face_hole_loops(skel, outer)) == 1
            @test isempty(face_hole_loops(skel, inner))
            @test ustrip(u"m^2", face_net_area(skel, outer)) ≈ 96.0
            @test ustrip(u"m^2", face_net_area(skel, inner)) ≈ 4.0
            @test face_opening_loops(skel, outer) == face_hole_loops(skel, outer)
        end

        @testset "A second face detection does not count a ring twice" begin
            # Hole side length → expected net area of the 10 m outer bay.
            # A larger ring removes more slab, and repeating find_faces! must
            # not remove it again.
            for (side, net) in ((2.0, 96.0), (4.0, 84.0))
                skel = BuildingSkeleton{Float64}()
                _member_square!(skel, 0.0, 0.0, 10.0, z)
                o = (10.0 - side) / 2
                _member_square!(skel, o, o, side, z)
                _faces_of!(skel)
                find_faces!(skel)
                outer = argmax(f -> ustrip(u"m^2", face_area(skel, f)), 1:2)
                @test length(face_hole_loops(skel, outer)) == 1
                @test length(skel.face_hole_vertices[outer]) == 1
                @test ustrip(u"m^2", face_net_area(skel, outer)) ≈ net
            end
        end

        @testset "Nested rings attach to the nearest enclosing face" begin
            skel = _faces_of!(let s = BuildingSkeleton{Float64}()
                _member_square!(s, 0.0, 0.0, 12.0, z)
                _member_square!(s, 2.0, 2.0, 8.0, z)
                _member_square!(s, 5.0, 5.0, 2.0, z)
                s
            end)
            nets = sort([ustrip(u"m^2", face_net_area(skel, f)) for f in 1:3])
            @test nets ≈ [4.0, 60.0, 80.0]
        end

        @testset "An opening inside the ring belongs to the inner face" begin
            skel = BuildingSkeleton{Float64}()
            _member_square!(skel, 0.0, 0.0, 10.0, z)
            _member_square!(skel, 4.0, 4.0, 2.0, z)
            _faces_of!(skel)
            add_slab_opening!(skel, [(4.5, 4.5), (5.5, 4.5), (5.5, 5.5), (4.5, 5.5)],
                              only(keys(skel.stories)))
            outer = argmax(f -> ustrip(u"m^2", face_area(skel, f)), 1:2)
            inner = 3 - outer
            @test isempty(face_openings(skel, outer))
            @test face_openings(skel, inner) == [1]
            @test ustrip(u"m^2", face_net_area(skel, outer)) ≈ 96.0
            @test ustrip(u"m^2", face_net_area(skel, inner)) ≈ 3.0
        end

        @testset "A grid's own perimeter is not a hole of an interior bay" begin
            # 4 × 4 bays of 6 × 5 m. The perimeter's interior point lands in
            # the bay at x 12–18, y 10–15, which shares no vertex with it.
            skel = BuildingSkeleton{Float64}()
            xs, ys = 0.0:6.0:24.0, 0.0:5.0:20.0
            id = Dict((i, j) => add_vertex!(skel, [x, y, z])
                      for (i, x) in enumerate(xs) for (j, y) in enumerate(ys))
            for i in eachindex(xs), j in eachindex(ys)
                i < length(xs) && add_element!(skel, id[(i, j)], id[(i + 1, j)]; group = :beams)
                j < length(ys) && add_element!(skel, id[(i, j)], id[(i, j + 1)]; group = :beams)
            end
            _faces_of!(skel)
            @test length(skel.face_vertex_indices) == 16
            @test isempty(skel.face_holes)
            @test all(f -> ustrip(u"m^2", face_net_area(skel, f)) ≈ 30.0,
                      eachindex(skel.face_vertex_indices))
        end

        @testset "Walls inside a bay stay line supports" begin
            skel = BuildingSkeleton{Float64}()
            vs = _member_square!(skel, 0.0, 0.0, 6.0, z)
            tip = add_vertex!(skel, [3.0, 2.0, z])
            add_element!(skel, vs[1], tip; group = :walls)
            a = add_vertex!(skel, [2.0, 4.0, z])
            b = add_vertex!(skel, [4.0, 4.0, z])
            add_element!(skel, a, b; group = :walls)
            _faces_of!(skel)
            @test length(skel.face_vertex_indices) == 1
            @test isempty(skel.face_holes)
        end
    end
    
    # =========================================================================
    # FrameLine Tests
    # =========================================================================
        @testset "A sloped floor edge is refused" begin
            z = 3.0
            function square_at(rise)
                skel = BuildingSkeleton{Float64}()
                vs = [add_vertex!(skel, [0.0, 0.0, z]), add_vertex!(skel, [6.0, 0.0, z]),
                      add_vertex!(skel, [6.0, 6.0, z + rise]), add_vertex!(skel, [0.0, 6.0, z])]
                for i in 1:4
                    add_element!(skel, vs[i], vs[mod1(i + 1, 4)]; group = :beams)
                end
                rebuild_stories!(skel)
                return skel
            end
            err = try
                find_faces!(square_at(0.02))
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("sloped", err.msg)
            @test occursin("0.02", err.msg)
            @test occursin("(6.0, 0.0) m", err.msg)
            @test occursin("(6.0, 6.0) m", err.msg)
            # A column is short in plan, so its height is not a floor slope.
            skel = BuildingSkeleton{Float64}()
            top = _member_square!(skel, 0.0, 0.0, 6.0, z)
            for v in top
                c = vertex_coords(skel, v)
                g = add_vertex!(skel, [c.x, c.y, 0.0])
                add_element!(skel, g, v; group = :columns)
            end
            @test length(_faces_of!(skel).face_vertex_indices) == 1
            # Half a millimetre is still one level face.
            @test length(_faces_of!(square_at(0.0005)).face_vertex_indices) == 1
            # A steeper edge is still refused, and says how far it rises.
            steeper = try
                find_faces!(square_at(0.05))
                nothing
            catch e
                e
            end
            @test steeper isa ArgumentError
            @test occursin("0.05", steeper.msg)
        end

    @testset "FrameLine Construction" begin
        
        # Mock column type
        struct MockColumn
            id::Int
            x::Float64
            y::Float64
            width::Float64
        end
        
        @testset "Simple X-direction frame" begin
            # Three columns along X-axis
            columns = [
                MockColumn(1, 0.0, 5.0, 1.0),
                MockColumn(2, 10.0, 5.0, 1.0),
                MockColumn(3, 20.0, 5.0, 1.0)
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:x, columns, 15.0, get_pos, get_width)
            
            @test n_joints(fl) == 3
            @test n_spans(fl) == 2
            @test isapprox(fl.direction[1], 1.0, atol=1e-6)
            @test isapprox(fl.direction[2], 0.0, atol=1e-6)
            @test fl.tributary_width == 15.0
            
            # Span lengths = center-to-center - half widths
            # 10 - 0.5 - 0.5 = 9.0
            @test all(isapprox.(fl.span_lengths, [9.0, 9.0], atol=0.01))
            
            # Joint positions
            @test fl.joint_positions == [:exterior, :interior, :exterior]
        end
        
        @testset "Y-direction frame" begin
            columns = [
                MockColumn(1, 5.0, 0.0, 1.5),
                MockColumn(2, 5.0, 12.0, 1.5),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:y, columns, 10.0, get_pos, get_width)
            
            @test n_joints(fl) == 2
            @test n_spans(fl) == 1
            @test isapprox(fl.direction[1], 0.0, atol=1e-6)
            @test isapprox(fl.direction[2], 1.0, atol=1e-6)
            
            # Span = 12 - 0 - 0.75 - 0.75 = 10.5
            @test isapprox(fl.span_lengths[1], 10.5, atol=0.01)
            @test fl.joint_positions == [:exterior, :exterior]
        end
        
        @testset "Columns get sorted by position" begin
            # Columns in wrong order
            columns = [
                MockColumn(3, 20.0, 0.0, 1.0),
                MockColumn(1, 0.0, 0.0, 1.0),
                MockColumn(2, 10.0, 0.0, 1.0),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:x, columns, 10.0, get_pos, get_width)
            
            # Should be sorted by X position
            @test fl.columns[1].id == 1
            @test fl.columns[2].id == 2
            @test fl.columns[3].id == 3
        end
        
        @testset "Rotated frame (45°)" begin
            # Columns along 45° diagonal
            columns = [
                MockColumn(1, 0.0, 0.0, 1.0),
                MockColumn(2, 5.0, 5.0, 1.0),
                MockColumn(3, 10.0, 10.0, 1.0),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            # 45° direction
            dir = (cosd(45), sind(45))
            fl = FrameLine(dir, columns, 8.0, get_pos, get_width)
            
            @test n_joints(fl) == 3
            @test n_spans(fl) == 2
            
            # Span = sqrt(5² + 5²) - widths ≈ 7.07 - 1.0 = 6.07
            expected_span = sqrt(50) - 1.0
            @test isapprox(fl.span_lengths[1], expected_span, atol=0.1)
        end
        
        @testset "End span detection" begin
            columns = [
                MockColumn(1, 0.0, 0.0, 1.0),
                MockColumn(2, 10.0, 0.0, 1.0),
                MockColumn(3, 20.0, 0.0, 1.0),
                MockColumn(4, 30.0, 0.0, 1.0),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:x, columns, 10.0, get_pos, get_width)
            
            @test is_end_span(fl, 1) == true   # First span
            @test is_end_span(fl, 2) == false  # Interior span
            @test is_end_span(fl, 3) == true   # Last span
        end

        @testset "Length widths convert from meters" begin
            # 18 ft centers, 16 inch columns → ℓn = 16.667 ft. Feet and meters
            # are both lengths, so Unitful converts either one.
            stations = (0.0u"ft", 18.0u"ft", 36.0u"ft")
            for xs in (stations, uconvert.(u"m", stations))
                cols = [(x = x, width = 16.0u"inch") for x in xs]
                fl = FrameLine(:x, cols, 14.0u"ft", c -> (c.x, zero(c.x)), (c, dir) -> c.width)
                @test ustrip(u"ft", fl.center_spans[1]) ≈ 18.0 rtol=1e-9
                @test ustrip(u"ft", fl.span_lengths[1]) ≈ 18.0 - 16.0 / 12 rtol=1e-9
                @test ustrip(u"ft", fl.column_projections[2]) ≈ 18.0 rtol=1e-9
            end
        end
    end

    @testset "A concave quad keeps its plan area" begin
        # (0,0), (3,1), (0,2), (1,1). The reflex vertex bites the polygon.
        # A fan from (0,0) measures 4 m²; the polygon is 2 m². A deeper bite
        # (reflex at x = 1.5) is 1.5 m². A square stays its own area.
        function _quad(pts)
            skel = BuildingSkeleton{Float64}()
            vs = [add_vertex!(skel, [x, y, 3.0]) for (x, y) in pts]
            for i in eachindex(vs)
                add_element!(skel, vs[i], vs[mod1(i + 1, length(vs))]; group = :beams)
            end
            _faces_of!(skel)
            return skel
        end
        dent = _quad([(0.0, 0.0), (3.0, 1.0), (0.0, 2.0), (1.0, 1.0)])
        @test length(dent.faces) == 1
        a = ustrip(u"m^2", face_area(dent, 1))
        @test a ≈ 2.0 atol = 1e-9
        rebuild_geometry_cache!(dent)
        @test ustrip(u"m^2", face_area(dent, 1)) ≈ a atol = 1e-12
        deeper = _quad([(0.0, 0.0), (3.0, 1.0), (0.0, 2.0), (1.5, 1.0)])
        @test ustrip(u"m^2", face_area(deeper, 1)) ≈ 1.5 atol = 1e-9
        @test ustrip(u"m^2", face_area(deeper, 1)) < a
        square = BuildingSkeleton{Float64}()
        _member_square!(square, 0.0, 0.0, 4.0, 3.0)
        _faces_of!(square)
        @test ustrip(u"m^2", face_area(square, 1)) ≈ 16.0 atol = 1e-9
    end

end  # Main testset
