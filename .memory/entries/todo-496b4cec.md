---
id: todo-496b4cec
type: todo
project: menegroth
parent_id: todo-5b438560
title: 'One-way slab analysis hierarchy: ACI coefficients / elastic strip / FEA (mirrors
  DDM / EFM / FEA)'
node_label: 'One-way methods: coef / strip / FEA'
tags: todo,one-way,slab,aci-318-11,analysis-method,deferred
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/types/analysis_methods.jl@9b0208b, StructuralSizer/src/slabs/options.jl@9b0208b,
  StructuralSizer/src/slabs/sizing.jl@9b0208b, StructuralSizer/src/slabs/codes/concrete/min_thickness.jl@9b0208b
session_id: sess-4d9a7f4b
created_at: '2026-10-31T13:13:26.715664+00:00'
updated_at: '2026-10-31T13:13:26.715664+00:00'
has_child_rationale: Design for the analysis-method layer of the one-way slab pipeline
---
Deferred by the user (2026-10-31). Design agreed in chat: one-way slab analysis should mirror the flat-plate DDM / EFM / FEA layering.

## Context
Framing integration tests fail with `no floor-design implementation for OneWay`, because `_size_slab!(::OneWay, ...)` falls through to the `UnsupportedFloorSystemError` fallback in `StructuralSizer/src/slabs/sizing.jl`. `OneWayOptions` (in `slabs/options.jl`) has no `method` field yet. `min_thickness(::OneWay, ...)` (Table 9.5(a)) already exists.

## Method hierarchy (ACI 318-11, corpus `aci-318-11`)
| Two-way (existing) | One-way (proposed) | Basis |
|---|---|---|
| `DDM` | `Coefficients` | §8.3.3 (a)-(e), pages 112-113 |
| `EFM` | `ElasticStrip` | §8.3.1 elastic analysis + §8.11.2 live-load arrangements, pages 118-119 |
| `FEA` | `OneWayFEA` | §8.3.1 |

- **Coefficients:** limited to 2+ spans, adjacent spans within 20%, uniform load, unfactored L <= 3D, prismatic members. Needs end classification (discontinuous unrestrained / integral with support / continuous). Must fail in pre-sizing outside §8.3.3, like `PreSizingValidationError` does for DDM.
- **ElasticStrip:** unit-width continuous beam solved in Asap. Handles unequal spans and L > 3D. §8.11.2 live-load cases: (a) factored D on all spans + full factored L on two adjacent spans, (b) factored D on all spans + full factored L on alternate spans. Enables §8.4 redistribution (not permitted with approximate moments). Supports come from the real framing, which removes the need to infer continuity.
- **OneWayFEA:** reuse the flat-plate shell FEA (meshing, D/L split, `design_approach = :strip`), integrating along the span axis only. The transverse direction gets shrinkage and temperature steel.

## Structure
- New abstract `OneWayAnalysisMethod`, kept separate from `FlatPlateAnalysisMethod`. Add a `method` field to `OneWayOptions`.
- Every method returns the same per-span envelope: +M / -M at the critical sections, V at the support faces.
- Method-independent design and checks: Ch. 10 flexure (As per ft), §7.12 shrinkage/temperature steel, §7.6.5 / §10.6 spacing, §11.2 one-way shear, Table 9.5(a) minimum h or §9.5.2.2 computed deflection (reuse the existing effective-inertia code).

## Build order
1. Shared design layer + Coefficients, with hand-calc oracles.
2. ElasticStrip, cross-checked against Coefficients where §8.3.3 applies.
3. OneWayFEA, cross-checked against ElasticStrip.

## Open decision
Default method: `ElasticStrip` (general, takes supports from the model; agent's suggestion) vs `Coefficients` (cheap, like DDM is for flat plates).
