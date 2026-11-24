using StructuralSizer
using Asap
using Test
using Unitful

# Drift governor: the catalog-aware outer loop (participation → optimality resize
# → snap → re-solve). Tests cover the pure snap, continuous and discrete-catalog
# convergence on a multi-story stick, and the non-sized "background" accounting.

# Build a fresh vertical cantilever stick with `nstory` elements at stiffness I0.
const _E = 200.0e9; const _G = 80.0e9; const _H = 3.5
const _A = 1.0e-2; const _J = 1.0e-6; const _P = 8.0e4; const _NST = 4; const _I0 = 6.0e-4

_mksec(I) = Section(_A * u"m^2", _E * u"Pa", _G * u"Pa",
                    I * u"m^4", I * u"m^4", _J * u"m^4")
_cur_I(el) = ustrip(u"m^4", el.section.Ix)
_apply_I!(el, I) = (el.section = _mksec(I))

function _build_stick()
    nodes = [Node([0.0u"m", 0.0u"m", (k * _H)u"m"], k == 0 ? :fixed : :free) for k in 0:_NST]
    els = [Element(nodes[k], nodes[k + 1], _mksec(_I0)) for k in 1:_NST]
    loads = [NodeForce(nodes[k + 1], [_P * u"N", 0.0u"N", 0.0u"N"]) for k in 1:_NST]
    model = FrameModel(nodes, els, loads)
    solve!(model)                                        # assigns globalIDs + state
    dofs = [nodes[k + 1].globalID[1] for k in 1:_NST]   # x-DOF of each story top
    return model, dofs
end

# Story drifts (story 1 from ground, the rest inter-story) at the current state.
function _story_drifts(model, dofs)
    u = [drift_participation(model, d).δ for d in dofs]
    return [u[1]; diff(u)]
end

# Per-story constraints: total drift for story 1, inter-story above.
function _story_constraints(dofs, δ_allow)
    cons = DriftConstraint[total_drift_constraint(dofs[1], δ_allow[1])]
    for k in 2:length(dofs)
        push!(cons, interstory_drift_constraint(dofs[k], dofs[k - 1], δ_allow[k]))
    end
    return cons
end

@testset "drift governor" begin

    @testset "snap_up picks the lightest section ≥ target" begin
        cat = [1.0, 2.0, 4.0, 8.0]
        @test snap_up(3.2, cat) == 4.0
        @test snap_up(2.0, cat) == 2.0          # exact match qualifies
        @test snap_up(0.5, cat) == 1.0
        @test snap_up(9.0, cat) == 8.0          # nothing ≥ target ⇒ largest
        @test_throws ArgumentError snap_up(1.0, Float64[])
    end

    @testset "continuous governor meets every story limit" begin
        model, dofs = _build_stick()
        solve!(model)
        δ_allow = 0.6 .* _story_drifts(model, dofs)
        cons = _story_constraints(dofs, δ_allow)
        res = resize_for_drift!(model, cons;
                                weight = [ustrip(u"m", el.length) for el in model.elements],
                                floor_I = fill(_I0, _NST),
                                catalog = nothing,
                                current_I = _cur_I, apply_I! = _apply_I!,
                                max_outer = 12, tol = 1e-2)
        @test res.converged
        @test res.status == :converged
        @test all(res.ratio .≤ 1 + 1e-2)
        @test all(res.sizes .≥ _I0 .- 1e-12)     # never below the strength floor
    end

    @testset "discrete-catalog governor stays feasible on real sections" begin
        model, dofs = _build_stick()
        solve!(model)
        δ_allow = 0.6 .* _story_drifts(model, dofs)
        cons = _story_constraints(dofs, δ_allow)
        catalog = [_I0 * 1.2^k for k in 0:14]
        res = resize_for_drift!(model, cons;
                                weight = [ustrip(u"m", el.length) for el in model.elements],
                                floor_I = fill(_I0, _NST),
                                catalog = catalog,
                                current_I = _cur_I, apply_I! = _apply_I!,
                                max_outer = 12, tol = 1e-2)
        @test res.converged
        @test all(res.ratio .≤ 1 + 1e-2)
        # Every delivered size is an actual catalog section.
        @test all(any(isapprox.(sz, catalog; rtol = 1e-9)) for sz in res.sizes)
    end

    @testset "non-sized background: accounting and infeasibility" begin
        # Constrain only the story-1 drift at node 1, which is governed entirely
        # by the base element (element 1). Sizing the upper elements alone cannot
        # reduce it → the governor must report background infeasibility.
        model, dofs = _build_stick()
        solve!(model)
        base_drift = _story_drifts(model, dofs)[1]
        tight = total_drift_constraint(dofs[1], 0.5 * base_drift)   # below what the base alone gives

        res_excl = resize_for_drift!(model, [tight];
                                     sized_elements = [2, 3, 4],     # exclude the base element
                                     weight = fill(1.0, 3),
                                     floor_I = fill(_I0, 3),
                                     catalog = nothing,
                                     current_I = _cur_I, apply_I! = _apply_I!,
                                     max_outer = 6, tol = 1e-2)
        @test res_excl.status == :background_infeasible
        @test !res_excl.converged

        # Including the base element, the same limit is reachable (stiffen element 1).
        model2, dofs2 = _build_stick()
        solve!(model2)
        tight2 = total_drift_constraint(dofs2[1], 0.5 * base_drift)
        res_incl = resize_for_drift!(model2, [tight2];
                                     sized_elements = [1, 2, 3, 4],
                                     weight = fill(1.0, 4),
                                     floor_I = fill(_I0, 4),
                                     catalog = nothing,
                                     current_I = _cur_I, apply_I! = _apply_I!,
                                     max_outer = 8, tol = 1e-2)
        @test res_incl.converged
        @test res_incl.ratio[1] ≤ 1 + 1e-2
    end

    @testset "rigid diaphragm: governor sizes columns on the reduced system" begin
        # Two columns tied to a diaphragm master; the drift constraint and the
        # participation both live on the reduced master/slave system (links set).
        E = 200.0e9; Gs = 80.0e9; H = 4.0; A = 1.0e-2; J = 1.0e-6
        b = 1.5; I0 = 4.0e-4; P = 6.0e4
        mksec(I) = Section(A * u"m^2", E * u"Pa", Gs * u"Pa",
                           I * u"m^4", I * u"m^4", J * u"m^4")
        base1 = Node([0.0u"m",  b * 1.0u"m", 0.0u"m"], :fixed)
        base2 = Node([0.0u"m", -b * 1.0u"m", 0.0u"m"], :fixed)
        top1  = Node([0.0u"m",  b * 1.0u"m", H * 1.0u"m"], :free)
        top2  = Node([0.0u"m", -b * 1.0u"m", H * 1.0u"m"], :free)
        master = Node([0.0u"m", 0.0u"m", H * 1.0u"m"], :free)
        c1 = Element(base1, top1, mksec(I0)); c2 = Element(base2, top2, mksec(I0))
        model = FrameModel([base1, base2, top1, top2, master], [c1, c2],
                           [NodeForce(master, [P * u"N", 0.0u"N", 0.0u"N"])])
        links = [RigidLink(master, top1), RigidLink(master, top2)]
        solve!(model, links)

        d0 = model.u[master.globalID[1]]            # current story drift at the master
        con = total_drift_constraint(master.globalID[1], 0.5 * d0)   # halve it
        curI(el) = ustrip(u"m^4", el.section.Ix)
        appI!(el, I) = (el.section = mksec(I))

        res = resize_for_drift!(model, [con];
                                sized_elements = [1, 2],
                                weight = [ustrip(u"m", c1.length), ustrip(u"m", c2.length)],
                                floor_I = [I0, I0],
                                catalog = nothing,
                                current_I = curI, apply_I! = appI!,
                                links = links, max_outer = 12, tol = 1e-2)
        @test res.converged
        @test res.status == :converged
        @test res.ratio[1] ≤ 1 + 1e-2
        @test all(res.sizes .≥ I0 - 1e-12)
        @test all(res.sizes .> I0)                  # columns had to grow to halve δ
        @test res.sizes[1] ≈ res.sizes[2] rtol = 1e-6   # symmetric columns size equally
    end
end
