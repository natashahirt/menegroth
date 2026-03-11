# Getting Started

> ```julia
> using StructuralSynthesizer
> skeleton = gen_medium_office(30ft, 30ft, 13ft, 3, 3, 5)
> struc    = BuildingStructure(skeleton)
> result   = design_building(struc, DesignParameters(loads = office_loads))
> ```

## Overview

This guide walks through installation, running your first structural design, launching the HTTP API, and building the documentation.

## Prerequisites

- **Julia 1.10+** (tested on 1.10 and 1.11)
- Git (to clone the repository)
- Optional: [Gurobi](https://www.gurobi.com/) license for mixed-integer optimization (falls back to [HiGHS](https://highs.dev/) automatically)

## Installation

Clone the repository and activate the project environment:

```bash
git clone https://github.com/natashahirt/menegroth.git
cd menegroth
```

From the Julia REPL:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

This resolves all dependencies for both `StructuralSizer` and `StructuralSynthesizer` (which is declared as a sub-package in the workspace).

## First Design

```julia
using StructuralSynthesizer

# 1. Generate a 3×3 bay, 5-story medium office skeleton
skeleton = gen_medium_office(
    30ft, 30ft,    # bay width x, y
    13ft,          # floor-to-floor height
    3, 3,          # bays in x, y
    5              # number of stories
)

# 2. Create the BuildingStructure (cells, members, slabs, caches)
struc = BuildingStructure(skeleton)

# 3. Configure design parameters
params = DesignParameters(
    loads = office_loads,                    # 50 psf LL, 15 psf SDL
    materials = MaterialOptions(
        steel = A992_Steel,
        concrete = RC_4000_60,
    ),
    fire_rating = 2.0,                      # 2-hour fire resistance
    fire_protection = SFRM(),               # spray-applied fireproofing
    optimize_for = :weight,                 # minimize structural weight
)

# 4. Run the design pipeline
result = design_building(struc, params)

# 5. Inspect results
println("Total weight: ", result.total_weight)
println("Embodied carbon: ", result.total_ec, " kgCO₂e")
```

`design_building` runs the full multi-stage pipeline:

1. `initialize!` — create cells, members, and slabs from the skeleton
2. `estimate_column_sizes!` — assign initial column sections from the catalog
3. `to_asap!` — build the finite element model (Asap)
4. `size!` — run AISC/ACI code checks, optimize sections via MIP
5. Post-process — compute embodied carbon, fire protection, reports

## Running the HTTP API

The platform includes an HTTP API for integration with external tools (Grasshopper, web dashboards, etc.).

### Quick start (direct load)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_service.jl
```

### Bootstrap mode (health endpoint available immediately)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
```

Bootstrap mode starts the HTTP server immediately with `/health` and `/status` endpoints, then loads the full package in the background. The `/design` endpoint becomes available once loading completes.

### Environment variables

| Variable | Default | Description |
|:---------|:--------|:------------|
| `PORT` or `SIZER_PORT` | `8080` | Server port |
| `SIZER_HOST` | `"0.0.0.0"` | Bind address |

### Example requests

```bash
# Health check
curl http://localhost:8080/health

# Server status
curl http://localhost:8080/status

# Input/output schema
curl http://localhost:8080/schema

# Run a design
curl -X POST http://localhost:8080/design \
  -H "Content-Type: application/json" \
  -d @input.json
```

## Building the Docs

```bash
julia --project=docs docs/make.jl
```

The generated site appears in `docs/build/`. Set `CI=true` to enable pretty URLs for deployment.

## Options & Configuration

### Gurobi vs HiGHS

The optimization framework checks for a Gurobi license at startup. If Gurobi is unavailable, all mixed-integer programs fall back to HiGHS transparently. Gurobi is faster for large discrete optimization problems (e.g., rebar layout, section catalog search) but HiGHS is sufficient for most designs.

### Display Units

`DesignParameters` accepts a `display_units` field (`:imperial` or `:metric`) that controls how results are formatted in reports and API responses. Internal calculations always use SI units via Unitful.jl.

## Limitations & Future Work

- **Lateral loads**: Wind and seismic load factors are defined in `LoadCombination` but the building generators currently produce gravity-only skeletons. Full lateral analysis requires user-supplied loads or a future wind/seismic module.
- **Timber design**: The `Timber` material type is defined but the NDS checker is minimal. Full NDS 2018 implementation is planned.
- **Multi-material optimization**: The current pipeline sizes each member independently. Cross-member optimization (e.g., grouping columns by size for constructability) is in development.
