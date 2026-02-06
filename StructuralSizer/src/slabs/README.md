# Slab Sizing API

Floor system sizing and optimization for various slab types.

## API Hierarchy

```
size_slabs!(struc; options)          # Size all slabs in structure
└── size_slab!(struc, idx; options)  # Size single slab (scripting/debug)
    └── _size_slab!(floor_type, ...) # Type-dispatched implementation
        ├── FlatPlate → size_flat_plate!()
        ├── Vault → optimize_vault() or _size_span_floor()
        └── (others) → not yet implemented
```

## Quick Start

```julia
using StructuralSizer

# Size all slabs in a structure
opts = FloorOptions(flat_plate=FlatPlateOptions(analysis_method=:ddm))
size_slabs!(struc; options=opts)

# Size a single slab
size_slab!(struc, 1; options=opts, verbose=true)

# Standalone vault optimization
result = optimize_vault(6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2")
```

## Floor Types

| Type | Status | Description |
| ---- | ------ | ----------- |
| `FlatPlate` | ✅ Full | Two-way flat plate (ACI 318 DDM/EFM) |
| `Vault` | ✅ Full | Unreinforced parabolic vault (Haile method) |
| `FlatSlab` | ⚠️ Stub | Flat plate with drop panels |
| `TwoWay` | ⚠️ Stub | Two-way slab with beams |
| `OneWay` | ⚠️ Stub | One-way slab |
| `Waffle` | ⚠️ Stub | Two-way joist system |
| `PTBanded` | ⚠️ Stub | Post-tensioned banded |

## Configuration

All options flow through `FloorOptions`:

```julia
FloorOptions(
    flat_plate = FlatPlateOptions(...),  # Flat plate / flat slab / waffle / PT
    one_way = OneWayOptions(...),        # One-way slab settings
    vault = VaultOptions(...),           # Vault-specific settings
    composite = CompositeDeckOptions(...),
    timber = TimberOptions(...),
    tributary_axis = nothing,            # Override tributary computation
)
```

The slab's floor type determines which sub-options are used.

## Implemented Systems

### Flat Plate (CIP Concrete)

Full ACI 318-19 design pipeline with DDM or EFM analysis.

```julia
opts = FloorOptions(flat_plate=FlatPlateOptions(
    material = RC_4000_60,      # Concrete + rebar
    analysis_method = :ddm,     # :ddm, :mddm, :efm
    cover = 0.75u"inch",
    deflection_limit = :L_360,
))
size_slabs!(struc; options=opts)
```

**Features:**
- Column P-M interaction design (iterates with slab)
- Punching shear with moment transfer
- Two-way deflection (crossing beam method)
- Strip reinforcement design

See: `codes/concrete/flat_plate/README.md`

### Vault (Unreinforced)

Parabolic vault sizing with geometry optimization.

```julia
# Optimization mode (default)
opts = FloorOptions(vault=VaultOptions(
    lambda_bounds = (10.0, 15.0),  # or rise_bounds
    thickness_bounds = (2.0u"inch", 4.0u"inch"),
    objective = MinVolume(),
))

# Analytical mode (fixed geometry)
opts = FloorOptions(vault=VaultOptions(
    lambda = 12.0,       # or rise = 0.5u"m"
    thickness = 75u"mm",
))
```

**Features:**
- Symmetric + asymmetric load analysis
- Elastic shortening (rise reduction)
- Grid or Ipopt optimization
- MinVolume/MinWeight/MinCarbon objectives

See: `codes/vault/README.md`

## Standalone Optimization

For vaults, `optimize_vault` can be called directly without a structure:

```julia
result = optimize_vault(
    6.0u"m",           # span
    1.0u"kN/m^2",      # SDL
    2.0u"kN/m^2";      # live
    lambda_bounds = (8.0, 15.0),
    objective = MinCarbon(),
)

result.rise       # Optimal rise
result.thickness  # Optimal thickness
result.status     # :optimal, :feasible, :infeasible
```

## Adding New Floor Types

1. Define type in `types.jl` (e.g., `struct MyFloor <: AbstractFloorSystem end`)
2. Add options struct in `options.jl` if needed
3. Implement `_size_slab!(::MyFloor, struc, slab, idx; options, ...)` in `sizing.jl`
4. Or implement `_size_span_floor(::MyFloor, span, sdl, live; ...)` for span-based sizing

## File Structure

```
slabs/
├── README.md           # This file
├── types.jl            # Floor type definitions, result structs
├── options.jl          # FloorOptions, FlatPlateOptions, OneWayOptions, VaultOptions
├── sizing.jl           # Main API: size_slabs!, size_slab!, _size_slab!
├── utils/              # ACI strip geometry, tributary helpers
├── optimize/           # Vault NLP optimization
│   ├── api.jl          # optimize_vault()
│   └── problems.jl     # VaultNLPProblem
└── codes/
    ├── concrete/
    │   ├── flat_plate/ # DDM, EFM, pipeline, calculations
    │   └── sizing.jl   # _size_span_floor for CIP types
    └── vault/
        ├── README.md
        └── haile_unreinforced.jl
```
