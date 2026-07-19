# =============================================================================
# DesignGraph topology test — non-linear (diamond) ordering + determinism
# =============================================================================
#
# Run 1 only ever builds a LINEAR chain of stages, so `topological_order`'s
# tie-break rule (what happens when two nodes become ready simultaneously) is
# never exercised by the equivalence gate. Run 2 will introduce real DAGs, so
# this test pins the tie-break BEFORE that lands.
#
# Fixture is a classic diamond:
#
#         A          A has no dependencies (root)
#        / \         B depends on A
#       B   C        C depends on A
#        \ /         D depends on B and C
#         D
#
# With Kahn's algorithm and insertion-order tie-breaking (see graph.jl), the
# ready set is kept sorted by insertion index, so when B and C are both ready
# after A, B (inserted first) is emitted first. The expected order is therefore
# fully determined: [:A, :B, :C, :D]. This test asserts (1) that exact order,
# (2) that it respects every dependency edge, and (3) that it is deterministic
# across repeated calls.
#
# Run standalone:
#   julia --project=StructuralSynthesizer \
#       StructuralSynthesizer/test/design_graph/test_design_graph_topology.jl
# =============================================================================

using StructuralSynthesizer
using Test

println("Testing DesignGraph topological ordering (diamond fixture)...")

# No-op stage closure: a pure ordering test never touches `struc`, so the node
# body does nothing. `StageNode(key, deps, fn, needs_sync)` is the Run-1 node.
_noop_stage(key, deps) = StageNode(key, deps, _ -> nothing, false)

@testset "DesignGraph topological_order (diamond)" begin
    # Insertion order [A, B, C, D] fixes the tie-break: B before C.
    A = _noop_stage(:A, NodeKey[])
    B = _noop_stage(:B, NodeKey[:A])
    C = _noop_stage(:C, NodeKey[:A])
    D = _noop_stage(:D, NodeKey[:B, :C])

    g = DesignGraph([A, B, C, D])

    order = topological_order(g)

    # (1) Exact expected order — pins the insertion-index tie-break.
    @test order == [:A, :B, :C, :D]

    # (2) Dependency-respecting: every node appears after all its dependencies.
    pos = Dict(k => i for (i, k) in enumerate(order))
    @test pos[:A] < pos[:B]
    @test pos[:A] < pos[:C]
    @test pos[:B] < pos[:D]
    @test pos[:C] < pos[:D]

    # (3) Deterministic: a second call returns an identical ordering.
    @test topological_order(g) == order
end

println("\n✓ DesignGraph topology test passed!")
