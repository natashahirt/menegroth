# A story is one shell. Neighbouring panels share the nodes on their common
# edge, and each triangle keeps the thickness of its own panel. A concrete
# web hangs below the soffit by the centroid of the piece that is actually
# in the frame.

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "Section centroid and story shell" begin
    @testset "A symmetric section carries its centroid at mid-depth" begin
        rect = RCBeamSection(b = 12u"inch", h = 20u"inch", bar_size = 9, n_bars = 3)
        @test centroid_from_top(rect) == rect.h / 2
        @test soffit_to_centroid(rect) == rect.h / 2
        steel = ISymmSection(10u"inch", 6u"inch", 0.3u"inch", 0.4u"inch")
        @test centroid_from_top(steel) == steel.d / 2
    end

    @testset "A T-beam centroid is not mid-depth, and the stem hangs from the soffit" begin
        tbeam = RCTBeamSection(
            bw = 12u"inch", h = 24u"inch", bf = 48u"inch", hf = 5u"inch",
            bar_size = 9, n_bars = 3)
        @test centroid_from_top(tbeam) == gross_centroid_from_top(tbeam)
        @test centroid_from_top(tbeam) != tbeam.h / 2
        @test soffit_to_centroid(tbeam) == (tbeam.h - tbeam.hf) / 2

        props = SS.shell_beam_properties(tbeam, tbeam.hf, NWC_4000)
        y = ustrip(u"m", tbeam.hf / 2 + soffit_to_centroid(tbeam))
        @test props.eccentricity[3] ≈ -y
        @test props.eccentricity[1] == 0.0
        @test props.eccentricity[2] == 0.0
        @test props.eccentricity[4] == 0.0
        # The frame is the stem. Its area is the stem, not the full T.
        stem = ustrip(u"m^2", tbeam.bw * (tbeam.h - tbeam.hf))
        @test ustrip(u"m^2", props.section.A) ≈ stem
    end

    @testset "Steel stays on the shell nodes with its bare section" begin
        steel = ISymmSection(10u"inch", 8u"inch", 0.3u"inch", 0.5u"inch"; material = A992_Steel)
        bare = SS.shell_beam_properties(steel, 0.2u"m", A992_Steel)
        @test bare.eccentricity == (0.0, 0.0, 0.0, 0.0)
        @test ustrip(u"m^4", bare.section.Ix) ≈ ustrip(u"m^4", steel.Ix)
    end

    @testset "Two panels share the edge nodes and keep their own thickness" begin
        E = 30e9
        ν = 0.2
        left = SS.StoryShellPanel(
            [(0.0, 0.0), (4.0, 0.0), (4.0, 1.0), (0.0, 1.0)],
            Asap.ShellSection(0.20u"m", E * u"Pa", ν; ρ = 2400u"kg/m^3"))
        right = SS.StoryShellPanel(
            [(4.0, 0.0), (8.0, 0.0), (8.0, 1.0), (4.0, 1.0)],
            Asap.ShellSection(0.30u"m", E * u"Pa", ν; ρ = 2400u"kg/m^3"))
        web = Asap.Section(0.15u"m^2", E * u"Pa", 0.4E * u"Pa",
                           3.0e-3u"m^4", 1.0e-3u"m^4", 1.0e-3u"m^4", 2400u"kg/m^3")
        ecc = SS.web_below_slab_eccentricity(0.30u"m", 0.50u"m")
        beam = SS.ShellFrameBeam([(4.0, 0.0), (4.0, 1.0)], web; eccentricity = ecc, id = :girder)
        built = SS.story_shell([left, right], [beam]; target_edge = 0.5u"m")

        @test length(built.boundary) == 4
        left_shells = built.shells[built.panel_index .== 1]
        right_shells = built.shells[built.panel_index .== 2]
        @test !isempty(left_shells) && !isempty(right_shells)
        @test all(el -> el.thickness ≈ 0.20, left_shells)
        @test all(el -> el.thickness ≈ 0.30, right_shells)

        function _uses(shells, node)
            any(el -> any(n -> n === node, el.nodes), shells)
        end
        shared = Asap.Node[]
        for n in built.nodes
            abs(ustrip(u"m", n.position[1]) - 4.0) > 1e-6 && continue
            _uses(left_shells, n) && _uses(right_shells, n) && push!(shared, n)
        end
        @test length(shared) >= 2
        @test !isempty(built.frames)
        @test all(el -> el.id === :girder, built.frames)
        # This girder runs +Y, so local y is up and the physical offset is unchanged.
        @test all(el -> abs(el.eccentricity[3] - ecc[3]) < 1e-12, built.frames)
        for el in built.frames
            @test ustrip(u"m", el.nodeStart.position[1]) ≈ 4.0 atol = 1e-6
            @test any(n -> n === el.nodeStart, shared)
        end
    end

    @testset "A web below the slab stays below when the beam runs west" begin
        E = 30e9
        ν = 0.2
        panel = SS.StoryShellPanel(
            [(0.0, 0.0), (4.0, 0.0), (4.0, 1.0), (0.0, 1.0)],
            Asap.ShellSection(0.20u"m", E * u"Pa", ν; ρ = 2400u"kg/m^3"))
        web = Asap.Section(0.15u"m^2", E * u"Pa", 0.4E * u"Pa",
                           3.0e-3u"m^4", 1.0e-3u"m^4", 1.0e-3u"m^4", 2400u"kg/m^3")
        ecc = SS.web_below_slab_eccentricity(0.20u"m", 0.40u"m")
        @test ecc[3] < 0
        east = SS.ShellFrameBeam([(0.0, 0.5), (4.0, 0.5)], web; eccentricity = ecc, id = :east)
        west = SS.ShellFrameBeam([(4.0, 0.25), (0.0, 0.25)], web; eccentricity = ecc, id = :west)
        built = SS.story_shell([panel], [east, west]; target_edge = 1.0u"m")
        east_frames = [el for el in built.frames if el.id === :east]
        west_frames = [el for el in built.frames if el.id === :west]
        @test !isempty(east_frames) && !isempty(west_frames)
        # +X: local y is up, so the downward offset stays negative.
        @test all(el -> ustrip(u"m", el.nodeEnd.position[1]) >
                        ustrip(u"m", el.nodeStart.position[1]), east_frames)
        @test all(el -> el.eccentricity[3] ≈ ecc[3], east_frames)
        # −X: local y points down, so the same downward offset is positive local y.
        @test all(el -> ustrip(u"m", el.nodeStart.position[1]) >
                        ustrip(u"m", el.nodeEnd.position[1]), west_frames)
        @test all(el -> el.eccentricity[3] ≈ -ecc[3], west_frames)
    end

    @testset "A section can change from one piece of a beam to the next" begin
        E = 30e9
        ν = 0.2
        panel = SS.StoryShellPanel(
            [(0.0, 0.0), (4.0, 0.0), (4.0, 1.0), (0.0, 1.0)],
            Asap.ShellSection(0.20u"m", E * u"Pa", ν))
        base = Asap.Section(0.1u"m^2", E * u"Pa", 0.4E * u"Pa",
                            1.0e-4u"m^4", 1.0e-4u"m^4", 1.0e-4u"m^4")
        beam = SS.ShellFrameBeam([(0.0, 0.5), (4.0, 0.5)], base; id = :taper)
        function section_at(b, station)
            Ix = (1.0e-4 + station) * u"m^4"
            return SS.section_with_strong_inertia(b.section, Ix)
        end
        built = SS.story_shell([panel], [beam]; target_edge = 1.0u"m", section_at = section_at)
        @test length(built.frames) >= 2
        ixs = [ustrip(u"m^4", el.section.Ix) for el in built.frames]
        @test length(unique(round.(ixs, digits = 6))) >= 2
    end

    @testset "Beams meeting the outline leave no zero-area triangle" begin
        # 54 ft × 42 ft in three bays each way, beams on every column line. Before
        # line points on the outline were boundary vertices, this mesh held 20
        # zero-area triangles, and Cholesky failed on the story model.
        xs = [0.0, 5.49, 10.97, 16.46]
        ys = [0.0, 4.27, 8.54, 12.81]
        sec = Asap.ShellSection(0.15u"m", 30e9u"Pa", 0.2; ρ = 2400u"kg/m^3")
        panels = vec([SS.StoryShellPanel([(xs[i], ys[j]), (xs[i + 1], ys[j]),
                                          (xs[i + 1], ys[j + 1]), (xs[i], ys[j + 1])], sec)
                      for i in 1:3, j in 1:3])
        steel = Asap.Section(6.6e-3u"m^2", 2.0e11u"Pa", 7.7e10u"Pa", 5.3e-5u"m^4",
                             1.8e-5u"m^4", 1e-6u"m^4")
        beams = SS.ShellFrameBeam[]
        for y in ys, i in 1:3
            push!(beams, SS.ShellFrameBeam([(xs[i], y), (xs[i + 1], y)], steel;
                                           id = Symbol("x$(i)_$(y)"), release = :freefree))
        end
        for x in xs, j in 1:3
            push!(beams, SS.ShellFrameBeam([(x, ys[j]), (x, ys[j + 1])], steel;
                                           id = Symbol("y$(j)_$(x)"), release = :freefree))
        end
        built = SS.story_shell(panels, beams; target_edge = 0.5u"m")
        twice_area(el) = begin
            p = [(ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])) for n in el.nodes]
            abs((p[2][1] - p[1][1]) * (p[3][2] - p[1][2]) - (p[2][2] - p[1][2]) * (p[3][1] - p[1][1]))
        end
        @test minimum(twice_area, built.shells) > 1e-8
        # The returned outline stays the four corners.
        @test length(built.boundary) == 4
    end

    @testset "Each span deflects as a beam of its own thickness" begin
        L = 4.0
        b = 1.0
        E = 30e9
        ν = 0.01
        q = 5_000.0
        left = SS.StoryShellPanel(
            [(0.0, 0.0), (L, 0.0), (L, b), (0.0, b)],
            Asap.ShellSection(0.20u"m", E * u"Pa", ν))
        right = SS.StoryShellPanel(
            [(L, 0.0), (2L, 0.0), (2L, b), (L, b)],
            Asap.ShellSection(0.25u"m", E * u"Pa", ν))
        built = SS.story_shell([left, right], SS.ShellFrameBeam[]; target_edge = 0.5u"m")
        for n in built.nodes
            x = ustrip(u"m", n.position[1])
            y = ustrip(u"m", n.position[2])
            n.dof .= true
            if x < 1e-6 || abs(x - L) < 1e-6 || x > 2L - 1e-6
                n.dof[3] = false
            end
            if x < 1e-6 && y < 1e-6
                n.dof[1] = false
                n.dof[2] = false
                n.dof[6] = false
            elseif x < 1e-6 && y > b - 1e-6
                n.dof[2] = false
            end
        end
        load = Asap.AreaLoad(built.shells, q * u"Pa")
        model = Asap.Model(built.nodes, built.frames, built.shells, [load])
        Asap.process!(model)
        Asap.solve!(model)

        function mid_defl(x0)
            best, bestd = built.nodes[1], Inf
            for n in built.nodes
                d = hypot(ustrip(u"m", n.position[1]) - x0, ustrip(u"m", n.position[2]) - b / 2)
                if d < bestd
                    best = n
                    bestd = d
                end
            end
            return abs(ustrip(u"m", best.displacement[3]))
        end
        # The centre line does not settle, and the two spans are continuous, so
        # the slope there is held near zero. Each span is a propped cantilever:
        # midspan deflection w L⁴ / (192 E I), two-fifths of the simple-span value.
        function beam_defl(t)
            I = b * t^3 / 12
            w = q * b
            return w * L^4 / (192 * E * I)
        end
        @test mid_defl(L / 2) ≈ beam_defl(0.20) rtol = 0.08
        @test mid_defl(1.5 * L) ≈ beam_defl(0.25) rtol = 0.08
        @test mid_defl(L / 2) > mid_defl(1.5 * L)

        rz = 0.0
        for n in built.nodes
            n.dof[3] && continue
            rz += ustrip(u"N", n.reaction[3])
        end
        @test rz ≈ q * (2L * b) rtol = 0.02
    end

    @testset "A simple span's midspan moment sizes the bottom bars" begin
        L = 4.0
        b = 1.0
        E = 30e9
        ν = 0.01
        qD = 2_000.0
        qL = 3_000.0
        # The same pairs the flat-plate shell stores in `_LOAD_COMBOS`.
        qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
        panel = SS.StoryShellPanel(
            [(0.0, 0.0), (L, 0.0), (L, b), (0.0, b)],
            Asap.ShellSection(0.20u"m", E * u"Pa", ν))
        built = SS.story_shell([panel], SS.ShellFrameBeam[]; target_edge = 0.5u"m")
        for n in built.nodes
            x = ustrip(u"m", n.position[1])
            y = ustrip(u"m", n.position[2])
            n.dof .= true
            if x < 1e-6 || x > L - 1e-6
                n.dof[3] = false
            end
            if x < 1e-6 && y < 1e-6
                n.dof[1] = false
                n.dof[2] = false
                n.dof[6] = false
            elseif x < 1e-6 && y > b - 1e-6
                n.dof[2] = false
            end
        end
        model = Asap.Model(built.nodes, built.frames, built.shells,
                           [Asap.AreaLoad(built.shells, 1.0u"Pa")])
        Asap.process!(model)
        Asap.solve!(model)
        design = StoryPanelDesign(qD * u"Pa", qL * u"Pa", 0.20u"m", (1.0, 0.0), OneWay())
        @test_throws ArgumentError story_panel_reinforcement(
            model, built.panel_index, [design], OneWayMomentCoefficients())
        fields = story_panel_reinforcement(
            model, built.panel_index, [design]; fc = NWC_4000.fc′)
        field = only(fields)
        @test field.moment_transform == :wood_armer
        @test field.d ≈ ustrip(u"m", effective_depth(0.20u"m"; two_way = false))
        num = 0.0
        den = 0.0
        for el in field.elements
            abs(el.cx - L / 2) < 0.35 || continue
            num += el.Mu_x_bot * el.area
            den += el.area
        end
        # A strip of unit width, simply supported: M = q L² / 8.
        @test den > 0
        @test (num / den) ≈ (qu * L^2 / 8) rtol = 0.10
        @test field.section_adequate
        @test maximum(el.As_x_bot for el in field.elements) >= first(field.elements).As_min
        @test maximum(el.As_x_bot for el in field.elements) > 0
    end
end
