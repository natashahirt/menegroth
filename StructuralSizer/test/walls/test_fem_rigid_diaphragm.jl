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
