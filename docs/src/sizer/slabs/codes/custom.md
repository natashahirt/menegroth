# Custom / Shaped Slab

> ```julia
> using StructuralSizer
> sizing_fn = (span_x, span_y, load, material) -> ShapedSlabResult(0.20u"m", 5.0u"kPa")
> slab = ShapedSlab(sizing_fn)
> spanning_behavior(slab)        # TwoWaySpanning()
> required_materials(slab)       # ()
> ```

## Overview

The `ShapedSlab` type provides an escape hatch for user-defined slab geometries
that fall outside the standard type hierarchy.  The user supplies a `sizing_fn`
that takes span, load, and material inputs and returns a `ShapedSlabResult` with
volume, self-weight, and optional thickness function.

Two internal example sizing functions are provided in source for reference:
`tapered_slab_fn` (thick edges, thin center) and `coffered_slab_fn`
(ribs with voids).

**Source:** `StructuralSizer/src/slabs/codes/custom/shaped.jl`

## Key Types

See `ShapedSlab` and `ShapedSlabResult` in
[Slab Types & Options](../types.md).

## Functions

- `ShapedSlab(sizing_fn)` — exported type constructor for custom slab behavior.
- `ShapedSlabResult(vol, sw)` — exported result constructor for custom slab output.

## Implementation Details

### ShapedSlab Dispatch

The `ShapedSlab` struct carries a `sizing_fn::Function` field. The internal
sizing dispatch delegates to:

```julia
slab.sizing_fn(span_x, span_y, load, material) -> ShapedSlabResult
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
| `material` | `AbstractMaterial` | Material properties passed through to `sizing_fn` |

## Limitations & Future Work

- No internal validation is performed on the `ShapedSlabResult` returned by the
  user's function—incorrect values propagate silently.
- The `thickness_fn` is purely for visualization; it is not used in any
  structural calculation.
- Fire rating adjustments are not applied to shaped slabs.
- Load distribution for `ShapedSlab` defaults to `DISTRIBUTION_CUSTOM`, which
  requires the caller to handle tributary area computation manually.
