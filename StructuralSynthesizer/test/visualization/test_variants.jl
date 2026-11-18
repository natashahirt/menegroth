using Test
using Unitful
using Asap
using StructuralSynthesizer

function _variant_beam()
    E = 200e9u"Pa"
    G = 77e9u"Pa"
    ρ = 7850.0u"kg/m^3"
    sec = Asap.Section(4.0e-3u"m^2", E, G, 4.0e-5u"m^4", 1.2e-5u"m^4", 8.0e-7u"m^4", ρ)
    n1 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], :fixed)
    n2 = Asap.Node([4.0u"m", 0.0u"m", 0.0u"m"], :free)
    beam = Asap.Element(n1, n2, sec, :beam)
    load = Asap.LineLoad(beam, [0.0u"N/m", 0.0u"N/m", -5.0e3u"N/m"])
    return Asap.Model([n1, n2], Asap.Element[beam], Asap.AbstractLoad[load])
end

function _replace_displacement(packet, values::Vector{Float32})
    buffers = StructuralSynthesizer.SceneBuffer[]
    for buffer in packet.buffers
        push!(buffers, buffer.name == "node_displacement" ? StructuralSynthesizer.SceneBuffer("node_displacement", values) : buffer)
    end
    return ScenePacket(packet.stages, packet.origin, packet.meta, buffers)
end

function _part(variant, role)
    for part in variant["parts"]
        part["role"] == role && return part
    end
    return nothing
end

@testset "variant scenes" begin
    @testset "every parameter has an anchor" begin
        @test Set(keys(PARAM_ANCHOR)) == Set(fieldnames(DesignParameters))
        snaps = [param_snapshot(DesignParameters()), param_snapshot(DesignParameters(deflection_limit = :L_240))]
        axes = variant_axes(snaps)
        @test any(axis -> axis["field"] == "deflection_limit" && axis["anchor"] == "none", axes)
        @test_throws ErrorException variant_axes([
            Dict("not_a_field" => Dict("hash" => "a", "label" => "a")),
        ])
    end

    @testset "a second design shares unchanged blocks and stays on the geometry" begin
        packet = build_scene(_variant_beam())
        doubled = scene_f32(packet, "node_displacement") .* 2
        other = _replace_displacement(packet, doubled)
        path = tempname() * ".mgscene"
        try
            id1 = append_variant!(path, packet; geometry_hash = "building-a", params = DesignParameters())
            id2 = append_variant!(path, other;
                geometry_hash = "building-a", params = DesignParameters(deflection_limit = :L_240))
            index = read_variant_index(path)
            @test index["geometry_hash"] == "building-a"
            @test length(index["variants"]) == 2
            left = _part(index["variants"][1], "frame")
            right = _part(index["variants"][2], "frame")
            @test left["blocks"]["node_position"] == right["blocks"]["node_position"]
            @test left["blocks"]["node_displacement"] != right["blocks"]["node_displacement"]
            @test !any(part -> any(name -> name == "node_rotation", keys(part["blocks"])),
                index["variants"][1]["parts"])

            back = materialize_variant(path, id1)
            scale = maximum(abs, scene_f32(packet, "node_displacement")) / 32767
            @test scene_f32(back, "node_position") == scene_f32(packet, "node_position")
            @test scene_u32(back, "element_nodes") == UInt32[0, 1]
            @test scene_f32(back, "node_displacement") ≈ scene_f32(packet, "node_displacement") atol = scale / 2 + 1e-9
            @test_throws ErrorException scene_buffer(back, "node_rotation")

            neighbors = variant_neighbors(index, id1, "none")
            @test length(neighbors) == 1
            @test neighbors[1]["id"] == id2
            @test isempty(variant_neighbors(index, id1, "slab"))

            @test_throws ErrorException append_variant!(path, packet;
                geometry_hash = "building-b", params = DesignParameters(name = "other"))
            @test_throws ErrorException append_variant!(path, packet;
                geometry_hash = "building-a", params = DesignParameters())

            drop_variant!(path, id2)
            @test length(read_variant_index(path)["variants"]) == 1
            @test id2 != "" && (right["blocks"]["node_displacement"] in variant_stored_hashes(path))
            compact_variants!(path)
            stored = variant_stored_hashes(path)
            @test left["blocks"]["node_position"] in stored
            @test !(right["blocks"]["node_displacement"] in stored)
            @test length(read_variant_index(path)["variants"]) == 1
        finally
            isfile(path) && rm(path)
        end
    end

    @testset "a shell triangle cannot belong to two slabs" begin
        position = Float32[0, 0, 0, 1, 0, 0, 0, 1, 0]
        faces = UInt32[0, 1, 2]
        packet = ScenePacket(
            ["frame"], (0.0, 0.0, 0.0),
            Dict{String, Any}(
                "stations" => 0,
                "components" => [
                    Dict{String, Any}(
                        "id" => "slab:1", "kind" => "slab",
                        "bind" => Dict{String, Any}("elevation_m" => 0.0),
                        "drawing" => Dict{String, Any}()),
                    Dict{String, Any}(
                        "id" => "slab:2", "kind" => "slab",
                        "bind" => Dict{String, Any}("elevation_m" => 0.2),
                        "drawing" => Dict{String, Any}()),
                ],
            ),
            [
                StructuralSynthesizer.SceneBuffer("node_position", position),
                StructuralSynthesizer.SceneBuffer("shell_faces", faces),
                StructuralSynthesizer.SceneBuffer("shell_kind", UInt8[0]),
                StructuralSynthesizer.SceneBuffer("shell_thickness", Float32[0.2]),
            ],
        )
        path = tempname() * ".mgscene"
        @test_throws ErrorException append_variant!(path, packet;
            geometry_hash = "building-a", params = DesignParameters())
        @test !isfile(path)
    end

    @testset "two slabs at one elevation take the triangle nearest their plan" begin
        # Left triangle sits in the left bay; right triangle sits in the right bay.
        position = Float32[
            0.1, 0.1, 3, 0.4, 0.1, 3, 0.2, 0.4, 3,
            1.1, 0.1, 3, 1.6, 0.1, 3, 1.3, 0.4, 3,
        ]
        slab(idx, ring) = Dict{String, Any}(
            "id" => "slab:$(idx)", "kind" => "slab", "design_index" => idx,
            "bind" => Dict{String, Any}("elevation_m" => 3.0, "plan_m" => [ring]),
            "drawing" => Dict{String, Any}())
        left = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
        right = [[1.0, 0.0], [2.0, 0.0], [2.0, 1.0], [1.0, 1.0]]
        packet = ScenePacket(
            ["frame"], (0.0, 0.0, 0.0),
            Dict{String, Any}("stations" => 0, "components" => [slab(1, left), slab(2, right)]),
            [
                StructuralSynthesizer.SceneBuffer("node_position", position),
                StructuralSynthesizer.SceneBuffer("shell_faces", UInt32[0, 1, 2, 3, 4, 5]),
                StructuralSynthesizer.SceneBuffer("shell_kind", UInt8[0, 0]),
                StructuralSynthesizer.SceneBuffer("shell_thickness", Float32[0.2, 0.2]),
            ],
        )
        parts = StructuralSynthesizer._shell_parts(packet)
        @test [part["id"] for part in parts] == ["slab:1", "slab:2"]
    end

    @testset "a solid head does not own the slab shell" begin
        # The head is filed as a slab and has no elevation. The plate still owns
        # the triangle. A missing elevation on the head is not a scene error.
        position = Float32[
            0.1, 0.1, 3, 0.4, 0.1, 3, 0.2, 0.4, 3,
        ]
        ring = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
        packet = ScenePacket(
            ["frame"], (0.0, 0.0, 0.0),
            Dict{String, Any}("stations" => 0, "components" => [
                Dict{String, Any}(
                    "id" => "beam:4", "kind" => "slab", "title" => "Solid head 4",
                    "bind" => Dict{String, Any}("frame_elements" => [3]),
                    "drawing" => Dict{String, Any}("solid_head" => true)),
                Dict{String, Any}(
                    "id" => "slab:1", "kind" => "slab", "design_index" => 1,
                    "bind" => Dict{String, Any}("elevation_m" => 3.0, "plan_m" => [ring]),
                    "drawing" => Dict{String, Any}()),
            ]),
            [
                StructuralSynthesizer.SceneBuffer("node_position", position),
                StructuralSynthesizer.SceneBuffer("shell_faces", UInt32[0, 1, 2]),
                StructuralSynthesizer.SceneBuffer("shell_kind", UInt8[0]),
                StructuralSynthesizer.SceneBuffer("shell_thickness", Float32[0.127]),
            ],
        )
        parts = StructuralSynthesizer._shell_parts(packet)
        @test [part["id"] for part in parts] == ["slab:1"]
    end

    @testset "a wall triangle off its drawn line keeps its mesher owner" begin
        # Meshed on column centerlines 0.6 m off the drawn y = 0 line: farther
        # than the drawn-line fallback accepts.
        position = Float32[0, 0.6, 0, 2, 0.6, 0, 2, 0.6, 3, 0, 0.6, 3]
        wall_record(idx, x1, y1, x2, y2) = Dict{String, Any}(
            "id" => "wall:$(idx)", "kind" => "wall", "design_index" => idx,
            "bind" => Dict{String, Any}("shell_kinds" => [1], "z0_m" => 0.0, "z1_m" => 3.0),
            "drawing" => Dict{String, Any}("x1_m" => x1, "y1_m" => y1, "x2_m" => x2, "y2_m" => y2))
        packet(buffers) = ScenePacket(
            ["frame"], (0.0, 0.0, 0.0),
            Dict{String, Any}("stations" => 0,
                "components" => [wall_record(1, 0.0, 0.0, 2.0, 0.0), wall_record(2, 0.0, 0.0, 0.0, 2.0)]),
            vcat([
                StructuralSynthesizer.SceneBuffer("node_position", position),
                StructuralSynthesizer.SceneBuffer("shell_faces", UInt32[0, 1, 2, 0, 2, 3]),
                StructuralSynthesizer.SceneBuffer("shell_kind", UInt8[1, 1]),
                StructuralSynthesizer.SceneBuffer("shell_thickness", Float32[0.4, 0.4]),
            ], buffers),
        )
        owned = packet([StructuralSynthesizer.SceneBuffer("shell_wall", UInt32[1, 1])])
        parts = StructuralSynthesizer._shell_parts(owned)
        @test [part["id"] for part in parts] == ["wall:1"]
        @test parts[1]["blocks"]["shell_wall"] == UInt32[1, 1]
        @test_throws ErrorException StructuralSynthesizer._shell_parts(packet(StructuralSynthesizer.SceneBuffer[]))
        @test_throws ErrorException StructuralSynthesizer._shell_parts(
            packet([StructuralSynthesizer.SceneBuffer("shell_wall", UInt32[1, 3])]))
    end

    @testset "version 1 is not read as a variant file" begin
        path = tempname() * ".mgscene"
        try
            write_scene(path, build_scene(_variant_beam(); stages = (:frame,)))
            @test_throws ErrorException read_variant_index(path)
        finally
            rm(path)
        end
    end
end
