# HAND CHECK — FEM in-plane rigid diaphragm does not use the penalty shell.
#
# The production drift authority ties (u_x, u_y, θ_z) and releases
# (u_z, θ_x, θ_y). This test checks that mode. It does not retune the
# penalty-shell equivalence tests, and it is not a published example.

using Test
using Unitful
using StructuralSizer
using Asap

const _INPLANE_RELEASE = (false, false, true, true, true, false)

function _two_walls()
    return [
        WallPanel(1, 0.0, 0.0, 4.0, 0.0, 0.0, 3.0, 0.2, 25e9, 0.2, 1),
        WallPanel(2, 0.0, 6.0, 4.0, 6.0, 0.0, 3.0, 0.2, 25e9, 0.2, 1),
    ]
end

@testset "FEM in-plane rigid diaphragm" begin
    panels = _two_walls()
    loads = [StoryLoad(1, 1.0e5, 0.0, 2.0, 3.0)]
    ev = FEMLateralEvaluator(story_heights=[3.0], mesh_div=1,
                             diaphragm_mode=:rigid, diaphragm_E=1.0e12)
    model, _, _, _, _, links = StructuralSizer._build_asap_wall_model(ev, panels, loads)

    @test !isempty(links)
    @test all(link -> link.release == _INPLANE_RELEASE, links)
    @test all(sh -> sh.id != :diaphragm, model.shell_elements)
    @test all(sh -> sh.E != 1.0e12, model.shell_elements)
    @test all(sh -> sh.id == :wall && sh.E == 25e9, model.shell_elements)

    # The penalty modulus is not in the solve: a different diaphragm_E
    # does not change the drift.
    other = FEMLateralEvaluator(story_heights=[3.0], mesh_div=1,
                                diaphragm_mode=:rigid, diaphragm_E=1.0e6)
    r_hi = evaluate_lateral(ev, panels, loads)
    r_lo = evaluate_lateral(other, panels, loads)
    @test r_hi.drift == r_lo.drift
    @test all(isfinite, r_hi.drift)

    # The default mode is still the penalty shell. This does not compare drift.
    penalty = FEMLateralEvaluator(story_heights=[3.0], mesh_div=1)
    penalty_model, = StructuralSizer._build_asap_wall_model(penalty, panels, loads)
    dia = [sh for sh in penalty_model.shell_elements if sh.id == :diaphragm]
    @test !isempty(dia)
    @test all(sh -> sh.E == 1.0e12, dia)
end

# Regression: the story force acts at StoryLoad's (ex, ey) in both diaphragm
# modes. The :rigid master is a wall corner node, and loading it directly put a
# symmetric core under pure X load into torsion 1.22 with a 1.5x wall split.
function _symmetric_core()
    E = 25e9; ν = 0.2; t = 0.3; H = 3.0
    # Opposite panels run in opposite directions so the mesh is symmetric too.
    return [
        WallPanel(1, -2.0, -5.0,  2.0, -5.0, 0.0, H, t, E, ν, 1),
        WallPanel(2,  2.0,  5.0, -2.0,  5.0, 0.0, H, t, E, ν, 1),
        WallPanel(3, -5.0, -2.0, -5.0,  2.0, 0.0, H, t, E, ν, 1),
        WallPanel(4,  5.0,  2.0,  5.0, -2.0, 0.0, H, t, E, ν, 1),
    ]
end

"""Base-reaction resultant `(ΣRx, ΣRy, ΣMz about the plan origin)` of a solved model."""
function _base_resultant(ev, panels, loads)
    model, _, _, _, _, links = StructuralSizer._build_asap_wall_model(ev, panels, loads)
    isempty(links) ? Asap.solve!(model) : Asap.solve!(model, links; reprocess=false)
    Rx = Ry = Mz = 0.0
    for nd in model.nodes
        iszero(ustrip(u"m", nd.position[3])) || continue
        rx = ustrip(u"N", nd.reaction[1]); ry = ustrip(u"N", nd.reaction[2])
        x = ustrip(u"m", nd.position[1]); y = ustrip(u"m", nd.position[2])
        Rx += rx; Ry += ry
        Mz += x * ry - y * rx + ustrip(u"N*m", nd.reaction[6])   # fixed base carries θz too
    end
    return Rx, Ry, Mz
end

@testset "FEM story load acts at (ex, ey)" begin
    panels = _symmetric_core()
    F = 1.0e5
    evs = Dict(mode => FEMLateralEvaluator(story_heights=[3.0], mesh_div=3,
                                           plan_halfwidth=(5.0, 5.0), diaphragm_mode=mode)
               for mode in (:penalty_shell, :rigid))

    # Centered load on a symmetric core: no twist, equal split, in both modes.
    for (mode, ev) in evs
        r = evaluate_lateral(ev, panels, [StoryLoad(1, F, 0.0, 0.0, 0.0)])
        @test r.torsion[1] ≈ 1.0 atol=1e-6
        @test r.wall_forces[1] ≈ r.wall_forces[2] rtol=1e-9
        @test abs(r.story_disp[1, 3]) < 1e-15
    end

    # Load 1 m toward wall 2 (ey = 1): statics. The applied moment about the
    # origin is ex·Fy − ey·Fx = −1e5 N·m, so the base reactions must carry +1e5,
    # whichever node the diaphragm master is.
    off = [StoryLoad(1, F, 0.0, 0.0, 1.0)]
    for (mode, ev) in evs
        Rx, Ry, Mz = _base_resultant(ev, panels, off)
        @test Rx ≈ -F rtol=1e-8
        @test abs(Ry) < 1e-6 * F
        @test Mz ≈ 1.0 * F rtol=1e-6
        r = evaluate_lateral(ev, panels, off)
        @test r.story_disp[1, 3] < 0                  # clockwise twist
        @test r.wall_forces[2] > r.wall_forces[1]     # the nearer wall takes more
    end

    # The near-rigid penalty shell and the rigid links agree on the twist.
    rp = evaluate_lateral(evs[:penalty_shell], panels, off)
    rr = evaluate_lateral(evs[:rigid], panels, off)
    @test rp.story_disp[1, 3] ≈ rr.story_disp[1, 3] rtol=0.02
    @test rp.wall_forces[1] / rp.wall_forces[2] ≈ rr.wall_forces[1] / rr.wall_forces[2] rtol=0.02
end
