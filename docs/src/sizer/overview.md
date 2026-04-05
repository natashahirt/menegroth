# StructuralSizer — Overview

> ```julia
> using StructuralSizer
> combo = strength_1_2D_1_6L
> p_u   = factored_pressure(combo, 100.0psf, 50.0psf)  # → 200 psf
> ```

## Overview

**StructuralSizer** is the component-level structural design and sizing library. It provides material definitions, load combinations, section catalogs, design code checks (AISC 360, ACI 318, fib MC2010, NDS), slab sizing, foundation design, and optimization solvers. StructuralSynthesizer depends on StructuralSizer for all structural calculations.

## Architecture

StructuralSizer is organized around an abstract type hierarchy that enables multiple dispatch across section types, material types, and design codes:

```
AbstractMaterial
├── Metal{K, T_P, T_D}  (aliases: StructuralSteel, RebarSteel)
├── Concrete{T_P, T_D}
├── ReinforcedConcreteMaterial{C, R}
├── FiberReinforcedConcrete{C}
└── Timber{T_P, T_D}

AbstractSection
├── ISymmSection, HSSRectSection, HSSRoundSection, PipeSection
├── RCBeamSection, RCTBeamSection, RCColumnSection, RCCircularSection
├── GlulamSection
└── PixelFrameSection

AbstractCapacityChecker
├── AISCChecker
├── ACIBeamChecker
├── ACIColumnChecker
├── PixelFrameChecker
└── NDSChecker
```

Design functions dispatch on `(section_type, material_type, code)` triples, so the same exported capacity function family (`get_ϕMn`, `get_ϕVn`, `get_ϕPn`, `check_biaxial_capacity`, etc.) routes to the correct steel, concrete, timber, or FRC implementation.

## Module Organization

The source tree mirrors the type hierarchy:

```
StructuralSizer/src/
├── StructuralSizer.jl      # Module definition, exports, precompilation
├── types.jl                 # AbstractMaterial, AbstractSection, AbstractDesignCode
├── Constants.jl             # Physical constants
├── loads/
│   ├── combinations.jl      # ASCE 7-22 load combinations
│   ├── gravity.jl           # GravityLoads presets (office, residential, ...)
│   └── pattern_loading.jl   # ACI 318 §13.7.6 pattern loading
├── materials/
│   ├── types.jl             # Material type definitions + registry
│   ├── steel.jl             # A992, S355, Rebar grades, Stud_51
│   ├── concrete.jl          # NWC presets, RC presets, Earthen materials
│   ├── frc.jl               # Fiber reinforced concrete (fib MC2010)
│   ├── timber.jl            # Timber material (stub)
│   └── fire_protection.jl   # SFRM, intumescent, custom coatings
├── members/
│   ├── sections/            # Section catalogs (steel W/HSS/Pipe, RC columns/beams)
│   └── codes/               # AISC 360, ACI 318, NDS, fib MC2010 checkers
├── slabs/                   # Flat plate, waffle, hollow core, steel deck, vaults
├── foundations/             # Spread footings, pile foundations
├── optimize/                # MIP solvers (Gurobi/HiGHS), objective functions
│   └── solvers/             # Binary search, catalog search, MIP formulations
└── visualization/           # Plotting utilities (optional)
```

## Dependency on Asap

StructuralSizer depends on [Asap](https://github.com/natashahirt/Asap.jl) (local fork at `external/Asap`) for:

- **Units**: Re-exports Unitful quantities — `kip`, `ksi`, `psf`, `ksf`, `pcf`, and `GRAVITY`
- **FEM**: `Asap.Model`, `Asap.solve!` for frame analysis in EFM and member sizing
- **Type aliases**: `Pressure`, `Force`, `Length`, `Density`, etc.

All unit quantities flow through Unitful.jl, so mixed-unit inputs are handled automatically:

```julia
GravityLoads(floor_LL = 2.4u"kPa", floor_SDL = 15.0psf)  # mixed units are fine
```

## Units & Type Aliases

StructuralSizer re-exports unit quantities from [Unitful.jl](https://github.com/PainterQubits/Unitful.jl) via [Asap](https://github.com/natashahirt/Asap.jl).

### US Customary Units

| Unit | Symbol | Definition | Usage |
|------|--------|------------|-------|
| `kip` | kip | 1000 lbf | Force |
| `ksi` | ksi | 1000 psi | Pressure / stress |
| `psf` | psf | lbf/ft² | Area load |
| `ksf` | ksf | 1000 psf | Foundation bearing |
| `pcf` | pcf | lb/ft³ | Density |

### Type Aliases (Dimension-Based)

| Alias | Dimension | Examples |
|-------|-----------|----------|
| `Length` | L | `m`, `ft`, `inch` |
| `Area` | L² | `m²`, `ft²`, `inch²` |
| `Volume` | L³ | `m³`, `ft³`, `inch³` |
| `Pressure` | ML⁻¹T⁻² | `Pa`, `ksi`, `psf` |
| `Force` | MLT⁻² | `N`, `kip`, `lbf` |
| `Moment` | ML²T⁻² | `N·m`, `kip·ft` |
| `LinearLoad` | MT⁻² | `N/m`, `kip/ft` |
| `Density` | ML⁻³ | `kg/m³`, `pcf` |

```@docs
Length
Area
Volume
SectionModulus
SecondMomentOfArea
TorsionalConstant
MomentOfInertia
WarpingConstant
Pressure
Force
Moment
Torque
LinearLoad
AreaLoadQuantity
Density
Acceleration
LengthQuantity
AreaQuantity
VolumeQuantity
PressureQuantity
ForceQuantity
MomentQuantity
ForcePerLength
```

### Unit Conversion Helpers

| Function | Description |
|----------|-------------|
| `to_ksi(x)` | Convert pressure to ksi |
| `to_kip(x)` | Convert force to kip |
| `to_kipft(x)` | Convert moment to kip·ft |
| `to_inches(x)` | Convert length to inches |
| `to_meters(x)` | Convert length to meters |
| `to_pascals(x)` | Convert pressure to Pa |
| `to_newtons(x)` | Convert force to N |

### Unitful Best Practices

```julia
# Store with natural units, convert when needed
span = 6.0u"m"
fc   = 4000u"psi"
stress = uconvert(u"MPa", fc)
value  = ustrip(u"ksi", stress)  # Strip only at final boundary
```

!!! note "Exception"
    Internal calculation functions may strip units at the boundary for optimizer
    interfaces, numerical solvers, and performance-critical inner loops.

### Physical & Design Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `GRAVITY` | 9.80665 m/s² | Standard gravity (from Asap) |

Dead/live load factors are accessed via `LoadCombination` presets (e.g., `strength_1_2D_1_6L.D`, `strength_1_2D_1_6L.L`).

## Dispatch Model

Functions dispatch on section type + material type + design code. For example:

```julia
# AISC steel flexural capacity
get_ϕMn(section, A992_Steel; Lb=20.0u"ft", Cb=1.0, axis=:strong)

# AISC steel axial capacity
get_ϕPn(section, A992_Steel, 20.0u"ft"; axis=:strong)
```

This pattern allows the same high-level APIs (`size_members`, `size_slabs!`, capacity/check helpers) to work across steel, concrete, timber, and FRC sections without conditional branching.

## Key Types

- `LoadCombination` — named load combination with factors for dead, live, snow, wind, and seismic loads per ASCE 7-22. Predefined constants include `strength_1_2D_1_6L`, `strength_1_4D`, etc.
- `GravityLoads` — unfactored gravity load intensities (service-level), with fields `floor_LL`, `roof_LL`, `grade_LL`, `floor_SDL`, `roof_SDL`, and `wall_SDL` (all `Pressure`).

## Limitations & Future Work

- **Timber**: Material type and NDS reference values are defined, but the NDS checker is minimal. Full NDS 2018 implementation is planned.
- **Composite beams**: AISC 360-16 Chapter I composite beam design is implemented (solid and deck slabs, full/partial composite, PNA solver, deflection, construction stage, stud detailing). Composite columns (I2) are not yet implemented.
- **Seismic detailing**: Current code checks cover gravity/wind strength. Seismic detailing (ACI 318 Chapter 18) is not yet implemented.
