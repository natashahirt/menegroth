# IS Code Foundation Design

> ```julia
> using StructuralSizer
> using Unitful
> concrete = NWC_4000
> rebar = Rebar_60
> demand = FoundationDemand(1; Pu=200u"kN", c1=300u"mm", c2=300u"mm")
> result = design_footing(SpreadFooting(), demand, stiff_clay, concrete, rebar;
>             pier_width=300u"mm")
> footprint_area(result)
> ```

## Overview

The Indian Standard (IS 456) foundation module provides spread footing design
using limit state principles adapted from IS 456 and SP-16.  The implementation
follows ACI 318 structural provisions for flexure and shear while using IS-style
checks for bearing and punching.

**Source:** `StructuralSizer/src/foundations/codes/is/`

## Key Types

See [Foundation Types & Options](../types.md) for `SpreadFooting` and
`SpreadFootingResult` type documentation.
Soil presets and the `Soil` type are documented on [Foundation Types & Options](../types.md).

## Functions

### Design

`design_footing(::SpreadFooting, ...)` is the main entry point for IS spread
footing design.  See [ACI Foundation Design](aci.md) for the shared
`design_footing` docstring.

`check_spread_footing` re-evaluates bearing and punching checks on an existing
result (see [Post-Design Check](#post-design-check) below for details).

## Implementation Details

### IS Spread Footing Design

The `design_footing(::SpreadFooting, demand, soil, concrete, rebar; ...)` workflow:

1. **Bearing sizing** (IS 456 §34.1 / §34.4): size from factored load with a safety factor:

```math
A_{\mathrm{req}} = \frac{P_u \, \mathrm{SF}}{q_a}, \qquad B = \sqrt{A_{\mathrm{req}}}
```

2. **Punching shear**: nominal shear stress capacity \(\tau_c \approx 0.25\sqrt{f'_c}\) at the critical section \(d/2\) from the column face.
3. **One-way (beam) shear**: \(\tau_{\text{beam}} \approx 0.17\sqrt{f'_c}\) at a section located \(d\) from the column face.
4. **Flexure**: Cantilever moment at column face; standard reinforcement calculation
5. **Minimum steel**: Per IS 456 provisions

### Post-Design Check

`check_spread_footing(result, demand, soil, concrete; SF, ϕ_shear)` re-evaluates
bearing and punching checks on an existing result, useful for verification or
when loads change.

### Differences from ACI

| Aspect | ACI 318 | IS 456 |
|:-------|:--------|:-------|
| Punching capacity | Three-equation minimum | ``0.25\sqrt{f'_c}`` simplified |
| Beam shear | ``2\lambda\sqrt{f'_c}`` | ``0.17\sqrt{f'_c}`` |
| Partial safety factors | ``\phi`` factors | Load factors on demand side |

## Options & Configuration

The IS footing design accepts keyword arguments rather than an options struct:

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `pier_width` | 0.3 m | Column/pier width |
| `rebar_dia` | 16 mm | Rebar diameter |
| `cover` | 75 mm | Clear cover |
| `SF` | 1.5 | Bearing safety factor |
| `ϕ_flexure` | 0.9 | Flexure strength reduction |
| `ϕ_shear` | 0.75 | Shear strength reduction |
| `min_depth` | 300 mm | Minimum footing depth |

## Limitations & Future Work

- Only spread footings are implemented for IS code; strip and mat foundations
  use the ACI module.
- IS 456 provisions for combined footings and raft foundations are not
  implemented.
- Seismic detailing per IS 13920 is not included.
- The implementation uses ACI-style Whitney stress block rather than the IS 456
  parabolic-rectangular stress block—results are slightly conservative.
