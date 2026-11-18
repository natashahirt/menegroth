using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful

# Columns stay on the skeleton. The slab edge moves out to the largest
# column face on each straight side.

const SS = StructuralSynthesizer

@testset "Slab edge outside the column centerlines" begin

    function _make_2x2_building(; bay_x=20.0u"ft", bay_y=20.0u"ft", h=10.0u"ft")
        skel = gen_medium_office(bay_x, bay_y, h, 2, 2, 1)
        struc = BuildingStructure(skel)
        initialize!(struc;
            floor_type=:flat_plate,
            floor_opts=StructuralSizer.FlatPlateOptions())
        return struc
    end

    @testset "Column centers stay on the vertices" begin
        struc = _make_2x2_building()
        for col in struc.columns
            col.c1 = 18.0u"inch"
            col.c2 = 18.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)
        update_structural_offsets!(struc; input_is_centerline=true)
        skel = struc.skeleton
        vc = skel.geometry.vertex_coords
        for col in struc.columns
            @test col.structural_offset == (0.0, 0.0)
            sx, sy = structural_center_xy_m(skel, col)
            @test sx ≈ vc[col.vertex_idx, 1]
            @test sy ≈ vc[col.vertex_idx, 2]
            if col.position == :interior
                @test isempty(col.boundary_inward_normals)
            end
        end
        # Normals are recorded for the edge and the corner. The center does not follow them.
        update_structural_offsets!(struc; input_is_centerline=false)
        for col in struc.columns
            @test col.structural_offset == (0.0, 0.0)
            if col.position == :interior
                @test isempty(col.boundary_inward_normals)
            else
                @test length(col.boundary_inward_normals) >= 1
                for n in col.boundary_inward_normals
                    @test hypot(n...) ≈ 1.0 atol = 1e-10
                end
            end
        end
    end

    @testset "The slab edge is flush with the largest column on a side" begin
        struc = _make_2x2_building()
        skel = struc.skeleton
        vc = skel.geometry.vertex_coords
        for col in struc.columns
            col.c1 = 12.0u"inch"
            col.c2 = 12.0u"inch"
        end
        # One south-edge column is the deep one. South is the minimum y.
        south = [col for col in struc.columns if col.position != :interior &&
                 vc[col.vertex_idx, 2] == minimum(vc[c.vertex_idx, 2] for c in struc.columns)]
        @test !isempty(south)
        south[1].c1 = 24.0u"inch"
        south[1].c2 = 24.0u"inch"
        overhang = SS.slab_vertex_overhang(struc)
        half_small = ustrip(u"m", 12.0u"inch") / 2
        half_large = ustrip(u"m", 24.0u"inch") / 2
        ys = [vc[v, 2] for v in keys(overhang)]
        y_south = minimum(ys)
        for (vi, off) in overhang
            y = vc[vi, 2]
            if y == y_south
                # Straight edge: every south vertex steps out by the large column.
                @test off[2] ≈ -half_large atol = 1e-6
            elseif y == maximum(ys)
                @test off[2] ≈ half_small atol = 1e-6
            end
        end
        # Growing that column moves the edge and leaves the vertex where it was.
        x0, y0 = vc[south[1].vertex_idx, 1], vc[south[1].vertex_idx, 2]
        south[1].c2 = 36.0u"inch"
        again = SS.slab_vertex_overhang(struc)
        @test again[south[1].vertex_idx][2] ≈ -ustrip(u"m", 36.0u"inch") / 2 atol = 1e-6
        @test vc[south[1].vertex_idx, 1] == x0
        @test vc[south[1].vertex_idx, 2] == y0
    end

    @testset "A drawn slab edge is shifted to centerlines once" begin
        skel = gen_medium_office(20.0u"ft", 20.0u"ft", 10.0u"ft", 1, 1, 1)
        struc = BuildingStructure(skel)
        rebuild_geometry_cache!(skel)
        before = copy(skel.geometry.vertex_coords)
        SS.apply_facade_setback!(struc)
        after = skel.geometry.vertex_coords
        moved = 0
        for i in 1:size(before, 1)
            (before[i, 1] == after[i, 1] && before[i, 2] == after[i, 2]) && continue
            moved += 1
            # Inward: closer to the plan centroid than the drawn point was.
        end
        @test moved > 0
        cx = sum(before[:, 1]) / size(before, 1)
        cy = sum(before[:, 2]) / size(before, 1)
        for i in 1:size(before, 1)
            (before[i, 1] == after[i, 1] && before[i, 2] == after[i, 2]) && continue
            d0 = hypot(before[i, 1] - cx, before[i, 2] - cy)
            d1 = hypot(after[i, 1] - cx, after[i, 2] - cy)
            @test d1 < d0
        end
        frozen = copy(after)
        SS.apply_facade_setback!(struc)
        @test skel.geometry.vertex_coords == frozen
    end

    @testset "The slab past the centerline loads edge members and edge columns" begin
        struc = _make_2x2_building()
        vc = struc.skeleton.geometry.vertex_coords
        for col in struc.columns
            col.c1 = 12.0u"inch"
            col.c2 = 12.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)
        w = ustrip(u"m", 12.0u"inch") / 2
        strips = SS.slab_edge_strips(struc)
        @test !isempty(strips)
        floors = unique(round(s.z, digits = 6) for s in strips)
        _len(s) = hypot(s.b[1] - s.a[1], s.b[2] - s.a[2])
        # A rectangle with one column size: perimeter × w, plus w² at each corner.
        for z in floors
            ss = [s for s in strips if round(s.z, digits = 6) == z]
            P = sum(_len, ss)
            @test sum(s.width * _len(s) for s in ss) ≈ P * w
            @test sum(s.corner_start for s in ss) ≈ 4w^2
            @test sum(SS.slab_edge_line_width(s) * _len(s) for s in ss) ≈ P * w + 4w^2
        end

        # Support areas at each floor: the cells plus the band.
        function _floor_support_area(z)
            keys_seen = Set{Tuple{Int, Int}}()
            total = 0.0
            for col in struc.columns
                abs(vc[col.vertex_idx, 3] - z) < 0.01 || continue
                key = (col.story, col.vertex_idx)
                key in keys_seen && continue
                push!(keys_seen, key)
                At = column_tributary_area(struc, col)
                At === nothing || (total += ustrip(u"m^2", At))
            end
            return total
        end
        function _floor_cell_area(z)
            sum(ustrip(u"m^2", c.area) for c in struc.cells
                if abs(vc[struc.skeleton.face_vertex_indices[c.face_idx][1], 3] - z) < 0.01)
        end
        z = first(floors)
        ss = [s for s in strips if round(s.z, digits = 6) == z]
        band = sum(s.width * _len(s) + s.corner_start for s in ss)
        @test _floor_support_area(z) ≈ _floor_cell_area(z) + band rtol = 1e-6
        # A second refresh replaces the strip shares instead of adding them again.
        update_structural_offsets!(struc; input_is_centerline=false)
        @test _floor_support_area(z) ≈ _floor_cell_area(z) + band rtol = 1e-6
        # The corner column gets its corner and half of each adjoining edge strip.
        corner = first(c for c in struc.columns
                       if c.position == :corner && abs(vc[c.vertex_idx, 3] - z) < 0.01)
        A_corner = sum(values(corner.tributary_cell_areas))
        bay = sqrt(ustrip(u"m^2", first(c for c in struc.cells if c.floor_type != :grade).area))
        @test A_corner ≈ (bay / 2)^2 + 2 * (bay / 2) * w + w^2 rtol = 1e-6

        # A larger edge column widens its whole side.
        south = [c for c in struc.columns if abs(vc[c.vertex_idx, 3] - z) < 0.01 &&
                 vc[c.vertex_idx, 2] ≈ minimum(vc[x.vertex_idx, 2] for x in struc.columns)]
        mid = first(c for c in south if c.position == :edge)
        mid.c2 = 24.0u"inch"
        update_structural_offsets!(struc; input_is_centerline=false)
        grown = [s for s in SS.slab_edge_strips(struc) if round(s.z, digits = 6) == z]
        band2 = sum(s.width * _len(s) + s.corner_start for s in grown)
        @test band2 ≈ band + 2bay * w + 2 * w * w rtol = 1e-6
        @test _floor_support_area(z) ≈ _floor_cell_area(z) + band2 rtol = 1e-6

        # The frame model carries the strip as uniform loads on the edge members.
        to_asap!(struc; params=DesignParameters(skip_visualization=true))
        loads = [ld for ld in struc.asap_model.loads
                 if ld isa Asap.TributaryLoad && ld.id === :slab_edge_strip]
        @test !isempty(loads)
        at_z = [ld for ld in loads
                if abs(ustrip(u"m", ld.element.nodeStart.position[3]) - z) < 0.01]
        len(ld) = ustrip(u"m", ld.element.length)
        # Pattern loading may split dead and live; each half covers the band once.
        n_per_strip = length(at_z) ÷ length(grown)
        @test n_per_strip * length(grown) == length(at_z)
        @test sum(ustrip(u"m", ld.widths[1]) * len(ld) for ld in at_z) / n_per_strip ≈ band2 rtol = 1e-6

        # Growing a column after to_asap!: sync_asap! widens the existing loads.
        mid.c2 = 36.0u"inch"
        update_structural_offsets!(struc; input_is_centerline=false)
        SS._sync_slab_edge_strip_widths!(struc)
        grown3 = [s for s in SS.slab_edge_strips(struc) if round(s.z, digits = 6) == z]
        band3 = sum(s.width * _len(s) + s.corner_start for s in grown3)
        @test band3 > band2
        @test sum(ustrip(u"m", ld.widths[1]) * len(ld) for ld in at_z) / n_per_strip ≈ band3 rtol = 1e-6
    end

    @testset "_column_half_dim_m returns correct half-dimension" begin
        col = Column([1], 10.0u"ft"; c1=24.0u"inch", c2=18.0u"inch")
        col.shape = :rectangular
        col.θ = 0.0

        half_x = SS._column_half_dim_m(col, (1.0, 0.0))
        @test isapprox(half_x, 0.3048, atol=0.001)

        half_y = SS._column_half_dim_m(col, (0.0, 1.0))
        @test isapprox(half_y, 0.2286, atol=0.001)

        col_circ = Column([1], 10.0u"ft"; c1=20.0u"inch", c2=20.0u"inch")
        col_circ.shape = :circular

        half_circ = SS._column_half_dim_m(col_circ, (1.0, 0.0))
        @test isapprox(half_circ, 0.254, atol=0.001)
    end

    @testset "The analysis plate covers the column and the column node stays put" begin
        struc = _make_2x2_building()
        skel = struc.skeleton
        for col in struc.columns
            col.c1 = 18.0u"inch"
            col.c2 = 18.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=true)
        support = Set(get(skel.groups_vertices, :support, Int[]))
        nodes = SS._create_offset_nodes(skel, Dict{Int, NTuple{2, Float64}}(), support)
        overhang = SS.slab_vertex_overhang(struc)
        slab = struc.slabs[1]
        boundary, _ = SS._get_slab_boundary_vertices(struc, slab)
        face = Dict{Int, Asap.Node}()
        spawned = Asap.Node[]
        corners, centers = SS._slab_outline_nodes!(
            skel, nodes, boundary, overhang, face, spawned)
        vc = skel.geometry.vertex_coords
        @test length(corners) == length(boundary)
        @test length(spawned) == count(vi -> hypot(get(overhang, vi, (0.0, 0.0))...) > 1e-8, boundary)
        @test length(spawned) > 0
        center_ids = Set(objectid(nd) for nd in centers)
        for (vi, corner) in zip(boundary, corners)
            off = get(overhang, vi, (0.0, 0.0))
            hypot(off...) > 1e-8 || continue
            @test objectid(corner) != objectid(nodes[vi])
            @test objectid(nodes[vi]) in center_ids
            @test ustrip(u"m", nodes[vi].position[1]) ≈ vc[vi, 1]
            @test ustrip(u"m", nodes[vi].position[2]) ≈ vc[vi, 2]
            @test ustrip(u"m", corner.position[1]) ≈ vc[vi, 1] + off[1]
            @test ustrip(u"m", corner.position[2]) ≈ vc[vi, 2] + off[2]
        end
    end
end
