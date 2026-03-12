# Hollow Core Precast

> ```julia
> using StructuralSizer
> ft = HollowCore()
> spanning_behavior(ft)       # OneWaySpanning()
> load_distribution(ft)       # DISTRIBUTION_ONE_WAY
> floor_symbol(ft)            # :hollow_core
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

No hollow-core-specific public sizing function is exported yet. Hollow-core slabs are reached via the structure-level APIs (`size_slab!` / `size_slabs!`) and currently remain stub implementations.

## Implementation Details

The internal hollow-core sizing path is currently a **stub** that raises a
"not yet implemented" error. The planned implementation will:

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
| `material` | `Concrete` | Concrete properties |
| `fire_rating` | `Int` | Required fire rating (hours) |

## Limitations & Future Work

- **Not yet implemented.** The current function is a placeholder stub.
- Planned: PCI span table lookup, composite topping design, camber calculation,
  and connection detailing.
- Diaphragm action and lateral load transfer through keyway grouting are not
  modeled.

## References

- `StructuralSizer/src/slabs/codes/concrete/hollow_core.jl`
