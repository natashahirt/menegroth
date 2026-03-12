# Custom / Shaped Slab

> ```julia
> using StructuralSizer
> slab = ShapedSlab(tapered_slab_fn)
> result = _size_span_floor(slab, 8.0u"m", 0.5u"kPa", 2.4u"kPa"; span_y=6.0u"m")
> result.volume_per_area   # concrete volume per plan area
> result.custom            # Dict of user-defined metadata
> ```

## Overview

The `ShapedSlab` type provides an escape hatch for user-defined slab geometries
that fall outside the standard type hierarchy.  The user supplies a `sizing_fn`
that takes span, load, and material inputs and returns a `ShapedSlabResult` with
volume, self-weight, and optional thickness function.

Two example sizing functions are provided: `tapered_slab_fn` (thick edges,
thin center) and `coffered_slab_fn` (ribs with voids).

**Source:** `StructuralSizer/src/slabs/codes/custom/shaped.jl`

## Key Types

See `ShapedSlab` and `ShapedSlabResult` in
[Slab Types & Options](../types.md).

## Functions

- `tapered_slab_fn(span_x, span_y, load, material)` — example sizing function for a slab that is thicker at edges and thinner at center. Returns a `ShapedSlabResult`.
- `coffered_slab_fn(span_x, span_y, load, material)` — example sizing function for a coffered slab with orthogonal ribs and voids. Returns a `ShapedSlabResult`.

## Implementation Details

### ShapedSlab Dispatch

The `ShapedSlab` struct carries a `sizing_fn::Function` field.  When
`_size_span_floor(slab::ShapedSlab, ...)` is called, it delegates to:

```julia
slab.sizing_fn(span_x, span_y, load, material) → ShapedSlabResult
```

The `ShapedSlabResult` stores:
- `volume_per_area`: Concrete (or other material) volume per plan area
- `self_weight`: Self-weight pressure
- `thickness_fn`: Optional `(x, y) → h(x, y)` for visualization
- `custom`: `Dict{Symbol, Any}` for arbitrary metadata

The spanning behavior defaults to `TwoWaySpanning()`, and `required_materials`
returns an empty tuple—the user must manage material tracking.

### Example Functions

**`tapered_slab_fn`**: Computes a slab that is thicker at the edges (support
zones) and thinner at the center (midspan).  The volume is computed by
integrating the linear taper profile.

**`coffered_slab_fn`**: Models a coffered slab with orthogonal ribs.  Parameters
`rib_spacing` and `rib_width` control the grid.  Volume accounts for the void
fraction between ribs.

## Options & Configuration

No dedicated options struct exists for `ShapedSlab`.  All configuration is
embedded in the user's `sizing_fn`.  The function receives:

| Parameter | Type | Description |
|:----------|:-----|:------------|
| `span_x` | `Length` | Span in the x-direction |
| `span_y` | `Length` | Span in the y-direction |
| `load` | `Pressure` | Total factored load |
| `material` | `ConcreteMaterial` | Material properties |

## Limitations & Future Work

- No internal validation is performed on the `ShapedSlabResult` returned by the
  user's function—incorrect values propagate silently.
- The `thickness_fn` is purely for visualization; it is not used in any
  structural calculation.
- Fire rating adjustments are not applied to shaped slabs.
- Load distribution for `ShapedSlab` defaults to `DISTRIBUTION_CUSTOM`, which
  requires the caller to handle tributary area computation manually.
