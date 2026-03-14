using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful

# Helpers
const SS = StructuralSynthesizer

@testset "Structural Column Offset" begin

    # ── Helper: build a 2×2 bay, 1-story building and initialize members ──
    function _make_2x2_building(; bay_x=20.0u"ft", bay_y=20.0u"ft", h=10.0u"ft")
        skel = gen_medium_office(bay_x, bay_y, h, 2, 2, 1)
        struc = BuildingStructure(skel)
        initialize!(struc;
            floor_type=:flat_plate,
            floor_opts=StructuralSizer.FlatPlateOptions())
        return struc
    end

    @testset "Interior columns have zero offset" begin
        struc = _make_2x2_building()
        for col in struc.columns
            if col.position == :interior
                @test col.structural_offset == (0.0, 0.0)
            end
        end
    end

    @testset "Default input_is_centerline=true → all offsets zero" begin
        struc = _make_2x2_building()
        # Assign column dimensions
        for col in struc.columns
            col.c1 = 18.0u"inch"
            col.c2 = 18.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=true)
        for col in struc.columns
            @test col.structural_offset == (0.0, 0.0)
        end
    end

    @testset "Architectural input → edge/corner columns get nonzero offset" begin
        struc = _make_2x2_building()
        skel = struc.skeleton
        vc = skel.geometry.vertex_coords

        for col in struc.columns
            col.c1 = 18.0u"inch"
            col.c2 = 18.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)

        half_dim_m = ustrip(u"m", 18.0u"inch") / 2  # 9" ≈ 0.2286m

        for col in struc.columns
            ox, oy = col.structural_offset
            if col.position == :interior
                @test ox == 0.0
                @test oy == 0.0
            else
                # Every non-interior column must have a nonzero offset
                offset_mag = hypot(ox, oy)
                @test offset_mag > 0.0

                # The offset magnitude per unique normal direction should be
                # approximately half_dim_m. Total magnitude depends on how many
                # unique normal directions exist (1 for edge-like, 2 for true corner).
                n_unique = length(col.boundary_inward_normals)
                @test n_unique >= 1

                if n_unique == 1
                    # Single inward direction: offset ≈ half_dim_m
                    @test isapprox(offset_mag, half_dim_m, atol=0.01)
                elseif n_unique == 2
                    # Two orthogonal inward directions: offset ≈ sqrt(2) × half_dim_m
                    @test isapprox(offset_mag, sqrt(2) * half_dim_m, atol=0.01)
                end
            end
        end
    end

    @testset "Offset points inward (toward slab interior)" begin
        struc = _make_2x2_building()
        skel = struc.skeleton
        vc = skel.geometry.vertex_coords

        for col in struc.columns
            col.c1 = 18.0u"inch"
            col.c2 = 18.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)

        # Compute building centroid (average of all face centroids)
        cx, cy, n = 0.0, 0.0, 0
        for face_vis in skel.face_vertex_indices
            for vi in face_vis
                cx += vc[vi, 1]; cy += vc[vi, 2]; n += 1
            end
        end
        cx /= n; cy /= n

        for col in struc.columns
            col.position == :interior && continue
            vi = col.vertex_idx
            arch_x, arch_y = vc[vi, 1], vc[vi, 2]
            ox, oy = col.structural_offset
            struct_x = arch_x + ox
            struct_y = arch_y + oy

            # Structural center should be closer to building centroid than architectural
            dist_arch = hypot(arch_x - cx, arch_y - cy)
            dist_struct = hypot(struct_x - cx, struct_y - cy)
            @test dist_struct < dist_arch
        end
    end

    @testset "structural_center_xy_m returns offset position" begin
        struc = _make_2x2_building()
        skel = struc.skeleton
        vc = skel.geometry.vertex_coords

        for col in struc.columns
            col.c1 = 24.0u"inch"
            col.c2 = 24.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)

        for col in struc.columns
            sx, sy = structural_center_xy_m(skel, col)
            vi = col.vertex_idx
            vx, vy = vc[vi, 1], vc[vi, 2]
            ox, oy = col.structural_offset
            @test isapprox(sx, vx + ox, atol=1e-12)
            @test isapprox(sy, vy + oy, atol=1e-12)
        end
    end

    @testset "Offset scales with column size" begin
        struc = _make_2x2_building()

        # Small columns
        for col in struc.columns
            col.c1 = 12.0u"inch"
            col.c2 = 12.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)
        small_offsets = Dict(col.vertex_idx => col.structural_offset for col in struc.columns)

        # Large columns
        for col in struc.columns
            col.c1 = 24.0u"inch"
            col.c2 = 24.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)

        for col in struc.columns
            col.position == :interior && continue
            ox_small = hypot(small_offsets[col.vertex_idx]...)
            ox_large = hypot(col.structural_offset...)
            @test ox_large > ox_small
            # Should scale roughly linearly (ratio ≈ 2.0 for 24/12)
            ratio = ox_large / ox_small
            @test isapprox(ratio, 2.0, atol=0.1)
        end
    end

    @testset "Idempotent: calling twice gives same result" begin
        struc = _make_2x2_building()
        for col in struc.columns
            col.c1 = 18.0u"inch"
            col.c2 = 18.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)
        first_pass = Dict(col.vertex_idx => col.structural_offset for col in struc.columns)

        update_structural_offsets!(struc; input_is_centerline=false)
        for col in struc.columns
            @test col.structural_offset == first_pass[col.vertex_idx]
        end
    end

    @testset "Inward normals populated for edge/corner" begin
        struc = _make_2x2_building()
        for col in struc.columns
            col.c1 = 18.0u"inch"
            col.c2 = 18.0u"inch"
        end
        update_structural_offsets!(struc; input_is_centerline=false)

        for col in struc.columns
            if col.position == :interior
                @test isempty(col.boundary_inward_normals)
            else
                # Non-interior columns have at least 1 unique inward normal
                @test length(col.boundary_inward_normals) >= 1
                for n in col.boundary_inward_normals
                    @test isapprox(hypot(n...), 1.0, atol=1e-10)
                end
            end
        end
    end

    @testset "_column_half_dim_m returns correct half-dimension" begin
        # Axis-aligned rectangular column: 24" × 18"
        col = Column([1], 10.0u"ft"; c1=24.0u"inch", c2=18.0u"inch")
        col.shape = :rectangular
        col.θ = 0.0

        # In X direction: c1/2 = 12" = 0.3048m
        half_x = SS._column_half_dim_m(col, (1.0, 0.0))
        @test isapprox(half_x, 0.3048, atol=0.001)

        # In Y direction: c2/2 = 9" = 0.2286m
        half_y = SS._column_half_dim_m(col, (0.0, 1.0))
        @test isapprox(half_y, 0.2286, atol=0.001)

        # Circular column: D/2 in any direction
        col_circ = Column([1], 10.0u"ft"; c1=20.0u"inch", c2=20.0u"inch")
        col_circ.shape = :circular

        half_circ = SS._column_half_dim_m(col_circ, (1.0, 0.0))
        @test isapprox(half_circ, 0.254, atol=0.001)  # 10" = 0.254m
    end
end
