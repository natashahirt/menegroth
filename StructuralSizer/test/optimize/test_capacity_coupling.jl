using StructuralSizer
using Unitful
using Test
import JuMP
const MOI = JuMP.MOI

# Design-dependent capacity coupling for the discrete member MILP. The property
# under test: when a member's demand is a LINEAR function of the section choices
# (the self-weight case — a column's load accumulates the weight of what it
# supports), `optimize_discrete(; coupling)` folds that dependency into a single
# certified MILP, so the returned sizes are globally optimal AND self-consistent
# with their own load in ONE solve — no demand-fixpoint iteration / ratchet.

const _CAT = all_W()
const _CHK = AISCChecker()
const _A   = [ustrip(u"m^2", section_area(s)) for s in _CAT]
const _N   = length(_CAT)

# Two lightly-loaded, identical groups: screening admits a wide feasible set and,
# uncoupled, each picks the lightest feasible W (the same one).
const _DEM = [MemberDemand(1; Mux = 50.0e3), MemberDemand(2; Mux = 50.0e3)]
const _GEO = [SteelMemberGeometry(4.0; Lb = 4.0), SteelMemberGeometry(4.0; Lb = 4.0)]

@testset "capacity coupling: flag-off is byte-identical" begin
    base = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel; objective = MinVolume())
    @test base.status == MOI.OPTIMAL

    off = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
                            objective = MinVolume(), coupling = nothing)
    @test off.section_indices == base.section_indices
    @test off.objective_value == base.objective_value
end

@testset "capacity coupling: a design-dependent load forces an upsize" begin
    base = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel; objective = MinVolume())
    m = base.section_indices[1]      # lightest feasible section for each group

    # Group 2 must carry a load equal to group 1's chosen-section "weight" (here its
    # area), and each section's capacity against that load is HALF its area. So the
    # chosen section for group 2 needs area ≥ 2× group 1's area — a strict upsize that
    # is impossible without the coupling. Group 1 is unconstrained and stays at `m`.
    weight = Vector{Vector{Float64}}(undef, 2)
    weight[1] = copy(_A)             # group 1 contributes its own area as "load"
    weight[2] = Float64[]            # group 2 is in no one's source list
    coupling = LinearCapacityCoupling(
        [2],                         # constrain group 2
        [[1]],                       # whose load comes from group 1
        [0.0],                       # no x-independent base load
        weight,
        [0.5 .* _A],                 # section s capacity for group 2 = 0.5·area(s)
    )

    res = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
                            objective = MinVolume(), coupling = coupling)
    @test res.status == MOI.OPTIMAL

    c1, c2 = res.section_indices
    @test c1 == m                                   # group 1 untouched by the coupling
    @test _A[c2] ≥ 2 * _A[c1] - 1e-12               # coupling forced the upsize
    @test weight[1][c1] ≤ 0.5 * _A[c2] + 1e-9       # the chosen section satisfies the constraint

    # Optimality: group 2 is the LIGHTEST feasible section meeting the constraint.
    load = weight[1][c1]
    lightest_ok = Inf
    cache = create_cache(_CHK, _N)
    precompute_capacities!(_CHK, cache, _CAT, A992_Steel, MinVolume())
    for s in 1:_N          # group 2's length is constant, so compare bare coefficients
        is_feasible(_CHK, cache, s, _CAT[s], A992_Steel, _DEM[2], _GEO[2]) || continue
        load ≤ 0.5 * _A[s] + 1e-9 || continue
        lightest_ok = min(lightest_ok, get_objective_coeff(_CHK, cache, s))
    end
    @test get_objective_coeff(_CHK, cache, c2) ≈ lightest_ok rtol = 1e-9
end

@testset "capacity coupling: an impossible load is infeasible, never unsafe" begin
    # No section has capacity for a load larger than 0.5·max(area): the coupled MILP
    # must report infeasibility rather than silently returning an under-capacity size.
    weight = Vector{Vector{Float64}}(undef, 2)
    weight[1] = fill(1.0e9, _N)      # group 1 contributes a load far beyond any capacity
    weight[2] = Float64[]
    coupling = LinearCapacityCoupling([2], [[1]], [0.0], weight, [0.5 .* _A])

    res = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
                            objective = MinVolume(), coupling = coupling)
    @test res.status != MOI.OPTIMAL          # INFEASIBLE / INFEASIBLE_OR_UNBOUNDED
    @test isempty(res.section_indices)       # graceful empty result, not a crash
end

@testset "capacity coupling: works with a section-count cap (n_max_sections)" begin
    # Coupling is an EXACT in-MILP constraint (not a pre-screen), so unlike the
    # `feasible` mask it is safe to combine with the group-coupling section cap. The
    # coupling forces two distinct sections here (group 2 must be ≥ 2× group 1's
    # area), so the cap must allow at least 2.
    weight = Vector{Vector{Float64}}(undef, 2)
    weight[1] = copy(_A)
    weight[2] = Float64[]
    coupling = LinearCapacityCoupling([2], [[1]], [0.0], weight, [0.5 .* _A])

    res = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
                            objective = MinVolume(), n_max_sections = 2, coupling = coupling)
    @test res.status == MOI.OPTIMAL
    @test length(unique(res.section_indices)) ≤ 2          # cap honored
    @test _A[res.section_indices[2]] ≥ 2 * _A[res.section_indices[1]] - 1e-12  # coupling honored
end

@testset "capacity coupling: dimension validation" begin
    # Mismatched aligned lengths (groups vs base).
    @test_throws ArgumentError optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
        coupling = LinearCapacityCoupling([2], [[1]], Float64[], [copy(_A), Float64[]], [0.5 .* _A]))
    # weight not one-per-group.
    @test_throws ArgumentError optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
        coupling = LinearCapacityCoupling([2], [[1]], [0.0], [copy(_A)], [0.5 .* _A]))
    # cap row not spanning the catalog.
    @test_throws ArgumentError optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
        coupling = LinearCapacityCoupling([2], [[1]], [0.0], [copy(_A), Float64[]], [[0.5]]))
    # out-of-range source group.
    @test_throws ArgumentError optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
        coupling = LinearCapacityCoupling([2], [[99]], [0.0], [copy(_A), Float64[]], [0.5 .* _A]))
end
