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

# -----------------------------------------------------------------------------
# LinearSelectionConstraint: a global linear limit over the selection binaries.
# The headline use is DRIFT: for a lateral system under a fixed force
# distribution, the drift is Σ_e γ_e/I_e, so each candidate section t contributes
# a constant γ_e/I_t — a LINEAR term in x[e,t]. Folding `δ ≤ δ_allow` into the MILP
# sizes every group for strength AND drift jointly, per-group optimal, in ONE
# certified solve (replacing the uniform grow-only drift jump loop).
# -----------------------------------------------------------------------------

const _IX = [ustrip(u"m^4", Ix(s)) for s in _CAT]   # strong-axis I per catalog section

@testset "linear constraint: flag-off is byte-identical" begin
    base = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel; objective = MinVolume())
    off  = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
                             objective = MinVolume(), linear_constraints = nothing)
    @test off.section_indices == base.section_indices
    @test off.objective_value == base.objective_value
end

@testset "linear (drift) constraint: single group picks the lightest stiff-enough section" begin
    # One cantilever group. Drift δ = Γ/I_chosen ≤ δ_allow ⇒ I_chosen ≥ Γ/δ_allow.
    # The MILP must pick the LIGHTEST feasible section meeting that stiffness floor.
    dem = [MemberDemand(1; Mux = 50.0e3)]
    geo = [SteelMemberGeometry(4.0; Lb = 4.0)]

    base = optimize_discrete(_CHK, dem, geo, _CAT, A992_Steel; objective = MinVolume())
    m0 = base.section_indices[1]
    # Choose δ_allow so the stiffness floor lands well above the strength pick.
    Γ = 10.0                                   # drift "participation" (γ·?) in SI
    I_needed = 3 * _IX[m0]                      # demand 3× the strength pick's stiffness
    δ_allow = Γ / I_needed
    coeff = [[Γ / _IX[s] for s in 1:_N]]       # coeff[group][section] = Γ/I_t

    res = optimize_discrete(_CHK, dem, geo, _CAT, A992_Steel; objective = MinVolume(),
        linear_constraints = [LinearSelectionConstraint(coeff, :leq, δ_allow)])
    @test res.status == MOI.OPTIMAL
    c = res.section_indices[1]
    @test _IX[c] ≥ I_needed - 1e-12                         # drift limit met
    @test coeff[1][c] ≤ δ_allow + 1e-12

    # Optimality: the lightest feasible section with I ≥ I_needed.
    cache = create_cache(_CHK, _N)
    precompute_capacities!(_CHK, cache, _CAT, A992_Steel, MinVolume())
    best = Inf
    for s in 1:_N
        is_feasible(_CHK, cache, s, _CAT[s], A992_Steel, dem[1], geo[1]) || continue
        _IX[s] ≥ I_needed || continue
        best = min(best, get_objective_coeff(_CHK, cache, s))
    end
    @test get_objective_coeff(_CHK, cache, c) ≈ best rtol = 1e-9
end

@testset "linear (drift) constraint: per-group allocation beats uniform scaling" begin
    # Two cantilever groups with DIFFERENT participation: group 1 contributes far
    # more drift per unit stiffness than group 2. The optimal response puts most of
    # the added material in group 1 (where γ/weight is highest) — strictly lighter
    # than the uniform jump loop, which scales both groups to the same stiff section.
    dem = [MemberDemand(1; Mux = 50.0e3), MemberDemand(2; Mux = 50.0e3)]
    geo = [SteelMemberGeometry(4.0; Lb = 4.0), SteelMemberGeometry(4.0; Lb = 4.0)]
    base = optimize_discrete(_CHK, dem, geo, _CAT, A992_Steel; objective = MinVolume())
    m1, m2 = base.section_indices
    Γ1, Γ2 = 20.0, 1.0                          # group 1 dominates the drift
    δ_now = Γ1 / _IX[m1] + Γ2 / _IX[m2]
    δ_allow = δ_now / 3                         # require a 3× drift reduction
    coeff = [[Γ1 / _IX[s] for s in 1:_N], [Γ2 / _IX[s] for s in 1:_N]]

    res = optimize_discrete(_CHK, dem, geo, _CAT, A992_Steel; objective = MinVolume(),
        linear_constraints = [LinearSelectionConstraint(coeff, :leq, δ_allow)])
    @test res.status == MOI.OPTIMAL
    c1, c2 = res.section_indices
    @test Γ1 / _IX[c1] + Γ2 / _IX[c2] ≤ δ_allow + 1e-12    # drift met
    @test res.objective_value ≥ base.objective_value - 1e-9 # adding drift can only add weight
    @test _IX[c1] > _IX[m1]                                 # group 1 (dominant) stiffened

    # Uniform baseline: force BOTH groups to the lightest single section meeting the
    # whole limit alone. The per-group optimum must be ≤ that.
    uni = Inf
    for s in 1:_N
        (Γ1 + Γ2) / _IX[s] ≤ δ_allow || continue
        uni = min(uni, _A[s])
    end
    @test !isinf(uni)
    @test _A[c1] + _A[c2] ≤ 2 * uni + 1e-9                  # per-group ≤ uniform
end

@testset "linear constraint: :geq sense and n_max + infeasible" begin
    dem = [MemberDemand(1; Mux = 50.0e3)]
    geo = [SteelMemberGeometry(4.0; Lb = 4.0)]
    # :geq — require the chosen section's area to be at least some floor.
    area_floor = 3 * minimum(_A)
    cgeq = [LinearSelectionConstraint([copy(_A)], :geq, area_floor)]
    rgeq = optimize_discrete(_CHK, dem, geo, _CAT, A992_Steel; objective = MinVolume(),
                             linear_constraints = cgeq)
    @test rgeq.status == MOI.OPTIMAL
    @test _A[rgeq.section_indices[1]] ≥ area_floor - 1e-12

    # Works with a section cap.
    rcap = optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel; objective = MinVolume(),
        n_max_sections = 1,
        linear_constraints = [LinearSelectionConstraint([copy(_A), copy(_A)], :geq, area_floor)])
    @test rcap.status == MOI.OPTIMAL
    @test length(unique(rcap.section_indices)) ≤ 1

    # Impossible drift limit ⇒ graceful empty result, not a crash.
    tiny = [LinearSelectionConstraint([[1.0 / _IX[s] for s in 1:_N]], :leq, 1e-30)]
    rinf = optimize_discrete(_CHK, dem, geo, _CAT, A992_Steel; objective = MinVolume(),
                             linear_constraints = tiny)
    @test rinf.status != MOI.OPTIMAL
    @test isempty(rinf.section_indices)
end

@testset "linear constraint: dimension/sense validation" begin
    # coeff not one-per-group.
    @test_throws ArgumentError optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
        linear_constraints = [LinearSelectionConstraint([copy(_A)], :leq, 1.0)])
    # coeff row not spanning the catalog.
    @test_throws ArgumentError optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
        linear_constraints = [LinearSelectionConstraint([copy(_A), [1.0]], :leq, 1.0)])
    # unknown sense.
    @test_throws ArgumentError optimize_discrete(_CHK, _DEM, _GEO, _CAT, A992_Steel;
        linear_constraints = [LinearSelectionConstraint([copy(_A), copy(_A)], :eq, 1.0)])
end
