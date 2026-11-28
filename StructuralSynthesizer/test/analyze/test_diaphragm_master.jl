# A plan-only rigid diaphragm leaves u_z, θ_x, and θ_y free. Each end of that
# link has to already sit on a column, beam, or wall shell. A node created
# only to be the master makes the reduced model singular.

using Test
using Unitful
using Asap
using StructuralSynthesizer

function _column_section()
    return Asap.Section(1.0u"m^2", 30e9u"Pa", 12.5e9u"Pa",
                        0.1u"m^4", 0.1u"m^4", 0.05u"m^4", 0.0u"kg/m^3")
end

function _zero_section()
    return Asap.Section(0.0u"m^2", 30e9u"Pa", 12.5e9u"Pa",
                        0.0u"m^4", 0.0u"m^4", 0.0u"m^4", 0.0u"kg/m^3")
end

"""Tie ux, uy, θz. Leave uz, θx, θy free."""
function _plan_tie(master, slave)
    release = ntuple(i -> !(i in (1, 2, 6)), 6)
    return Asap.RigidLink(master, slave; release=release, id=:rigid_diaphragm)
end

@testset "diaphragm node must already be stiff" begin
    base = Asap.Node([0.0, 0.0, 0.0] .* u"m", :fixed)
    top = Asap.Node([0.0, 0.0, 4.0] .* u"m", :free)
    column = Asap.Element(base, top, _column_section())
    floating = Asap.Node([1.0, 0.0, 4.0] .* u"m", :free)

    @test_throws msg -> occursin("singular", msg) require_diaphragm_node_stiffness(
        [_plan_tie(floating, top)], [column], Asap.ShellTri3[])

    base2 = Asap.Node([8.0, 0.0, 0.0] .* u"m", :fixed)
    top2 = Asap.Node([8.0, 0.0, 4.0] .* u"m", :free)
    column2 = Asap.Element(base2, top2, _column_section())
    @test require_diaphragm_node_stiffness(
        [_plan_tie(top, top2)], [column, column2], Asap.ShellTri3[]) === nothing

    # A floating slave keeps the same three DOFs free.
    @test_throws ArgumentError require_diaphragm_node_stiffness(
        [_plan_tie(top, floating)], [column], Asap.ShellTri3[])

    shell_top = Asap.Node([0.0, 2.0, 4.0] .* u"m", :free)
    shell_side = Asap.Node([1.0, 2.0, 4.0] .* u"m", :free)
    shell_base = Asap.Node([0.0, 2.0, 3.0] .* u"m", :fixed)
    shell = Asap.ShellTri3((shell_top, shell_side, shell_base),
                           0.3u"m", 30e9u"Pa", 0.2; id=:wall)
    @test require_diaphragm_node_stiffness(
        [_plan_tie(top, shell_top)], [column], [shell]) === nothing

    wall_base = Asap.Node([2.0, 0.0, 0.0] .* u"m", :fixed)
    wall_top = Asap.Node([2.0, 0.0, 4.0] .* u"m", :free)
    wall_edge = Asap.Element(wall_base, wall_top, _zero_section())
    @test_throws ArgumentError require_diaphragm_node_stiffness(
        [_plan_tie(wall_top, top)], [wall_edge, column], Asap.ShellTri3[])

    # A fully supported node is not a free unknown.
    held = Asap.Node([3.0, 0.0, 4.0] .* u"m", :fixed)
    @test require_diaphragm_node_stiffness(
        [_plan_tie(top, held)], [column], Asap.ShellTri3[]) === nothing

    # A link that also ties the gravity DOFs is not this check.
    full = Asap.RigidLink(floating, top)
    @test require_diaphragm_node_stiffness([full], [column], Asap.ShellTri3[]) === nothing
end
