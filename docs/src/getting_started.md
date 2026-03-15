# Getting Started

> ```julia
> using StructuralSynthesizer
> using Unitful
> skeleton = gen_medium_office(30.0u"ft", 30.0u"ft", 13.0u"ft", 3, 3, 5)
> struc    = BuildingStructure(skeleton)
> result   = design_building(struc, DesignParameters(loads = office_loads))
> ```

## Overview

This guide walks through installation, running your first structural design, launching the HTTP API, and building the documentation.

## Prerequisites

- **Julia 1.12.4** (project target; see `Dockerfile`)
- Git (to clone the repository)
- Optional: [Gurobi](https://www.gurobi.com/) license for mixed-integer optimization (falls back to [HiGHS](https://highs.dev/) automatically)

## Installation

Clone the repository and activate the project environment:

```bash
git clone https://github.com/natashahirt/menegroth.git
cd menegroth
git submodule update --init --recursive
```

From the Julia REPL:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

This resolves all dependencies for both `StructuralSizer` and `StructuralSynthesizer` (which is declared as a sub-package in the workspace).

### Linux note: Asap path dependencies

This repository uses local path dependencies to `external/Asap`. On Linux, some `Project.toml` files may contain Windows-style backslashes (for example `..\\external\\Asap`), which Julia treats as a different path and can cause `Pkg.instantiate()` to fail with a path resolution error.

If that happens, replace backslashes with forward slashes in the `Project.toml` files that reference Asap, then re-run `Pkg.instantiate()`:

```bash
sed -i 's#\\#/#g' Project.toml StructuralSizer/Project.toml StructuralSynthesizer/Project.toml StructuralVisualization/Project.toml
```

## First Design

```julia
using StructuralSynthesizer
using Unitful

# 1. Generate a 3×3 bay, 5-story medium office skeleton
skeleton = gen_medium_office(
    30.0u"ft", 30.0u"ft",    # bay width x, y
    13.0u"ft",               # floor-to-floor height
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
        concrete = NWC_4000,
        rebar = Rebar_60,
    ),
    fire_rating = 2.0,                      # 2-hour fire resistance
    fire_protection = SFRM(),               # spray-applied fireproofing
    optimize_for = :weight,                 # minimize structural weight
)

# 4. Run the design pipeline
result = design_building(struc, params)

# 5. Inspect results
println("Steel weight: ", result.summary.steel_weight)
println("Embodied carbon: ", result.summary.embodied_carbon, " kgCO₂e")
println("All checks pass: ", result.summary.all_checks_pass)
```

`design_building` runs the full multi-stage pipeline:

1. `initialize!` — create cells, members, and slabs from the skeleton
2. `estimate_column_sizes!` — assign initial column sections from the catalog
3. `to_asap!` — build the finite element model (Asap)
4. `size!` — run AISC/ACI code checks and select sections from catalogs (binary search by default; MIP when enabled by options)
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

# Input schema
curl http://localhost:8080/schema

# Submit a design (async)
curl -X POST http://localhost:8080/design \
  -H "Content-Type: application/json" \
  -d @input.json

# Poll until idle, then fetch the last result
curl http://localhost:8080/status
curl http://localhost:8080/result
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

`DesignParameters` accepts a `display_units` field (use `imperial` or `metric`) that controls how values are formatted in reports and local outputs. The HTTP API derives its output units from the request (`APIParams.unit_system`), which is mapped to `DesignParameters.display_units` during `json_to_params`.

## Limitations & Future Work

- **Lateral loads**: Wind and seismic load factors are defined in `LoadCombination` but the building generators currently produce gravity-only skeletons. Full lateral analysis requires user-supplied loads or a future wind/seismic module.
- **Timber design**: The `Timber` material type is defined but the NDS checker is minimal. Full NDS 2018 implementation is planned.
- **Cross-member constraints**: The synthesizer groups members for constructability (for example, collinear member grouping), but building-wide constraints (for example “use at most N unique column sections across the entire building”) are not yet exposed at the pipeline level.
