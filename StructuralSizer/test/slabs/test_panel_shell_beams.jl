# Frame beams share the shell's nodes. The checks are closed-form.
#
# A strip with ν near 0 is a beam: δ = 5 w L⁴ / 384 E I.
# The same strip plus a web hung below the soffit is the transformed T-section.
# The support reactions equal the load on the panel.

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

"""Simply-supported strip: uz fixed on both short edges, the plane anchored."""
function _pin_strip!(nodes, L, b)
    for n in nodes
        x = ustrip(u"m", n.position[1])
        y = ustrip(u"m", n.position[2])
        on_end = x < 1e-6 || x > L - 1e-6
        n.dof .= true
        if on_end
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
    return nodes
end

function _midspan_node(nodes, L, b)
    best = nodes[1]
    best_d = Inf
    for n in nodes
        d = hypot(ustrip(u"m", n.position[1]) - L / 2, ustrip(u"m", n.position[2]) - b / 2)
        if d < best_d
            best = n
            best_d = d
        end
    end
    return best
end

function _solve_strip(section, beams, L, b, q, h)
    boundary = [(0.0, 0.0), (L, 0.0), (L, b), (0.0, b)]
    built = SS.panel_shell_with_beams(boundary, section, beams; target_edge = h * u"m")
    _pin_strip!(built.nodes, L, b)
    load = Asap.AreaLoad(built.shells, q * u"Pa")
    model = Asap.Model(built.nodes, built.frames, built.shells, [load])
    Asap.process!(model)
    Asap.solve!(model)
    return model, built
end

@testset "Panel shell with frame beams" begin
    L = 8.0
    b = 1.0
    t = 0.20
    E = 30e9
    ν = 0.01
    q = 5_000.0
    h = 0.25
    G = E / (2 * (1 + ν))
    section = Asap.ShellSection(t * u"m", E * u"Pa", ν)

    # Beam formula for a strip of width b. w = q b.
    function beam_defl(I)
        w = q * b
        return 5 * w * L^4 / (384 * E * I)
    end

    @testset "A one-way strip deflects as a beam" begin
        model, built = _solve_strip(section, SS.ShellFrameBeam[], L, b, q, h)
        mid = _midspan_node(built.nodes, L, b)
        δ = abs(ustrip(u"m", mid.displacement[3]))
        I_slab = b * t^3 / 12
        @test δ ≈ beam_defl(I_slab) rtol = 0.08

        Rz = sum(ustrip(u"N", n.reaction[3]) for n in built.nodes)
        @test Rz ≈ q * L * b rtol = 0.02
    end

    @testset "An offset web makes the transformed T-section" begin
        bw, hw = 0.30, 0.50
        I_web = bw * hw^3 / 12
        I_weak = hw * bw^3 / 12
        web = Asap.Section(bw * hw * u"m^2", E * u"Pa", G * u"Pa",
                           I_web * u"m^4", I_weak * u"m^4", I_web * u"m^4")
        ecc = SS.web_below_slab_eccentricity(t * u"m", hw * u"m")
        @test ecc[3] ≈ -(t / 2 + hw / 2)
        beam = SS.ShellFrameBeam([(0.0, b / 2), (L, b / 2)], web; eccentricity = ecc)
        model, built = _solve_strip(section, [beam], L, b, q, h)
        @test !isempty(built.frames)
        # Every frame node is a shell node.
        shell_ids = IdDict(n => true for n in built.nodes)
        @test all(haskey(shell_ids, el.nodeStart) && haskey(shell_ids, el.nodeEnd)
                  for el in built.frames)

        A_s, A_w = b * t, bw * hw
        y_w = ecc[3]
        ybar = A_w * y_w / (A_s + A_w)
        I_T = b * t^3 / 12 + A_s * ybar^2 + I_web + A_w * (y_w - ybar)^2
        mid = _midspan_node(built.nodes, L, b)
        δ = abs(ustrip(u"m", mid.displacement[3]))
        @test δ ≈ beam_defl(I_T) rtol = 0.10

        Rz = sum(ustrip(u"N", n.reaction[3]) for n in built.nodes)
        @test Rz ≈ q * L * b rtol = 0.02
    end
end
