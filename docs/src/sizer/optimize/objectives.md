# Optimization Objectives

> ```julia
> using StructuralSizer
> obj = MinCarbon()
> val = objective_value(obj, section, material, length)
> total = total_objective(obj, sections, materials, lengths)
> ```

## Overview

The objectives module defines what the optimizer minimizes.  Four objectives are
provided, all implementing the `AbstractObjective` interface:

- **MinWeight**: Minimize total structural weight (default)
- **MinVolume**: Minimize total material volume
- **MinCost**: Minimize estimated material cost
- **MinCarbon**: Minimize embodied carbon (kgCO₂e)

Objectives are used by both the MIP discrete solver and the NLP continuous
solver to compute per-section coefficients and total objective values.

**Source:** `StructuralSizer/src/optimize/core/objectives.jl`

## Key Types

```@docs
AbstractObjective
MinWeight
MinVolume
MinCost
MinCarbon
```

## Functions

```@docs
objective_value
total_objective
```

## Implementation Details

### Objective Value Computation

`objective_value(obj, section, material, length)` computes the contribution of
a single member to the total objective:

| Objective | Formula |
|:----------|:--------|
| `MinWeight` | \( \rho \cdot A \cdot L \) |
| `MinVolume` | \( A \cdot L \) |
| `MinCost` | \( \text{unit\_cost} \cdot \rho \cdot A \cdot L \) |
| `MinCarbon` | \( \text{GWP} \cdot \rho \cdot A \cdot L \) |

where ``\rho`` is the material density, ``A`` is the section area, ``L`` is the
member length, and GWP is the Global Warming Potential (kgCO₂e per kg).

An overload `objective_value(obj, section, length)` omits the material argument
and uses the section's built-in material properties (for catalog sections with
embedded material data).

### Total Objective

`total_objective(obj, sections, materials, lengths)` sums `objective_value`
across all members:

```math
Z = \sum_{i=1}^{n} \text{objective\_value}(\text{obj}, s_i, m_i, L_i)
```

This is used by the MIP solver to set the linear objective coefficients and by
the NLP solver's `_convert_objective` to map raw volumes to the chosen metric.

### Integration with Solvers

In the MIP formulation, `precompute_capacities!` calls `objective_value` for
each candidate section to set the cost vector.  The solver then minimizes the
linear objective ``\sum_j c_j x_{ij}``.

In the NLP formulation, the raw output of `objective_fn(problem, x)` is
typically a volume, which `_convert_objective` maps to the selected objective
type using the problem's material properties.

## Options & Configuration

Objectives are zero-configuration singleton types.  Material cost and carbon
intensity are stored on the material objects, not on the objective:

| Property | Stored on | Description |
|:---------|:----------|:------------|
| Density ``\rho`` | Material | kg/m³ |
| Unit cost | Material | \$/kg or \$/m³ |
| GWP | Material | kgCO₂e/kg |

## Limitations & Future Work

- **MinCost** uses simplified unit material costs; fabrication, erection, and
  connection costs are not included.
- **MinCarbon** uses cradle-to-gate (A1–A3) embodied carbon only; transportation,
  construction, end-of-life, and biogenic carbon are not modeled.
- Multi-objective optimization (e.g., Pareto front of cost vs. carbon) is not
  supported; the user must run separate optimizations and compare.
- The objective interface assumes a single material per member; composite
  members (e.g., concrete-filled HSS) require custom handling.
- Life-cycle cost optimization (including maintenance, replacement, demolition)
  is planned as a future extension.
