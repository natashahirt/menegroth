# Load Combinations

> ```julia
> using StructuralSizer
> combo = strength_1_2D_1_6L
> p_u   = factored_pressure(combo, 100.0psf, 50.0psf)   # → 200 psf
> p_env = envelope_pressure(gravity_combinations, 100.0psf, 50.0psf)
> ```

## Overview

Load combinations apply factored loads to structural members per ASCE 7-22 §2.3.1 (strength design) and §2.4.1 (ASD). The `LoadCombination` type stores named factor sets for dead, live, roof live, snow, rain, wind, and earthquake loads. Standard combinations are provided as `const` instances; custom combinations can be created for non-US codes (e.g., Eurocode).

## Key Types

```@docs
LoadCombination
```

### Fields

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `name` | `Symbol` | `:strength` | Identifier |
| `D` | `Float64` | 1.2 | Dead load factor |
| `L` | `Float64` | 1.6 | Live load factor |
| `Lr` | `Float64` | 0.0 | Roof live load factor |
| `S` | `Float64` | 0.0 | Snow load factor |
| `R` | `Float64` | 0.0 | Rain load factor |
| `W` | `Float64` | 0.0 | Wind load factor |
| `E` | `Float64` | 0.0 | Earthquake load factor |

## Standard Combinations (ASCE 7-22 §2.3.1)

| Preset | Expression | D | L | Lr/S/R | W | E |
|:-------|:-----------|:--|:--|:-------|:--|:--|
| `strength_1_4D` | 1.4D | 1.4 | 0 | 0 | 0 | 0 |
| `strength_1_2D_1_6L` | 1.2D + 1.6L + 0.5(Lr/S/R) | 1.2 | 1.6 | 0.5 | 0 | 0 |
| `strength_1_2D_1_6Lr` | 1.2D + 1.6(Lr/S/R) + L | 1.2 | 1.0 | 1.6 | 0.5 | 0 |
| `strength_1_2D_1_0W` | 1.2D + 1.0W + L + 0.5(Lr/S/R) | 1.2 | 1.0 | 0.5 | 1.0 | 0 |
| `strength_1_2D_1_0E` | 1.2D + 1.0E + L + 0.2S | 1.2 | 1.0 | 0/0.2/0 | 0 | 1.0 |
| `strength_0_9D_1_0W` | 0.9D + 1.0W | 0.9 | 0 | 0 | 1.0 | 0 |
| `strength_0_9D_1_0E` | 0.9D + 1.0E | 0.9 | 0 | 0 | 0 | 1.0 |

| Preset | Expression | D | L | Notes |
|:-------|:-----------|:--|:--|:------|
| `ASD` | 1.0D + 1.0L | 1.0 | 1.0 | Allowable stress design |
| `service` | 1.0D + 1.0L | 1.0 | 1.0 | Serviceability (deflection) |

### Aliases

- `default_combo` = `strength_1_2D_1_6L` (most common gravity combination)

## Combination Sets

| Set | Contents | Use Case |
|:----|:---------|:---------|
| `asce7_strength_combinations` | All 7 ASCE 7-22 strength combos | Full envelope analysis |
| `gravity_combinations` | `strength_1_4D`, `strength_1_2D_1_6L`, `service` | Gravity-only design |

## Functions

```@docs
factored_pressure
factored_load
envelope_pressure
```

### factored\_pressure

Two-argument form (gravity only):

```julia
p_u = factored_pressure(combo, dead_load, live_load)
# Returns: combo.D × dead + combo.L × live
```

Keyword form (all load types):

```julia
p_u = factored_pressure(combo; D=5.0u"kN/m^2", L=3.0u"kN/m^2", W=1.5u"kN/m^2")
```

### factored\_load

Alias for `factored_pressure` — works identically, named for clarity when applying to forces or moments rather than pressures.

### envelope\_pressure

Takes a vector of combinations and returns the maximum factored value:

```julia
p_max = envelope_pressure(gravity_combinations, 100.0psf, 50.0psf)
# → max(1.4×100, 1.2×100+1.6×50, 1.0×100+1.0×50) = 200 psf
```

## Implementation Details

- **ASCE 7-22 §2.3.1**: All strength combinations follow the 2022 edition. The combination numbering (1–7) matches the standard. Combination 2 (`strength_1_2D_1_6L`) includes `Lr = S = R = 0.5` as companion loads, matching the standard's `0.5(Lr or S or R)` notation.
- **Gravity envelope**: `envelope_pressure` computes the scalar maximum across all combinations. This is correct for gravity-only analysis where all loads act downward. For lateral combinations (wind/seismic), directional analysis with separate positive/negative envelopes is needed.
- **Type stability**: `factored_pressure` preserves Unitful types through multiplication. The result has the same dimension as the input loads.
- **Custom combinations**: Non-US codes can be expressed directly:

```julia
eurocode_combo = LoadCombination(name=:EC0_6_10, D=1.35, L=1.5)
```

## Current Scope & Future Roadmap

### Gravity-Only Scope

The loads infrastructure currently handles **gravity loads** (dead, live, superimposed dead) through three components:

| File | Purpose |
|:-----|:--------|
| `combinations.jl` | `LoadCombination` struct, ASCE 7-22 presets, `factored_pressure` / `envelope_pressure` |
| `gravity.jl` | `GravityLoads` struct with occupancy presets (`office_loads`, `residential_loads`, …) |
| `pattern_loading.jl` | ACI 318 pattern load utilities (checkerboard, adjacent spans) |

`LoadCombination` already carries fields for all ASCE 7 load types (D, L, Lr, S, R, **W**, **E**), but the W and E factors are currently inert — no lateral load source exists yet to multiply them against.

### Expanding to Lateral Loads

When the implementation moves beyond gravity, the minimal path is:

1. **Define lateral load inputs** — Create a `LateralLoads` struct (or extend a broader `BuildingLoads` wrapper) and wire it into `DesignParameters` alongside `GravityLoads`.
2. **Apply lateral forces to the Asap model** — Add a function (e.g., `_apply_lateral_loads!`) in `StructuralSynthesizer/src/analyze/asap/utils.jl` that places nodal lateral forces at each floor-diaphragm level. The existing `sync_asap!` pipeline would call this after `_create_cell_tributary_loads!`.
3. **Use the keyword-argument `factored_pressure` at lateral call sites** — The full overload already exists (`factored_pressure(combo; D=dead, L=live, W=wind_demand)`). No changes to `combinations.jl` are needed.
4. **Column / beam sizing picks up lateral demands automatically** — Columns are sized from Asap member forces. Once lateral loads are in the model, demands increase and columns size up through the existing `sync_asap! → size → sync_asap!` pipeline loop.
5. **Slab unbalanced moments (wind-governed punching)** — Feed frame-sway unbalanced moments into the punching shear check via the existing `Mux` / `Muy` inputs in `codes/aci/punching.jl`.
6. **Multi-case analysis** — Wind introduces directional load cases (+X, −X, +Y, −Y) requiring separate Asap solves per direction, per-member demand envelopes, and sign-aware combination (e.g., 0.9D + 1.0W can produce net uplift).

### What Already Works

- `LoadCombination` struct — has W, E fields
- `factored_pressure` / `envelope_pressure` — full-keyword versions exist
- `DesignParameters.load_combinations` — accepts any combo vector
- `design_building` pipeline — stages are composable
- Snapshot / restore — unaffected by lateral loads

The hardest part will be computing the wind pressures themselves (MWFRS per ASCE 7 Chapter 27/28), not wiring them into the existing infrastructure.

## Limitations & Future Work

- **Lateral load directions**: The envelope functions return a scalar maximum, which is appropriate for gravity. Wind and seismic require tracking load direction and sign.
- **Load combination selection**: The user manually selects which combinations to use. Automatic filtering based on available load types (e.g., skip wind combos when no wind load is defined) is not implemented.
- **Exceptional loads**: Extraordinary event combinations (ASCE 7-22 §2.5) are not included.
