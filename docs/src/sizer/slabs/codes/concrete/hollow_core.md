# Hollow Core Precast

> ```julia
> using StructuralSizer
> result = _size_span_floor(HollowCore(), 10.0u"m", 0.5u"kPa", 2.4u"kPa";
>                     fire_rating=2)
> total_depth(result)   # plank depth
> self_weight(result)   # kN/m²
> ```

## Overview

Hollow core planks are precast, prestressed concrete elements with continuous
longitudinal voids to reduce self-weight.  The design approach selects a plank
profile from manufacturer span tables based on span, applied loads, and fire
rating requirements.

**Source:** `StructuralSizer/src/slabs/codes/concrete/hollow_core.jl`

## Key Types

`HollowCore` — precast, prestressed hollow core plank slab type.

See also `ProfileResult` in [Slab Types & Options](../../types.md).

## Functions

`_size_span_floor(::HollowCore, ...)` — entry point for hollow core slab sizing (currently a stub).

## Implementation Details

The `_size_span_floor(::HollowCore, ...)` entry point is currently a **stub**
that raises a "not yet implemented" error.  The planned implementation will:

1. Look up manufacturer span tables (PCI Hollow Core Slab Manual)
2. Select the lightest profile satisfying span, load, and fire rating
3. Return a `ProfileResult` with the selected profile's depth, void ratio,
   and self-weight

The `ProfileResult` type accounts for voids via its `volume_per_area` field,
which stores the effective concrete volume (less than the product of depth ×
area due to hollow cores).

## Options & Configuration

The sizing function accepts:

| Parameter | Type | Description |
|:----------|:-----|:------------|
| `span` | `Length` | Clear span |
| `sdl` | `Pressure` | Superimposed dead load |
| `live` | `Pressure` | Live load |
| `material` | `ConcreteMaterial` | Concrete properties |
| `fire_rating` | `Int` | Required fire rating (hours) |

## Limitations & Future Work

- **Not yet implemented.** The current function is a placeholder stub.
- Planned: PCI span table lookup, composite topping design, camber calculation,
  and connection detailing.
- Diaphragm action and lateral load transfer through keyway grouting are not
  modeled.
