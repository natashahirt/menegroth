"""
    AbstractObjective

Abstract base type for optimization objective functions.

Each subtype defines a scalar quantity to minimize during member sizing.
Subtypes: [`MinWeight`](@ref), [`MinVolume`](@ref), [`MinCost`](@ref), [`MinCarbon`](@ref).
"""
abstract type AbstractObjective end

"""Minimize total member weight: A × L × ρ"""
struct MinWeight <: AbstractObjective end

"""Minimize total member volume: A × L"""
struct MinVolume <: AbstractObjective end

"""
Minimize total cost.

- `MinCost()` — uses `material.cost` [USD/kg] (errors if cost=NaN)
- `MinCost(c::Real)` — explicit unit cost [USD/kg]
- `MinCost(f::Function)` — custom cost function `f(section, material) -> cost_per_length`
"""
struct MinCost{T} <: AbstractObjective
    unit_cost::T
end
"""Construct a `MinCost` with an explicit unit cost (USD/kg)."""
MinCost(c::Real) = MinCost{typeof(c)}(c)

"""Construct a `MinCost` that uses the material's built-in cost field."""
MinCost() = MinCost(NaN)

"""Minimize embodied carbon: A × L × ρ × ecc"""
struct MinCarbon <: AbstractObjective end

"""
    ParetoScalarization(o1, o2, w, ref1, ref2) <: AbstractObjective

Weighted-sum scalarization of two objectives, for tracing a Pareto front by
continuation. Minimises the DIMENSIONLESS convex combination

    w · (o1 / ref1)  +  (1 − w) · (o2 / ref2),    w ∈ [0, 1]

where `ref1`, `ref2` are fixed positive reference quantities carrying the same
units as `o1`, `o2` respectively. They render each term dimensionless and O(1) so
two incommensurable metrics — e.g. structural volume (m³) and embodied carbon
(kgCO₂e) — can be combined on one axis. Sweeping `w` from 1 → 0 walks the
*supported* Pareto points from the `o1`-optimum to the `o2`-optimum; setting each
`ref` to the corresponding single-objective optimum normalises both anchors to 1.

Because it delegates to each component's own [`objective_value`](@ref), it
inherits their exact semantics — including the RC concrete/rebar carbon split —
and works unchanged under every checker whose cache precomputes `objective_value`
(AISC steel, ACI columns/beams). Precompute keyword args (`rebar`, `transverse`)
are forwarded verbatim to the components, so the RC path is handled correctly.
"""
struct ParetoScalarization{O1<:AbstractObjective, O2<:AbstractObjective, R1, R2} <: AbstractObjective
    o1::O1
    o2::O2
    w::Float64
    ref1::R1
    ref2::R2
    function ParetoScalarization(o1::AbstractObjective, o2::AbstractObjective,
                                 w::Real, ref1, ref2)
        0 ≤ w ≤ 1 || throw(ArgumentError("ParetoScalarization: w must be in [0,1]; got $w."))
        (ustrip(ref1) > 0 && ustrip(ref2) > 0) ||
            throw(ArgumentError("ParetoScalarization: ref1 and ref2 must be positive."))
        new{typeof(o1), typeof(o2), typeof(ref1), typeof(ref2)}(o1, o2, Float64(w), ref1, ref2)
    end
end

"""
    objective_value(obj::AbstractObjective, section, material, L) -> Unitful.Quantity

Compute the objective function value for a single section of length `L`. The
return is always a typed quantity (`kg` for [`MinWeight`](@ref), `m^3` for
[`MinVolume`](@ref), unit-cost × kg for [`MinCost`](@ref), `kgCO2e` for
[`MinCarbon`](@ref)); callers strip units at the solver / API boundary.
"""
function objective_value end

"""Objective value for MinWeight: A × L × ρ, with A from [`self_weight_area`](@ref)."""
function objective_value(::MinWeight, s::AbstractSection, mat::AbstractMaterial, L)
    self_weight_area(s) * L * mat.ρ
end

"""Objective value for MinVolume (without material): A × L."""
function objective_value(::MinVolume, s::AbstractSection, L)
    self_weight_area(s) * L
end

"""Objective value for MinVolume (material ignored): A × L."""
objective_value(::MinVolume, s::AbstractSection, ::AbstractMaterial, L) = objective_value(MinVolume(), s, L)

"""Objective value for MinCost with a numeric unit cost: A × L × ρ × cost."""
function objective_value(obj::MinCost{<:Real}, s::AbstractSection, mat::AbstractMaterial, L)
    cost = isnan(obj.unit_cost) ? mat.cost : obj.unit_cost
    isnan(cost) && error("MinCost requires material.cost to be set (material has cost=NaN). " *
                         "Either set cost on your material or use MinCost(unit_cost_per_kg).")
    self_weight_area(s) * L * mat.ρ * cost
end

"""Objective value for MinCost with a custom function: f(section, material) × L."""
function objective_value(obj::MinCost{<:Function}, s::AbstractSection, mat::AbstractMaterial, L)
    obj.unit_cost(s, mat) * L
end

"""Objective value for MinCarbon: A × L × ρ × ecc."""
function objective_value(::MinCarbon, s::AbstractSection, mat::AbstractMaterial, L)
    self_weight_area(s) * L * mat.ρ * mat.ecc
end

"""
Objective value for a [`ParetoScalarization`](@ref): the dimensionless weighted
sum `w·(o1/ref1) + (1−w)·(o2/ref2)`. Delegates to each component's
`objective_value`, forwarding any precompute keyword args (`rebar`, `transverse`)
so the RC concrete/rebar split is applied correctly. Each `vᵢ/refᵢ` must be
dimensionless (matching units), which `ustrip(NoUnits, …)` enforces.
"""
function objective_value(obj::ParetoScalarization, s::AbstractSection,
                         mat::AbstractMaterial, L; kwargs...)
    v1 = objective_value(obj.o1, s, mat, L; kwargs...)
    v2 = objective_value(obj.o2, s, mat, L; kwargs...)
    return obj.w * ustrip(Unitful.NoUnits, v1 / obj.ref1) +
           (1 - obj.w) * ustrip(Unitful.NoUnits, v2 / obj.ref2)
end

"""
Concrete, longitudinal steel, and ties or stirrups of one RC section.

`As` is the longitudinal area. Ties and stirrups come from
[`transverse_steel_per_length`](@ref) on `section` and replace concrete as
well. Weight is kilograms for every RC section. `MinCost` stays the gross
volume and does not come through here.
"""
function _rc_objective(obj::AbstractObjective, Ag, As, concrete, rebar, transverse, L, section)
    As_tr = transverse_steel_per_length(section, concrete, transverse)
    Ac = Ag - As - As_tr
    Ac < zero(Ac) && (Ac = zero(Ac))
    mc = uconvert(u"kg", Ac * L * concrete.ρ)
    ml = uconvert(u"kg", As * L * rebar.ρ)
    mt = uconvert(u"kg", As_tr * L * transverse.ρ)
    if obj isa MinWeight
        return mc + ml + mt
    elseif obj isa MinCarbon
        return uconvert(u"kgCO2e", mc * concrete.ecc + ml * rebar.ecc + mt * transverse.ecc)
    else
        error("$(typeof(obj)) has no rebar split")
    end
end

"""
    total_objective(obj, sections, materials, lengths) -> Unitful.Quantity

Sum of [`objective_value`](@ref) over all member groups (one material per
group). Returns the same typed quantity that the underlying `objective_value`
produces (`kg`, `m^3`, USD, or `kgCO2e`).
"""
function total_objective(obj::AbstractObjective, sections, materials, lengths)
    sum(objective_value(obj, s, m, L) for (s, m, L) in zip(sections, materials, lengths))
end

"""
    total_objective(obj, sections, mat::AbstractMaterial, lengths) -> Unitful.Quantity

Sum of [`objective_value`](@ref) over all member groups sharing a single
material.
"""
function total_objective(obj::AbstractObjective, sections, mat::AbstractMaterial, lengths)
    sum(objective_value(obj, s, mat, L) for (s, L) in zip(sections, lengths))
end
