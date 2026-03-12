# Steel Floor Decks

> ```julia
> using StructuralSizer
> result = _size_span_floor(CompositeDeck(), 3.0u"m", 0.5u"kPa", 3.6u"kPa")
> total_depth(result)    # deck + fill
> self_weight(result)    # kN/m²
> ```

## Overview

The steel floor module covers three steel deck systems:

- **CompositeDeck**: Composite steel deck with concrete topping, where the
  profiled steel deck acts as permanent formwork and tensile reinforcement.
- **NonCompositeDeck**: Steel deck without composite action—deck resists
  construction loads only; concrete topping is structurally independent.
- **JoistRoofDeck**: Open-web steel joist roof system with metal deck.

Each type inherits from `AbstractSteelFloor` and carries `OneWaySpanning`
behavior.

**Source:** `StructuralSizer/src/slabs/codes/steel/`

## Key Types

See `CompositeDeck`, `NonCompositeDeck`,
`JoistRoofDeck`, `AbstractSteelFloor`,
`CompositeDeckResult`, and `JoistDeckResult` in
[Slab Types & Options](../types.md).

## Functions

`_size_span_floor(slab_type, ...)` — internal dispatch for simplified steel floor sizing by deck type (currently stubs).

## Implementation Details

### CompositeDeck

The composite deck system combines a profiled steel deck (typically 1.5", 2",
or 3" depth) with a concrete fill.  The total depth is deck depth + fill depth
(usually 2"–3.5" above the deck flutes).

Result fields include separate steel and concrete volumes:
- `steel_vol_per_area`: Deck steel volume per plan area
- `concrete_vol_per_area`: Concrete fill volume per plan area (accounting for
  flute geometry)

The `CompositeDeckResult` type stores deck profile, gauge, fill depth, and both
material volumes.

### NonCompositeDeck

Non-composite deck carries loads independently—the steel deck resists
construction-phase loads, while the concrete topping (if present) is designed
as a one-way slab spanning between supports.

### JoistRoofDeck

Open-web steel joists (SJI designations) with a metal roof deck.  The
`JoistDeckResult` stores joist designation, depth, spacing, and deck profile.

## Options & Configuration

See `CompositeDeckOptions` in [Slab Types & Options](../types.md).

Key parameters for composite deck design:

| Parameter | Description |
|:----------|:------------|
| `deck_profile` | Deck manufacturer profile (e.g., "2VLI20") |
| `deck_gauge` | Steel gauge (16, 18, 20, 22) |
| `fill_depth` | Concrete fill above deck flutes |
| `deck_mat` | Deck steel material properties |

## Limitations & Future Work

- All three steel floor sizing functions are **stubs** that raise "not yet
  implemented" errors.
- Planned: SDI composite deck tables, Vulcraft catalog lookup, composite beam
  interaction with deck.
- Joist roof deck: SJI load table lookup and joist girder selection.
- Diaphragm action for lateral load resistance is not modeled.
