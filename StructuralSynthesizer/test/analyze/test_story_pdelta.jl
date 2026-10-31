# Story geometric stiffness on the rigid-diaphragm masters.
#
# Wilson & Habibullah (1987) (corpus: wilson-habibullah-1987-pdelta). The
# builder places each member force through the rigid-floor kinematics. That
# must equal the paper's centroid form: Eq. 12 with r² (PDF p. 8) moved to the
# masters by Eqs. 13–14 (PDF pp. 9–10), with W = ΣP at the force centroid
# and W r² = Σ P |p − c|².

using Test
using Unitful
using Asap
using LinearAlgebra
using StructuralSynthesizer

const _SS = StructuralSynthesizer

"""Paper form: −A_jᵀ L'_ij A_j on (u_xT, u_yT, θ_T, u_xB, u_yB, θ_B)."""
function _wilson_block(W, r2, h, c, top, bot)
    Lp = (W / h) .* [ 1  0  0  -1   0   0
                      0  1  0   0  -1   0
                      0  0  r2  0   0  -r2
                     -1  0  0   1   0   0
                      0 -1  0   0   1   0
                      0  0 -r2  0   0   r2]
    # U'_j = A_j U_j: displacement at the point under the centroid c.
    a(m) = [1.0 0.0 -(c[2] - m[2])
            0.0 1.0  (c[1] - m[1])
            0.0 0.0  1.0]
    A = zeros(6, 6)
    A[1:3, 1:3] = a(top)
    A[4:6, 4:6] = a(bot)
    return -(transpose(A) * Lp * A)
end

function _xy(nd)
    p = nd.position
    return (ustrip(u"m", p[1]), ustrip(u"m", p[2]))
end

@testset "Story geometric stiffness (Wilson & Habibullah 1987)" begin

    @testset "Member form equals Eqs. 12–14 with offset masters" begin
        base = Asap.Node([0.0, 0.0, 0.0] .* u"m", :fixed)
        mbot = Asap.Node([-0.3, 0.2, 3.0] .* u"m", :free)
        mtop = Asap.Node([1.0, 0.5, 6.5] .* u"m", :free)
        sec = Asap.Section(0.01u"m^2", 200e9u"Pa", 77e9u"Pa", 1e-4u"m^4", 1e-4u"m^4", 1e-5u"m^4")
        model = Asap.Model([base, mbot, mtop],
                           [Asap.Element(base, mbot, sec), Asap.Element(mbot, mtop, sec)],
                           Asap.AbstractLoad[])
        Asap.process!(model)

        pts = [(2.0, 1.0, 4.0e5), (-1.5, 2.5, 2.5e5), (0.5, -2.0, 6.0e5),
               (3.0, -1.0, 1.5e5), (-2.0, -0.5, -0.5e5)]   # one member in tension
        prof = _SS.StoryAxialProfile(3.0, 6.5, mtop, mbot, pts)
        Kg = _SS.story_geometric_stiffness(model, [prof])

        W = sum(p[3] for p in pts)
        c = (sum(p[1] * p[3] for p in pts) / W, sum(p[2] * p[3] for p in pts) / W)
        r2 = sum(p[3] * ((p[1] - c[1])^2 + (p[2] - c[2])^2) for p in pts) / W
        @test W == _SS.story_axial_total(prof)

        dofs = [mtop.globalID[1], mtop.globalID[2], mtop.globalID[6],
                mbot.globalID[1], mbot.globalID[2], mbot.globalID[6]]
        ref = _wilson_block(W, r2, 3.5, c, _xy(mtop), _xy(mbot))
        @test Matrix(Kg[dofs, dofs]) ≈ ref rtol=1e-12
        @test Kg ≈ transpose(Kg)
        others = setdiff(1:model.nDOFs, dofs)
        @test iszero(Kg[others, :])

        # Fixed base: the bottom rows and columns drop out of the same block.
        prof0 = _SS.StoryAxialProfile(3.0, 6.5, mtop, nothing, pts)
        Kg0 = _SS.story_geometric_stiffness(model, [prof0])
        @test Matrix(Kg0[dofs[1:3], dofs[1:3]]) ≈ ref[1:3, 1:3] rtol=1e-12
        @test iszero(Kg0[dofs[4:6], :])

        @test_throws ArgumentError _SS.story_geometric_stiffness(
            model, [_SS.StoryAxialProfile(3.0, 3.0, mtop, mbot, pts)])
    end

    @testset "Gravity cut, then the lateral solve amplifies by 1/(1−θ)" begin
        h = 4.0
        b = 1.5
        P = 2.0e6                       # N on each column top
        H = 1.0e4                       # N at the master
        sec = Asap.Section(0.01u"m^2", 200e9u"Pa", 77e9u"Pa", 1e-4u"m^4", 1e-4u"m^4", 1e-5u"m^4")
        corners = [(b, b), (-b, b), (-b, -b), (b, -b)]
        bases = [Asap.Node([x, y, 0.0] .* u"m", :fixed) for (x, y) in corners]
        tops = [Asap.Node([x, y, h] .* u"m", :free) for (x, y) in corners]
        master = Asap.Node([0.0, 0.0, h] .* u"m", :free)
        model = Asap.Model(vcat(bases, tops, [master]),
                           [Asap.Element(bases[i], tops[i], sec) for i in 1:4],
                           Asap.AbstractLoad[])
        links = [Asap.RigidLink(master, t) for t in tops]
        Asap.process!(model)

        gravity = Asap.AbstractLoad[Asap.NodeForce(t, [0.0, 0.0, -P] .* u"N") for t in tops]
        ug = Asap.solve(model, [gravity], links)[1]
        profs = _SS.story_axial_profiles(model, ug, _SS.WallMesh(), [(h, master)], 0.0;
                                         loads=gravity)
        @test length(profs) == 1
        prof = only(profs)
        @test prof.master_bottom === nothing
        @test _SS.story_axial_total(prof) ≈ 4P rtol=1e-9
        @test all(pt -> isapprox(pt[3], P; rtol=1e-9), prof.points)

        Kg = _SS.story_geometric_stiffness(model, profs)
        gx, gθ = master.globalID[1], master.globalID[6]
        @test Kg[gx, gx] ≈ -4P / h rtol=1e-9
        @test Kg[gθ, gθ] ≈ -4P * 2b^2 / h rtol=1e-9

        lateral = Asap.AbstractLoad[Asap.NodeForce(master, [H, 0.0, 0.0] .* u"N")]
        Δ0 = Asap.solve(model, [lateral], links)[1][gx]
        u = Asap.solve(model, [lateral], links; geometric_stiffness=Kg)[1]
        Δ = u[gx]
        θ = 4P * Δ0 / (H * h)           # ASCE 7-22 Eq. 12.8-16 with Ie = Cd
        @test 0.10 < θ < 0.3
        @test Δ ≈ Δ0 / (1 - θ) rtol=1e-9

        # K_e u exceeds the applied shear by the story couple. Without −K_G u
        # the cut residual is that couple; with it the cut closes.
        bare = _SS.check_story_cut_equilibrium(model, u, _SS.WallMesh(), lateral, 0.0;
                                              fixed_end_from_loads=true)
        @test bare.residual[1] ≈ (4P / h) * Δ rtol=1e-6 atol=1.0
        @test !bare.passed
        closed = _SS.check_story_cut_equilibrium(model, u, _SS.WallMesh(), lateral, 0.0;
                                                fixed_end_from_loads=true,
                                                geometric_stiffness=Kg)
        @test closed.passed
    end

    @testset "§6.2.5.3 moment cap and load scaling" begin
        _SS.require_second_order_moment(1.4, 1.0)
        _SS.require_second_order_moment(0.4, 0.2)
        @test_throws ArgumentError _SS.require_second_order_moment(1.4 + 2.0, 1.0)
        node = Asap.Node([0.0, 0.0, 0.0] .* u"m", :free)
        ld = Asap.NodeForce(node, [2.0, 0.0, -4.0] .* u"N")
        scaled = _SS.scale_story_loads([ld], 1.2)
        @test ustrip.(u"N", only(scaled).value) ≈ [2.4, 0.0, -4.8]
        @test isempty(_SS.scale_story_loads([ld], 0.0))
        @test ld.value[1] == 2.0u"N"
    end

    @testset "A base free in plan is refused" begin
        h = 3.0
        sec = Asap.Section(0.01u"m^2", 200e9u"Pa", 77e9u"Pa", 1e-4u"m^4", 1e-4u"m^4", 1e-5u"m^4")
        base = Asap.Node([0.0, 0.0, 0.0] .* u"m", [true, true, false, false, false, false])
        top = Asap.Node([0.0, 0.0, h] .* u"m", :free)
        master = Asap.Node([0.5, 0.0, h] .* u"m", :free)
        model = Asap.Model([base, top, master], [Asap.Element(base, top, sec)],
                           Asap.AbstractLoad[])
        Asap.process!(model)
        u = zeros(model.nDOFs)
        @test_throws ArgumentError _SS.story_axial_profiles(
            model, u, _SS.WallMesh(), [(h, master)], 0.0)
        @test_throws ArgumentError _SS.story_axial_profiles(
            model, u, _SS.WallMesh(), [(0.0, master)], 0.0)
    end
end
