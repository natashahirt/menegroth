# Steel binary search must not treat "heaviest section fails" as "nothing works",
# and it must not stop five sections below the search hit. Feasibility is not
# monotone in weight order (a depth limit rejects the heaviest section; LTB can
# reject a mid-weight section that a lighter one passes).

struct DepthProbeChecker <: StructuralSizer.AbstractCapacityChecker end

struct DepthProbeCache <: StructuralSizer.AbstractCapacityCache
    ok::Vector{Bool}
    obj::Vector{Float64}
end

struct DepthProbeSection <: StructuralSizer.AbstractSection end
struct DepthProbeDemand <: StructuralSizer.AbstractDemand
    member_idx::Int
end
struct DepthProbeGeometry <: StructuralSizer.AbstractMemberGeometry end
struct DepthProbeMaterial <: StructuralSizer.AbstractMaterial end

function StructuralSizer.is_feasible(
    ::DepthProbeChecker, cache::DepthProbeCache, j::Int,
    ::DepthProbeSection, ::DepthProbeMaterial, ::DepthProbeDemand, ::DepthProbeGeometry,
)
    return cache.ok[j]
end

StructuralSizer.get_objective_coeff(::DepthProbeChecker, cache::DepthProbeCache, j::Int) =
    cache.obj[j]

function _probe_search(ok::Vector{Bool}, obj::Vector{Float64})
    n = length(ok)
    catalog = [DepthProbeSection() for _ in 1:n]
    return StructuralSizer._binary_search_feasible(
        DepthProbeChecker(), DepthProbeCache(ok, obj), catalog, DepthProbeMaterial(),
        DepthProbeDemand(1), DepthProbeGeometry(), collect(1:n),
    )
end

@testset "binary search depth limit and back-scan" begin
    # Heaviest fails a depth limit. A lighter section is feasible. The old
    # search returned 0 here.
    @test _probe_search([false, true, false, false], [1.0, 2.0, 3.0, 4.0]) == 2

    # Heaviest passes, so binary search lands on it. Section 2 is feasible and
    # more than five steps lighter. The old five-step scan missed it.
    ok = fill(false, 12)
    ok[2] = true
    ok[12] = true
    @test _probe_search(ok, collect(Float64, 1:12)) == 2

    # Lightest feasible is the answer without a scan when it passes.
    @test _probe_search([true, false, true], [1.0, 2.0, 3.0]) == 1

    # Nothing feasible.
    @test _probe_search([false, false, false], [1.0, 2.0, 3.0]) == 0
end
