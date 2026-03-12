# Timber Floor Systems

> ```julia
> using StructuralSizer
> result = _size_span_floor(CLT(), 5.0u"m", 0.5u"kPa", 2.4u"kPa";
>                     fire_rating=1)
> total_depth(result)   # panel depth
> self_weight(result)   # kN/m²
> ```

## Overview

The timber floor module covers four mass timber and engineered wood systems:

- **CLT** (Cross-Laminated Timber): Alternating-grain panel with effective
  section properties from layup.
- **DLT** (Dowel-Laminated Timber): Solid timber planks connected with hardwood
  dowels.
- **NLT** (Nail-Laminated Timber): Dimension lumber laminated with nails.
- **MassTimberJoist**: Traditional timber joist with subfloor panel.

All types inherit from `AbstractTimberFloor` and carry `OneWaySpanning`
behavior.

**Source:** `StructuralSizer/src/slabs/codes/timber/`

## Key Types

See `CLT`, `DLT`, `NLT`,
`MassTimberJoist`, `AbstractTimberFloor`,
`TimberPanelResult`, and `TimberJoistResult` in
[Slab Types & Options](../types.md).

## Functions

`_size_span_floor(slab_type, ...)` — internal dispatch for simplified timber floor sizing by panel/joist type (currently stubs).

## Implementation Details

### CLT (Cross-Laminated Timber)

CLT panels consist of alternating orthogonal layers of lumber.  Effective
section properties (EI, GA) are computed using the Gamma method or the
Timoshenko beam analog, accounting for rolling shear between layers.

The `TimberPanelResult` stores panel ID, depth, ply count, and timber volume
per plan area.

### DLT (Dowel-Laminated Timber)

DLT panels are mechanically laminated using hardwood dowels without adhesive.
The sizing approach is similar to CLT but with different interlayer connection
stiffness.

### NLT (Nail-Laminated Timber)

NLT uses dimension lumber (2×, 3×) laminated on edge with nails.  The
`lumber_size` parameter selects the member dimension.  Effective properties
account for partial composite action between laminations.

### MassTimberJoist

A traditional joist system with discrete timber joists and a subfloor panel
(plywood, OSB, or CLT).  The `TimberJoistResult` stores joist size, spacing,
deck type, and total system depth.

## Options & Configuration

See `TimberOptions` in [Slab Types & Options](../types.md).

Common parameters:

| Parameter | Description |
|:----------|:------------|
| `fire_rating` | Required fire rating (hours), affects char depth deduction |
| `material` | Timber species/grade properties |
| `lumber_size` | NLT lamination size (e.g., "2x10") |
| `spacing` | Joist spacing for `MassTimberJoist` |
| `deck_type` | Subfloor panel type for `MassTimberJoist` |

Fire design reduces the effective section by a char depth calculated from the
NDS/CSA O86 charring rate for the specified fire rating.

## Limitations & Future Work

- All four timber sizing functions are **stubs** that raise "not yet implemented"
  errors.
- Planned: PRG 320 CLT layup catalog, NDS reference design values, vibration
  check per ATC Design Guide 1.
- DLT rolling shear check per manufacturer-specific approval data.
- Fire design currently uses simplified charring rates; a full effective
  cross-section method is planned.
- Acoustic performance (STC/IIC ratings) is not evaluated.
