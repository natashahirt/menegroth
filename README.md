# menegroth

End-to-end building generation and structural design platform in Julia. Produces fully sized structural systems (beams, columns, slabs, and foundations) from a parametric building skeleton, with embodied carbon accounting and fire protection sizing.

## Quick Start

```julia
using StructuralSynthesizer

skeleton = gen_medium_office(30ft, 30ft, 13ft, 3, 3, 5)
struc    = BuildingStructure(skeleton)
result   = design_building(struc, DesignParameters(loads = office_loads))
```

## Packages

| Package | Purpose |
|:--------|:--------|
| **Asap** | Units (Unitful), FEM analysis |
| **StructuralSizer** | Materials, sections, design codes (AISC 360, ACI 318, fib MC2010, NDS), slabs, foundations, optimization |
| **StructuralSynthesizer** | Building generation, design workflows, tributary analysis, post-processing, HTTP API |
| **StructuralPlots** | Makie themes and figure utilities |
| **StructuralStudies** | Parametric research studies |

Dependency chain: `Asap` → `StructuralSizer` → `StructuralSynthesizer`

## Installation

```bash
git clone https://github.com/natashahirt/menegroth.git
cd menegroth
```

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

**Requirements:** Julia 1.10+. Optional: [Gurobi](https://www.gurobi.com/) license (falls back to [HiGHS](https://highs.dev/) automatically).

## HTTP API

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_service.jl
```

Endpoints: `GET /health`, `GET /status`, `GET /schema`, `POST /design`. See the full documentation for details.

## Documentation

Build locally:

```bash
julia --project=docs docs/make.jl
```

The generated site appears in `docs/build/`. Full documentation covers materials, design codes, slab systems, foundations, optimization, building workflows, the API, and implementation details.

## Design Code Coverage

| Code | Scope | Status |
|:-----|:------|:-------|
| AISC 360-16 | W, HSS Rect, HSS Round — flexure, shear, compression, P-M interaction, LTB | Full |
| ACI 318-11/19 | RC columns (rect + circular, P-M, biaxial, slenderness), beams (flexure + shear), flat plates (DDM, EFM, FEA) | Full |
| ACI 336.2R | Spread, strip/combined, and mat foundations (rigid + Hetenyi) | Full |
| fib MC2010 | FRC shear (PixelFrame) | Full |
| NDS | Timber | Stub |

## License

Private repository — all rights reserved.
