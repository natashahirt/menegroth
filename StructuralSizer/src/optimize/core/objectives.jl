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
    objective_value(obj::AbstractObjective, section, material, L) -> Float64

Compute the objective function value for a single section of length `L`.
"""
function objective_value end

"""Objective value for MinWeight: A × L × ρ."""
function objective_value(::MinWeight, s::AbstractSection, mat::AbstractMaterial, L)
    section_area(s) * L * mat.ρ
end

"""Objective value for MinVolume (without material): A × L."""
function objective_value(::MinVolume, s::AbstractSection, L)
    section_area(s) * L
end

"""Objective value for MinVolume (material ignored): A × L."""
objective_value(::MinVolume, s::AbstractSection, ::AbstractMaterial, L) = objective_value(MinVolume(), s, L)

"""Objective value for MinCost with a numeric unit cost: A × L × ρ × cost."""
function objective_value(obj::MinCost{<:Real}, s::AbstractSection, mat::AbstractMaterial, L)
    cost = isnan(obj.unit_cost) ? mat.cost : obj.unit_cost
    isnan(cost) && error("MinCost requires material.cost to be set (material has cost=NaN). " *
                         "Either set cost on your material or use MinCost(unit_cost_per_kg).")
    section_area(s) * L * mat.ρ * cost
end

"""Objective value for MinCost with a custom function: f(section, material) × L."""
function objective_value(obj::MinCost{<:Function}, s::AbstractSection, mat::AbstractMaterial, L)
    obj.unit_cost(s, mat) * L
end

"""Objective value for MinCarbon: A × L × ρ × ecc."""
function objective_value(::MinCarbon, s::AbstractSection, mat::AbstractMaterial, L)
    section_area(s) * L * mat.ρ * mat.ecc
end

"""
    total_objective(obj, sections, materials, lengths) -> Float64

Sum of `objective_value` over all member groups (one material per group).
"""
function total_objective(obj::AbstractObjective, sections, materials, lengths)
    sum(objective_value(obj, s, m, L) for (s, m, L) in zip(sections, materials, lengths))
end

"""
    total_objective(obj, sections, mat::AbstractMaterial, lengths) -> Float64

Sum of `objective_value` over all member groups sharing a single material.
"""
function total_objective(obj::AbstractObjective, sections, mat::AbstractMaterial, lengths)
    sum(objective_value(obj, s, mat, L) for (s, L) in zip(sections, lengths))
end
