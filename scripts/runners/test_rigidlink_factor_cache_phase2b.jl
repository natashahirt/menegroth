# Targeted verification for #7 phase 2b — the caller-owned
# `RigidLinkFactorCache` threaded into the non-mutating
# `solve(model, cases, links; geometric_stiffness/exclude_shells, factor_cache)`.
#
# Proves two things on a small frame swept over several geometric-stiffness
# matrices (the lateral stage's per-gravity-key P-Δ sweep):
#   1. Equivalence — results with a cache are bit-identical to results without,
#      for every case and every K_G (a reuse must never change the answer).
#   2. Reuse — the first K_G factors fresh (one `:factor`), and every later K_G
#      on the same pattern reuses the symbolic analysis (`:refactor`), so the
#      sweep pays one symbolic factorization, not one per key.
#
#   julia --project=external/Asap scripts/runners/test_rigidlink_factor_cache_phase2b.jl
using Asap, Test, LinearAlgebra, Unitful, SparseArrays
Unitful.register(Asap)

"""Two-story single-bay moment frame (no links: G is identity, so the reduced
path still runs and `K_G` is honoured)."""
function _frame()
    E = 200e9u"Pa"; G = 77e9u"Pa"
    col = Section(0.015u"m^2", E, G, 3e-4u"m^4", 1e-4u"m^4", 5e-6u"m^4")
    bm  = Section(0.020u"m^2", E, G, 5e-4u"m^4", 2e-4u"m^4", 8e-6u"m^4")
    L = 6.0u"m"; H = 3.5u"m"
    nodes = [
        Node([0.0u"m", 0.0u"m", 0.0u"m"], :fixed),
        Node([L,       0.0u"m", 0.0u"m"], :fixed),
        Node([0.0u"m", 0.0u"m", H],       :free),
        Node([L,       0.0u"m", H],       :free),
        Node([0.0u"m", 0.0u"m", 2H],      :free),
        Node([L,       0.0u"m", 2H],      :free),
    ]
    elements = [
        Element(nodes[1], nodes[3], col, :c1),
        Element(nodes[2], nodes[4], col, :c2),
        Element(nodes[3], nodes[5], col, :c3),
        Element(nodes[4], nodes[6], col, :c4),
        Element(nodes[3], nodes[4], bm,  :b1),
        Element(nodes[5], nodes[6], bm,  :b2),
    ]
    model = Model(nodes, elements, Asap.AbstractLoad[])
    process!(model)
    return model, nodes
end

"""A symmetric story geometric-stiffness matrix with `(P/h)[1 -1; -1 1]` couples
on the lateral (x) DOFs of the two levels — same sparsity for every `P`, so the
reduced pattern is stable across the sweep (the condition the cache exploits)."""
function _story_kg(model, nodes, P1, P2)
    H = 3.5
    n = model.nDOFs
    K = spzeros(n, n)
    xdof(nd) = nd.globalID[1]
    add!(K, a, b, v) = (K[a, a] += v; K[b, b] += v; K[a, b] -= v; K[b, a] -= v)
    # Story 1: ground (fixed, no free DOF) → level 1 ; Story 2: level 1 → level 2.
    add!(K, xdof(nodes[3]), xdof(nodes[5]), P2 / H)   # upper story couple
    K[xdof(nodes[3]), xdof(nodes[3])] += P1 / H       # lower story (base fixed)
    return -K                                          # signed: compression < 0
end

"""Count `:factor` / `:refactor` events while running `f`."""
function _counts(f)
    log = Asap.AnalysisLog()
    Asap.with_analysis_log(log) do
        f()
    end
    nf = count(e -> e.kind == :factor, log.events)
    nr = count(e -> e.kind == :refactor, log.events)
    return nf, nr
end

@testset "#7 phase 2b — cache equivalence + reuse" begin
    model, nodes = _frame()
    links = Asap.RigidLink[]
    V = 50e3
    cases = [
        [NodeForce(nodes[3], [V * 1.0u"N", 0.0u"N", 0.0u"N"]),
         NodeForce(nodes[5], [V * 1.0u"N", 0.0u"N", 0.0u"N"])],
        [NodeForce(nodes[5], [V * 2.0u"N", 0.0u"N", 0.0u"N"])],
    ]
    kgs = [_story_kg(model, nodes, 500e3 * s, 400e3 * s) for s in (1.0, 1.5, 0.75)]

    @testset "geometric_stiffness equivalence" begin
        cache = RigidLinkFactorCache()
        for Kg in kgs
            ref = Asap.solve(model, cases, links; geometric_stiffness = Kg)
            got = Asap.solve(model, cases, links; geometric_stiffness = Kg,
                             factor_cache = cache)
            @test length(got) == length(ref)
            for j in eachindex(ref)
                @test got[j] == ref[j]          # bit-identical, not ≈
            end
        end
    end

    @testset "symbolic analysis reused across the sweep" begin
        cache = RigidLinkFactorCache()
        nf, nr = _counts() do
            for Kg in kgs
                Asap.solve(model, cases, links; geometric_stiffness = Kg,
                           factor_cache = cache)
            end
        end
        @test nf == 1                            # one fresh symbolic analysis
        @test nr == length(kgs) - 1              # the rest reuse it

        # Without a cache, every key factors fresh.
        nf0, nr0 = _counts() do
            for Kg in kgs
                Asap.solve(model, cases, links; geometric_stiffness = Kg)
            end
        end
        @test nf0 == length(kgs)
        @test nr0 == 0
    end
end
