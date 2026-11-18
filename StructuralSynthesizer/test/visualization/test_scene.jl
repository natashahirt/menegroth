# Scene packets: binary round trip, fail-loud stage names, and deflected-shape
# parity with Asap.ElementDisplacements. The viewer shader copies `hermite_local`.

using Test
using Unitful
using LinearAlgebra
using JSON3
using StructuralSynthesizer
using Asap

"""A soft cantilever along +X with a uniform downward line load. Deflection is large enough to see.

`tip` must restrain any rotational DOF the element release disconnects, or the stiffness matrix is singular.
"""
function _cantilever(; release = :fixedfixed, tip = :free)
    E = 200e9u"Pa"
    G = 77e9u"Pa"
    ρ = 7850.0u"kg/m^3"
    sec = Asap.Section(4.0e-3u"m^2", E, G, 4.0e-5u"m^4", 1.2e-5u"m^4", 8.0e-7u"m^4", ρ)
    n1 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], :fixed)
    n2 = Asap.Node([4.0u"m", 0.0u"m", 0.0u"m"], tip)
    beam = Asap.Element(n1, n2, sec, :beam; release = release)
    load = Asap.LineLoad(beam, [0.0u"N/m", 0.0u"N/m", -5.0e3u"N/m"])
    return Asap.Model([n1, n2], Asap.Element[beam], Asap.AbstractLoad[load])
end

"""Every stored station matches Asap, including the member-load particular solution."""
function _assert_deflection_parity(model, packet; atol = 1e-4)
    stations = Int(packet.meta["stations"])
    for (e, elem) in enumerate(model.frame_elements)
        reference = Asap.ElementDisplacements(elem, model; resolution = stations)
        for s in 1:stations
            got = scene_station_displacement(packet, e, s)
            ref = reference.uglobal[:, s]
            @test isapprox(got[1], ref[1]; atol = atol)
            @test isapprox(got[2], ref[2]; atol = atol)
            @test isapprox(got[3], ref[3]; atol = atol)
        end
    end
end

@testset "scene packet" begin
    @testset "round trip and frame contents" begin
        model = _cantilever()
        packet = build_scene(model; stations = 9)
        @test packet.stages == ["frame", "loads", "solved"]
        @test length(scene_f32(packet, "node_position")) == 6
        @test scene_u32(packet, "element_nodes") == UInt32[0, 1]
        @test scene_u8(packet, "element_type") == UInt8[0] # beam, named :beam
        @test length(scene_u32(packet, "line_load_element")) == 1
        @test length(scene_u32(packet, "support_index")) == 1
        @test scene_u8(packet, "support_fixity")[1] == 0x3f # :fixed restrains all 6 DOFs

        io = IOBuffer()
        write_scene(io, packet)
        seekstart(io)
        loaded = read_scene(io)
        @test loaded.stages == packet.stages
        @test loaded.origin == packet.origin
        @test scene_f32(loaded, "node_position") == scene_f32(packet, "node_position")
        @test scene_f32(loaded, "element_local_dof") == scene_f32(packet, "element_local_dof")
        @test scene_f32(loaded, "load_particular") == scene_f32(packet, "load_particular")
        @test Int(loaded.meta["stations"]) == 9
        axial = scene_f32(packet, "element_axial")
        @test length(axial) == 1
        @test isfinite(axial[1])
        @test packet.meta["max_axial_n"] + 1e-4 >= abs(axial[1])

        # A file opened for reading cannot take the header padding. Eight
        # header lengths cover every remainder mod 8.
        for k in 0:7
            meta = copy(packet.meta)
            meta["pad"] = "x"^k
            path = tempname() * ".mgscene"
            try
                write_scene(path, ScenePacket(packet.stages, packet.origin, meta, packet.buffers))
                from_file = read_scene(path)
                @test from_file.meta["pad"] == "x"^k
                @test scene_f32(from_file, "node_position") == scene_f32(packet, "node_position")
            finally
                isfile(path) && rm(path)
            end
        end
    end

    @testset "deflected shape matches Asap" begin
        # Line load: particular solution is nonzero, so this fails if the shader
        # term is dropped or the Hermite sign convention drifts from `unodal`.
        loaded_beam = _cantilever()
        packet = build_scene(loaded_beam; stations = 9)
        # Joint displacements must be the solved ones. A zero vector means
        # process! allocated `u` and the solve was skipped.
        @test packet.meta["max_displacement"] > 1e-4
        _assert_deflection_parity(loaded_beam, packet)

        # Moment release at the tip. The tip rotations are supported so the
        # released DOFs are not free mechanisms; the DOF mask still zeros them.
        released = _cantilever(; release = :fixedfree, tip = [true, true, true, false, false, false])
        released_packet = build_scene(released; stations = 7)
        _assert_deflection_parity(released, released_packet)

        # Multi-member frame: beams carry line loads, columns and the brace do not.
        frame = demo_frame_model()
        frame_packet = build_scene(frame; stations = 5)
        _assert_deflection_parity(frame, frame_packet)
        types = scene_u8(frame_packet, "element_type")
        @test any(==(0x01), types) # column
        @test any(==(0x02), types) # brace
        @test count(==(0x00), types) > 0
    end

    @testset "fail loud" begin
        model = _cantilever()
        @test_throws ErrorException build_scene(model; stages = (:sized,))
        @test_throws ErrorException build_scene(model; stations = 1)

        n1 = Asap.Node([1.0u"m", 2.0u"m", 3.0u"m"], :fixed)
        n2 = Asap.Node([1.0u"m", 2.0u"m", 3.0u"m"], :free)
        sec = Asap.Section(4.0e-3u"m^2", 200e9u"Pa", 77e9u"Pa", 4.0e-5u"m^4", 1.2e-5u"m^4", 8.0e-7u"m^4", 7850.0u"kg/m^3")
        zero = Asap.Element(n1, n2, sec, :beam)
        bad = Asap.Model([n1, n2], Asap.Element[zero], Asap.AbstractLoad[])
        @test_throws ErrorException build_scene(bad; stages = (:frame,))

        @test_throws ErrorException read_scene(IOBuffer(UInt8[0x00, 0x01, 0x02, 0x03, 0x01, 0x00]))
    end

    @testset "frame stage does not require a solution" begin
        model = _cantilever()
        packet = build_scene(model; stages = (:frame, :loads))
        @test "solved" ∉ packet.stages
        # process! allocates u, but a loaded cantilever is not solved: u stays zero
        # and nodal displacements are never filled.
        @test all(iszero, model.u)
        @test !isassigned(first(model.nodes).displacement, 1)
        @test !any(b -> b.name == "element_local_dof", packet.buffers)
        @test !any(b -> b.name == "element_axial", packet.buffers)
    end

    @testset "shell triangles index the shared node table" begin
        m = u"m"
        E = 30e9u"Pa"
        sec = Asap.Section(0.09u"m^2", E, 12e9u"Pa", 6.75e-4u"m^4", 6.75e-4u"m^4", 1.1e-3u"m^4", 2400.0u"kg/m^3")
        base = Asap.Node([0.0m, 0.0m, 0.0m], :fixed)
        top = Asap.Node([0.0m, 0.0m, 3.0m], :free)
        b = Asap.Node([4.0m, 0.0m, 3.0m], :fixed)
        c = Asap.Node([0.0m, 4.0m, 3.0m], :fixed)
        column = Asap.Element(base, top, sec, :column)
        slab = Asap.ShellTri3((top, b, c), 0.2m, E, 0.2; id = :slab_1)
        wall = Asap.ShellTri3((base, b, top), 0.3m, E, 0.2; id = :wall)
        model = Asap.Model([base, top, b, c], Asap.Element[column], Asap.ShellElement[slab, wall], Asap.AbstractLoad[])
        Asap.process!(model)

        faces, kinds, thickness, stress, axial = StructuralSynthesizer._shell_faces(model)
        index = Dict(objectid(n) => i - 1 for (i, n) in enumerate(model.nodes))
        @test faces == UInt32[index[objectid(top)], index[objectid(b)], index[objectid(c)],
                              index[objectid(base)], index[objectid(b)], index[objectid(top)]]
        @test kinds == UInt8[StructuralSynthesizer.SHELL_KIND_SLAB, StructuralSynthesizer.SHELL_KIND_WALL]
        @test thickness == Float32[0.2, 0.3]
        @test isempty(stress)
        @test isempty(axial)
        @test StructuralSynthesizer._shell_kind(:drop_panel) == StructuralSynthesizer.SHELL_KIND_PATCH
        @test StructuralSynthesizer._shell_kind(:something) == StructuralSynthesizer.SHELL_KIND_OTHER
    end

    @testset "vertical membrane is the wall axial force" begin
        m = u"m"
        E = 30e9u"Pa"
        t = 0.2m
        base1 = Asap.Node([0.0m, 0.0m, 0.0m], :fixed)
        base2 = Asap.Node([1.0m, 0.0m, 0.0m], :fixed)
        top1 = Asap.Node([0.0m, 0.0m, 1.0m], :free)
        top2 = Asap.Node([1.0m, 0.0m, 1.0m], :free)
        wall = Asap.ShellTri3((base1, base2, top2), t, E, 0.2; id = :wall)
        other = Asap.ShellTri3((base1, top2, top1), t, E, 0.2; id = :wall)
        model = Asap.Model([base1, base2, top1, top2], Asap.Element[], Asap.ShellElement[wall, other], Asap.AbstractLoad[])
        Asap.solve!(model, Asap.AbstractLoad[
            Asap.NodeForce(top1, [0.0, 0.0, -1.0e3] .* u"N"),
            Asap.NodeForce(top2, [0.0, 0.0, -1.0e3] .* u"N"),
        ])
        _, _, _, _, axial = StructuralSynthesizer._shell_faces(model)
        @test length(axial) == 2
        for (elem, stored) in zip((wall, other), axial)
            sif = Asap.ShellInternalForces(elem, model.u)
            expect = StructuralSynthesizer._shell_vertical_force(elem, sif)
            @test stored ≈ Float32(expect)
            @test expect < 0
        end

        # A floor's in-plane axes are horizontal, so the vertical component is zero.
        # The 1 kN load runs parallel to edge a–b, so this right triangle carries
        # it as shear Nxy. Nxx and Nyy stay zero.
        a = Asap.Node([0.0m, 0.0m, 3.0m], :fixed)
        b = Asap.Node([2.0m, 0.0m, 3.0m], :fixed)
        c = Asap.Node([0.0m, 2.0m, 3.0m], [true, true, false, false, false, false])
        slab = Asap.ShellTri3((a, b, c), t, E, 0.2; id = :slab_1)
        floor = Asap.Model([a, b, c], Asap.Element[], Asap.ShellElement[slab], Asap.AbstractLoad[])
        Asap.solve!(floor, Asap.AbstractLoad[Asap.NodeForce(c, [1.0e3, 0.0, 0.0] .* u"N")])
        _, _, _, _, floor_axial = StructuralSynthesizer._shell_faces(floor)
        @test length(floor_axial) == 1
        @test abs(floor_axial[1]) < 1.0
        floor_force = Asap.ShellInternalForces(slab, floor.u)
        @test hypot(floor_force.Nxx, floor_force.Nyy, floor_force.Nxy) > 1.0
    end

    @testset "slab embeds wall nodes inside its outline or on its edge" begin
        m = u"m"
        corners = [Asap.Node([x * m, y * m, 3.0m], :free) for (x, y) in ((0, 0), (8, 0), (8, 8), (0, 8))]
        inside = Asap.Node([4.0m, 4.0m, 3.0m], :free)
        on_edge = Asap.Node([4.0m, 0.0m, 3.0m], :free)
        other_floor = Asap.Node([4.0m, 2.0m, 6.6m], :free)
        outside = Asap.Node([9.0m, 4.0m, 3.0m], :free)
        already = Asap.Node([2.0m, 2.0m, 3.0m], :free)
        picked = StructuralSynthesizer._slab_wall_nodes(
            [inside, on_edge, other_floor, outside, already, corners[1]], [already], corners)
        @test picked == [inside, on_edge]
    end

    @testset "component dossier keeps the solve and drops unverified ratios" begin
        cr = ColumnDesignResult(;
            section_size = "400x400",
            c1 = 0.4u"m", c2 = 0.4u"m", height = 3.6u"m",
            Ag = 0.16u"m^2", As_total = 0.0016u"m^2", rho_g = 0.01,
            Pu = 800.0u"kN", Mu_x = 40.0u"kN*m", Mu_y = 10.0u"kN*m",
            axial_ratio = 0.35, interaction_ratio = 0.72, ok = true,
        )
        ev = StructuralSizer.TraceEvent(
            1.5, :sizing, "size_columns", "column_4", :decision,
            Dict{String, Any}("path" => "discrete_mip"),
        )
        record = StructuralSynthesizer._column_record(4, cr, (story = 2,), [7, 8], StructuralSizer.TraceEvent[ev])
        @test record["kind"] == "column"
        @test record["story"] == 2
        @test record["bind"]["frame_elements"] == [7, 8]
        @test record["drawing"]["c1_m"] ≈ 0.4
        @test record["drawing"]["rho_g"] ≈ 0.01
        @test record["governing"]["check"] == "pm_interaction"
        @test record["governing"]["ratio"] ≈ 0.72
        @test record["path"][1]["element_id"] == "column_4"
        @test record["path"][1]["data"]["path"] == "discrete_mip"
        loaded = JSON3.read(JSON3.write(record))
        @test loaded.checks[1].demand_unit == "kN"

        unverified = ColumnDesignResult(; axial_ratio = NaN, interaction_ratio = NaN, ok = false)
        blank = StructuralSynthesizer._column_record(1, unverified, (story = 0,), Int[], StructuralSizer.TraceEvent[])
        @test blank["governing"]["check"] == "axial_compression_unverified"
        @test blank["governing"]["ratio"] === nothing
        @test blank["checks"][1]["ratio"] === nothing

        # The sizer's check is the record when Chapter E could not run.
        sized = ColumnDesignResult(;
            axial_ratio = NaN, interaction_ratio = 0.55, ok = true,
            governing_check = "pm_interaction_compression",
            governing_ratio = 0.55, governing_clause = "AISC 360-16 H1",
        )
        sized_record = StructuralSynthesizer._column_record(
            2, sized, (story = 1,), Int[], StructuralSizer.TraceEvent[])
        @test sized_record["governing"]["check"] == "pm_interaction_compression"
        @test sized_record["governing"]["ratio"] ≈ 0.55
        @test sized_record["governing"]["clause"] == "AISC 360-16 H1"

        beam = BeamDesignResult(;
            section_size = "W16X26", Mu = 194.0u"kN*m", Vu = 142.0u"kN",
            flexure_ratio = 0.88, shear_ratio = 0.29, ok = true,
            governing_check = "deflection_total", governing_ratio = 0.41,
            governing_clause = "AISC 360-16 L",
            governing_demand = 1 / 400, governing_capacity = 1 / 240,
        )
        beam_record = StructuralSynthesizer._beam_record(
            4, beam, Int[], StructuralSizer.TraceEvent[])
        @test beam_record["governing"]["check"] == "deflection_total"
        @test beam_record["governing"]["ratio"] ≈ 0.41
        @test beam_record["governing"]["clause"] == "AISC 360-16 L"
        @test beam_record["checks"][1]["governing"] == false
        @test beam_record["checks"][2]["governing"] == false
        defl = beam_record["checks"][3]
        @test defl["name"] == "deflection_total"
        @test defl["governing"] == true
        @test defl["demand_unit"] == "δ/L"

        long = StructuralSynthesizer._jsonify(collect(1:100))
        @test long["truncated"] == true
        @test long["length"] == 100
        @test length(long["head"]) == 8
    end

    @testset "solids export as an OBJ" begin
        buffers = StructuralSynthesizer.SceneBuffer[]
        push!(buffers, StructuralSynthesizer.SceneBuffer("node_position", Float32[0, 0, 0, 2, 0, 0, 0, 2, 0]))
        push!(buffers, StructuralSynthesizer.SceneBuffer("shell_faces", UInt32[0, 1, 2]))
        push!(buffers, StructuralSynthesizer.SceneBuffer("shell_kind", UInt8[0]))
        push!(buffers, StructuralSynthesizer.SceneBuffer("shell_thickness", Float32[2]))
        push!(buffers, StructuralSynthesizer.SceneBuffer("member_solid_position", Float32[1, 2, 3]))
        push!(buffers, StructuralSynthesizer.SceneBuffer("member_solid_faces", UInt32[0, 0, 0]))
        push!(buffers, StructuralSynthesizer.SceneBuffer("footing_center", Float32[1, 2, 3]))
        push!(buffers, StructuralSynthesizer.SceneBuffer("footing_size", Float32[2, 4, 6]))
        packet = ScenePacket(String["frame"], (10.0, 20.0, 30.0), Dict{String, Any}(), buffers)
        meshes = StructuralSynthesizer.scene_meshes(packet)
        @test [m.name for m in meshes] == ["columns", "slabs", "footings"]

        slab = meshes[2]
        @test length(slab.faces) ÷ 3 == 8
        zs = Float64[]
        for i in 3:3:length(slab.positions)
            push!(zs, slab.positions[i])
        end
        @test minimum(zs) ≈ 29
        @test maximum(zs) ≈ 31

        footing = meshes[3]
        xs = Float64[footing.positions[i] for i in 1:3:length(footing.positions)]
        @test minimum(xs) ≈ 10
        @test maximum(xs) ≈ 12
        @test length(footing.faces) ÷ 3 == 12

        path = joinpath(mktempdir(), "solids.obj")
        StructuralSynthesizer.write_scene_obj(path, packet)
        text = read(path, String)
        @test occursin("o columns", text)
        @test occursin("o slabs", text)
        @test occursin("o footings", text)
        @test !occursin("o walls", text)
    end

    @testset "a tributary ribbon is the assigned width along the centerline" begin
        # Full width 2 m on a 4 m beam is a 4 m by 2 m rectangle, area 8 m².
        loops = StructuralSynthesizer._tributary_ribbons(
            [(0.0, 0.0), (4.0, 0.0)], [0.0, 1.0], [2.0, 2.0])
        @test length(loops) == 1
        ring = only(loops)
        area = 0.0
        for i in eachindex(ring)
            a = ring[i]
            b = ring[mod1(i + 1, length(ring))]
            area += a[1] * b[2] - b[1] * a[2]
        end
        @test abs(area) / 2 ≈ 8.0
        # A corner is two runs. Neither fold crosses the kink.
        kinked = StructuralSynthesizer._tributary_ribbons(
            [(0.0, 0.0), (4.0, 0.0), (4.0, 3.0)], [0.0, 1.0], [2.0, 2.0])
        @test length(kinked) == 2
    end

    @testset "a beam outline sits on the edge that owns it" begin
        trib = Asap.TributaryPolygon(1, [0.0, 1.0, 0.5], [0.0, 0.0, 2.0], 2.0, 1.0)
        xy = Asap.vertices(trib, (0.0, 0.0), (4.0, 0.0))
        pos = Float32[]
        counts = UInt32[]
        @test StructuralSynthesizer._push_plan!(pos, counts, xy, 3.6, (1.0, 2.0, 0.5))
        @test counts == UInt32[3]
        @test pos[1] ≈ Float32(-1)
        @test pos[2] ≈ Float32(-2)
        @test pos[3] ≈ Float32(3.1)
        @test pos[7] ≈ Float32(1)   # x = 2 − 1, halfway along the 4 m edge
        @test pos[8] ≈ Float32(0)   # y = 2 − 2, the left normal of +X
    end

    @testset "beam bars and the column tie are the section's own" begin
        beam = StructuralSizer.RCBeamSection(b = 12u"inch", h = 20u"inch", bar_size = 9, n_bars = 3)
        bars = StructuralSizer.section_rebar_bars(beam)
        tr = StructuralSizer.section_transverse(beam)
        @test length(bars) == 3
        @test all(bar -> bar[3] ≈ 2 * StructuralSizer.section_rebar_radius(beam), bars)
        cover = ustrip(u"m", beam.cover)
        h = ustrip(u"m", beam.h)
        b = ustrip(u"m", beam.b)
        db, dst = bars[1][3], tr.diameter
        @test bars[1][2] ≈ -h / 2 + cover + dst + db / 2
        @test bars[1][1] ≈ -(b / 2 - cover - dst - db / 2)
        @test bars[3][1] ≈ -bars[1][1]
        @test tr.kind == :stirrup
        @test tr.bar_size == 3
        @test tr.loop[1][1] ≈ -b / 2 + cover + dst / 2

        both = StructuralSizer.RCBeamSection(b = 12u"inch", h = 20u"inch",
            bar_size = 9, n_bars = 3, bar_size_prime = 6, n_bars_prime = 2)
        @test length(StructuralSizer.section_rebar_bars(both)) == 5

        col = StructuralSizer.RCColumnSection(b = 16u"inch", h = 16u"inch", bar_size = 8, n_bars = 4)
        ties = StructuralSizer.section_transverse(col)
        drawn = StructuralSynthesizer._rebar_drawing(col)
        @test ties.kind == :tie
        @test ties.bar_size == 4
        @test length(drawn) == 4
        @test length(drawn[1]) == 3
        @test StructuralSynthesizer._transverse_drawing(col)["loop_m"] isa Vector
    end

    @testset "a solid slab carries no deck and a concentric member stays on its nodes" begin
        model = _cantilever()
        packet = build_scene(model; stages = (:frame,))
        ecc = scene_f32(packet, "element_eccentricity")
        @test length(ecc) == 4
        @test all(iszero, ecc)

        prof = StructuralSizer.composite_deck_profile("2VLI")
        deck = StructuralSizer.CompositeDeckResult(
            "2VLI", prof.hr, 20, 0.0762u"m", prof.hr + 0.0762u"m",
            0.001u"m", 0.1u"m", 3.0u"kPa", (ok = true,))
        drawn = StructuralSynthesizer._deck_drawing(deck, (0.0, 1.0))
        @test drawn["profile"] == "2VLI"
        @test drawn["hr_m"] ≈ ustrip(u"m", prof.hr)
        @test drawn["rib_top_m"] ≈ ustrip(u"m", prof.rib_top)
        @test drawn["rib_bottom_m"] ≈ ustrip(u"m", prof.rib_bottom)
        @test drawn["pitch_m"] ≈ ustrip(u"m", prof.pitch)
        @test drawn["fill_m"] ≈ 0.0762
        @test drawn["sheet_m"] ≈ ustrip(u"m", prof.gages[20].t)
        @test drawn["direction"] == [0.0, 1.0]
        solid = StructuralSizer.CIPSlabResult(0.2u"m", 0.2u"m", 4.0u"kPa")
        @test StructuralSynthesizer._deck_drawing(solid, (1.0, 0.0)) === nothing
        @test StructuralSynthesizer._deck_drawing(deck, (0.0, 0.0))["direction"] === nothing

        spaced = StructuralSynthesizer._rib_spacing([
            (0.0, 0.0, 4.0, 0.0), (0.0, 1.5, 4.0, 1.5), (0.0, 3.0, 4.0, 3.0)])
        @test spaced ≈ 1.5
        @test StructuralSynthesizer._rib_spacing([
            (0.0, 0.0, 4.0, 0.0), (0.0, 0.0, 0.0, 4.0)]) === nothing
        @test StructuralSynthesizer._rib_spacing([(0.0, 0.0, 4.0, 0.0)]) === nothing

        sec = model.frame_elements[1].section
        n1 = Asap.Node([0.0u"m", 0.0u"m", 3.0u"m"], :free)
        n2 = Asap.Node([4.0u"m", 0.0u"m", 3.0u"m"], :free)
        elem = Asap.Element(n1, n2, sec, :beam; eccentricity = (0.0u"m", 0.1u"m", -0.25u"m", 0.0u"m"))
        elem.LCS[1] = [1.0, 0.0, 0.0]
        elem.LCS[2] = [0.0, 0.0, 1.0]
        elem.LCS[3] = [0.0, -1.0, 0.0]
        p1, p2 = StructuralSynthesizer._eccentric_ends(elem, (0.0, 0.0, 0.0))
        @test p1[3] ≈ 2.75
        @test p2[1] ≈ 4.1
        @test p2[3] ≈ 2.75
        elem.LCS[1] = [0.0, 0.0, 0.0]
        @test_throws ErrorException StructuralSynthesizer._eccentric_ends(elem, (0.0, 0.0, 0.0))
    end

    @testset "a footing support is that analysis node" begin
        model = _cantilever()
        @test StructuralSynthesizer._checked_support_node(model, 1, (0.0, 0.0, 0.0)) === UInt32(0)
        @test StructuralSynthesizer._checked_support_node(model, 2, (4.0, 0.0, 0.0)) === UInt32(1)
        @test_throws ErrorException StructuralSynthesizer._checked_support_node(model, 1, (1.0, 0.0, 0.0))
        @test_throws ErrorException StructuralSynthesizer._checked_support_node(model, 9, (0.0, 0.0, 0.0))
    end
end

@testset "A mat keeps its plan axes and its walls" begin
    sx, sy = StructuralSynthesizer._footing_plan_xy(:mat, 9.0, 6.0, [0.0, 8.0], [0.0, 8.0])
    @test sx ≈ 6.0
    @test sy ≈ 9.0
    sx, sy = StructuralSynthesizer._footing_plan_xy(:spread, 2.8, 1.9, [0.0], [0.0])
    @test sx ≈ 2.8
    @test sy ≈ 1.9
    sx, sy = StructuralSynthesizer._footing_plan_xy(:wall_strip, 10.0, 1.2, [0.0, 0.0], [0.0, 8.0])
    @test sx ≈ 1.2
    @test sy ≈ 10.0
    @test StructuralSynthesizer._footing_kind(:mat) === 0x03
    @test StructuralSynthesizer._footing_kind(:wall_strip) === 0x04
    @test_throws ErrorException StructuralSynthesizer._footing_kind(:pile)

    straight = [(0.0, 0.0, 8.0, 0.0), (8.0, 0.0, 16.0, 0.0)]
    corner = [(0.0, 0.0, 8.0, 0.0), (0.0, 0.0, 0.0, 6.0)]
    @test StructuralSynthesizer._legs_colinear(straight)
    @test !StructuralSynthesizer._legs_colinear(corner)
    xmin, xmax, ymin, ymax = StructuralSynthesizer._leg_extent(corner, 0.5)
    @test xmin ≈ -0.5
    @test xmax ≈ 8.0
    @test ymin ≈ -0.5
    @test ymax ≈ 6.0

    L = typeof(1.0u"m")
    A = typeof(1.0u"m^2")
    V = typeof(1.0u"m^3")
    F = typeof(1.0u"N")
    result = StructuralSizer.MatFootingResult{L, A, V, F}(
        6.0u"m", 9.0u"m", 0.61u"m", 0.50u"m",
        0.012u"m^2", 0.002u"m^2", 0.011u"m^2", 0.001u"m^2",
        0, 12.0u"m^3", 0.2u"m^3", 0.583, :rigid)
    fdn = Foundation([1], result; foundation_type = :mat, wall_indices = [1])
    wall = Wall(1, 3.6u"m"; thickness = 0.30u"m",
                x1 = 8.0, y1 = 8.0, x2 = 16.0, y2 = 8.0, story = 0,
                openings = [WallOpening(3.1, 0.0, 1.8, 2.1, :door)])
    fr = FoundationDesignResult(; length = 9.0u"m", width = 6.0u"m", depth = 0.61u"m",
                                bearing_ratio = 0.2, punching_ratio = 0.9, ok = true)
    record = StructuralSynthesizer._footing_record(
        1, fr, 0, Int[4], StructuralSizer.TraceEvent[], fdn, [wall])
    @test record["title"] == "Mat 1"
    @test record["governing"]["check"] == "utilization"
    @test record["governing"]["ratio"] ≈ 0.583
    drawing = record["drawing"]
    @test drawing["foundation_type"] == "mat"
    @test drawing["analysis"] == "rigid"
    @test drawing["n_columns"] == 0
    @test drawing["reinforcement"]["As_x_bot_m2"] ≈ 0.012
    @test drawing["walls"][1]["openings"][1]["kind"] == "door"
    @test drawing["note"] === nothing

    elbow = Foundation([1], result; foundation_type = :wall_strip, wall_indices = [1, 2])
    other = Wall(1, 3.6u"m"; thickness = 0.30u"m",
                 x1 = 8.0, y1 = 8.0, x2 = 8.0, y2 = 16.0, story = 0)
    turned = StructuralSynthesizer._footing_record(
        2, fr, 1, Int[4], StructuralSizer.TraceEvent[], elbow, [wall, other])
    @test turned["title"] == "Wall strip 2"
    @test occursin("legs", turned["drawing"]["note"])
end

@testset "an edge T-beam draws its flange on the slab side" begin
    sec = StructuralSizer.RCTBeamSection(bw = 10u"inch", h = 16u"inch", bf = 20u"inch",
                                         hf = 5u"inch", bar_size = 8, n_bars = 3)
    rect = StructuralSizer.RCTBeamSection(bw = 10u"inch", h = 16u"inch", bf = 10u"inch",
                                          hf = 5u"inch", bar_size = 8, n_bars = 3)
    bw = ustrip(u"m", sec.bw)
    bf = ustrip(u"m", sec.bf)
    centered = StructuralSynthesizer._edge_flange_outline(sec, 0)
    stored = [[Float64(y), Float64(z)] for (y, z) in StructuralSizer.section_polygon(sec)]
    @test centered == stored
    shelf = StructuralSynthesizer._edge_flange_outline(sec, +1)
    ys = [p[1] for p in shelf]
    @test minimum(ys) ≈ -bw / 2 atol = 1e-9
    @test maximum(ys) ≈ -bw / 2 + bf atol = 1e-9
    @test all(p -> p[1] ≈ -bw / 2 || p[1] ≈ bw / 2 || p[1] ≈ -bw / 2 + bf, shelf)
    other = StructuralSynthesizer._edge_flange_outline(sec, -1)
    oys = [p[1] for p in other]
    @test maximum(oys) ≈ bw / 2 atol = 1e-9
    @test minimum(oys) ≈ bw / 2 - bf atol = 1e-9
    # The stem and the top and bottom fibres stay in the centroid frame.
    @test extrema(p[2] for p in shelf) == extrema(p[2] for p in stored)
    @test StructuralSynthesizer._edge_flange_outline(rect, +1) ==
          StructuralSynthesizer._edge_flange_outline(rect, 0)

    slab = NTuple{2, Float64}[(0.0, 0.0), (10.0, 0.0), (10.0, 6.0), (0.0, 6.0)]
    origin = (0.0, 0.0, 0.0)
    east = StructuralSynthesizer._flange_draw_side([10.0, 1.0, 0.0], [10.0, 2.0, 0.0],
                                                   0.0, sec, [slab], origin)
    west = StructuralSynthesizer._flange_draw_side([0.0, 1.0, 0.0], [0.0, 2.0, 0.0],
                                                   0.0, sec, [slab], origin)
    interior = StructuralSynthesizer._flange_draw_side([5.0, 1.0, 0.0], [5.0, 2.0, 0.0],
                                                       0.0, sec, [slab], origin)
    square = StructuralSynthesizer._flange_draw_side([10.0, 1.0, 0.0], [10.0, 2.0, 0.0],
                                                     0.0, rect, [slab], origin)
    @test east == 1
    @test west == -1
    @test interior == 0
    @test square == 0

    # East edge, heading +Y: local +y points into the slab, so the shelf stays inside x = 10
    # and the outside face stops at the stem.
    poly = StructuralSynthesizer._edge_flange_outline(sec, east)
    verts, _ = StructuralSynthesizer._build_frame_element_mesh(
        poly, [10.0, 1.0, 0.0], [10.0, 2.0, 0.0], 0.0)
    xs = [v[1] for v in verts]
    @test maximum(xs) ≈ 10 + bw / 2 atol = 1e-8
    @test minimum(xs) ≈ 10 + bw / 2 - bf atol = 1e-8
end

@testset "a rib stem meets the soffit and the flange stays the slab" begin
    m = u"m"
    E = 30e9u"Pa"
    sec = StructuralSizer.RCTBeamSection(bw = 0.25u"m", h = 0.40u"m", bf = 1.20u"m",
                                         hf = 0.10u"m", bar_size = 5, n_bars = 2)
    frame = Asap.Section(0.09u"m^2", E, 12e9u"Pa", 6.75e-4u"m^4", 6.75e-4u"m^4", 1.1e-3u"m^4", 2400.0u"kg/m^3")
    n1 = Asap.Node([0.0m, 1.0m, 3.0m], :free)
    n2 = Asap.Node([4.0m, 1.0m, 3.0m], :free)
    n3 = Asap.Node([0.0m, 5.0m, 3.0m], :free)
    beam = Asap.Element(n1, n2, frame, :rib)
    slab = Asap.ShellTri3((n1, n2, n3), 0.10m, E, 0.2; id = :slab_1)
    model = Asap.Model([n1, n2, n3], Asap.Element[beam], Asap.ShellElement[slab], Asap.AbstractLoad[])
    p1 = [0.0, 1.0, 3.0]
    p2 = [4.0, 1.0, 3.0]
    drawn = StructuralSynthesizer._rib_stem_below_slab(sec, beam, p1, p2, 0.0, model, (0.0, 0.0, 0.0))
    @test drawn !== nothing
    poly, q1, q2 = drawn
    stem = 0.30
    @test maximum(abs(p[1]) for p in poly) ≈ 0.25 / 2 atol = 1e-9
    @test maximum(abs(p[2]) for p in poly) ≈ stem / 2 atol = 1e-9
    # Half the 0.10 m slab plus half the 0.30 m stem. The top fiber is the soffit.
    @test q1[3] ≈ 3.0 - (0.10 / 2 + stem / 2) atol = 1e-9
    @test q2[3] ≈ q1[3]
    @test q1[3] + stem / 2 ≈ 3.0 - 0.10 / 2 atol = 1e-9

    beam.eccentricity = (0.0, 0.0, -0.20, 0.0)
    seated = StructuralSynthesizer._rib_stem_below_slab(sec, beam, p1, p2, 0.0, model, (0.0, 0.0, 0.0))
    @test seated[2] == p1
    @test seated[3] == p2

    bare = Asap.Model([n1, n2], Asap.Element[beam], Asap.ShellElement[], Asap.AbstractLoad[])
    beam.eccentricity = (0.0, 0.0, 0.0, 0.0)
    @test StructuralSynthesizer._rib_stem_below_slab(sec, beam, p1, p2, 0.0, bare, (0.0, 0.0, 0.0)) === nothing

    base = Asap.Node([0.0m, 1.0m, 0.0m], :fixed)
    wall = Asap.ShellTri3((base, n2, n1), 0.20m, E, 0.2; id = :wall)
    walls = Asap.Model([base, n1, n2], Asap.Element[beam], Asap.ShellElement[wall], Asap.AbstractLoad[])
    @test StructuralSynthesizer._shell_thickness_near(walls, p1, p2, (0.0, 0.0, 0.0)) === nothing
end
