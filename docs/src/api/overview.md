# HTTP API Overview

> ```julia
> # Start the API server
> # julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
> ```

## Overview

The menegroth HTTP API exposes the full design pipeline as a JSON REST service. It accepts building geometry and design parameters as JSON, runs the design workflow, and returns sized elements, material quantities, embodied carbon, and visualization data.

The API uses [Oxygen.jl](https://github.com/ndortega/Oxygen.jl) for HTTP routing and supports both a **bootstrap mode** (fast cold start, lazy loading) and a **full service mode** (everything loaded upfront).

## Endpoints

### GET /health

Health check for liveness probes.

```bash
curl http://localhost:8080/health
```

```json
{"status": "ok"}
```

### GET /status

Server state endpoint. In bootstrap mode it reports `"warming"` until full routes are loaded; after load it reports full-service states (`"idle"`, `"running"`, `"queued"`).

```bash
curl http://localhost:8080/status
```

```json
{"status":"warming","message":"Full API not ready yet"}
```

### GET /schema

Returns documentation of the input/output JSON schema.

```bash
curl http://localhost:8080/schema
```

### POST /validate

Validate input JSON without running the design.

```bash
curl -X POST http://localhost:8080/validate \
  -H "Content-Type: application/json" \
  -d @input.json
```

```json
{"status": "ok", "message": "Input is valid."}
```

### POST /design

Run the full design pipeline. Returns an `APIOutput` with sized elements, summary, and optional visualization.

```bash
curl -X POST http://localhost:8080/design \
  -H "Content-Type: application/json" \
  -d @input.json
```

```json
{
  "status": "ok",
  "compute_time_s": 2.34,
  "summary": {
    "all_pass": true,
    "concrete_volume_ft3": 1234.5,
    "steel_weight_lb": 56789.0,
    "rebar_weight_lb": 12345.0,
    "embodied_carbon_kgCO2e": 98765.0,
    "critical_ratio": 0.87,
    "critical_element": "Column 12"
  },
  "slabs": [...],
  "columns": [...],
  "beams": [...],
  "foundations": [...]
}
```

When the server is busy, `POST /design` returns:

```json
{
  "status": "queued",
  "message": "Request queued; will run after current job completes."
}
```

## Starting the Server

### Bootstrap Mode (Production)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
```

Bootstrap mode starts a lightweight HTTP server immediately with `/health`, `/status`, and `/debug` endpoints. It then loads `StructuralSynthesizer` in a background task. Once loaded, it registers the full route set (`/design`, `/validate`, `/schema`). This provides fast cold starts for container deployments while the heavy package precompilation happens in the background.

### Full Service Mode (Development)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_service.jl
```

Full service mode loads everything upfront with `using StructuralSynthesizer`, registers all routes, and starts serving. This is simpler but has a longer startup time.

## Key Types

```@docs
APIInput
APIOutput
APIParams
APIError
```

**`APISummary`** — A summary of the design results including pass/fail status, total material quantities (concrete volume, steel weight, rebar weight), embodied carbon, and the governing demand-to-capacity ratio with its associated element.

## Functions

```@docs
register_routes!
```

## Implementation Details

### Environment Variables

| Variable | Description | Default |
|:---------|:------------|:--------|
| `PORT` / `SIZER_PORT` | HTTP listen port | `8080` |
| `SIZER_HOST` | Bind address | `0.0.0.0` |
| `SS_ENABLE_VISUALIZATION` | Include visualization data in output | `false` |
| `SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD` | Run precompilation workload on startup | `false` |

### Request Queuing

If the server is already processing a design request, incoming requests are queued and processed FIFO:

1. `POST /design` → `try_start!(server_status)`
2. If busy → `enqueue!(server_status, input)` and return `{"status": "queued"}`
3. Client polls `GET /status` until `"idle"`
4. Client retries `POST /design`

### Geometry Caching

Repeated requests with the same building geometry (but different design parameters) skip skeleton reconstruction:

1. `compute_geometry_hash(input)` → SHA hash of vertices, edges, faces, supports, stories
2. If hash matches a cached skeleton, reuse it
3. Only `json_to_params` and `design_building` are re-run

This significantly speeds up parameter studies where only loads, materials, or floor options change.

## Limitations & Future Work

- The API processes one design at a time; true concurrent execution is not supported.
- WebSocket streaming of design progress is planned but not yet implemented.
- Authentication is not implemented; the API is intended for internal/VPC use.

## References

- `StructuralSynthesizer/src/api/routes.jl`
- `scripts/api/sizer_bootstrap.jl`
