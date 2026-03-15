# HTTP API Overview

> ```julia
> # Start the API server
> # julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
> ```

## Overview

The menegroth HTTP API exposes the full design pipeline as a JSON REST service. It accepts building geometry and design parameters as JSON, runs the design workflow, and returns sized elements, material quantities, embodied carbon, and visualization data.

The API uses [Oxygen.jl](https://github.com/ndortega/Oxygen.jl) for HTTP routing and supports both a **bootstrap mode** (fast cold start, lazy loading) and a **full service mode** (everything loaded upfront).

## Key Types

```@docs
APIInput
APIOutput
APIParams
APIError
StructuralSynthesizer.APISummary
```

## Functions

```@docs
register_routes!
```

### Endpoints

### GET /health

Health check for liveness probes.

```bash
curl http://localhost:8080/health
```

```json
{"status": "ok"}
```

### GET /status

Server state endpoint.

- In **full service mode** (`scripts/api/sizer_service.jl`), the response is always `{"state":"idle"|"running"|"queued"}` (no `message` field).
- In **bootstrap mode** (`scripts/api/sizer_bootstrap.jl`), the lightweight bootstrap server may return `{"state":"warming","message":"..."}` before the full API has been loaded; once loaded, it delegates to the full `/status` route and returns only `{"state":"..."}`.

```bash
curl http://localhost:8080/status
```

```json
{"state":"idle"}
```

### GET /env-check

Returns whether expected Gurobi Web License Service environment variables are set (presence only; values are never returned). This is useful for debugging AWS/App Runner secret injection.

```bash
curl http://localhost:8080/env-check
```

### GET /debug (bootstrap only)

Bootstrap mode exposes a lightweight debug endpoint that reports the bootstrap loader status and any background-load error message.

### GET /schema

Returns documentation of the API input payload schema and a short endpoint summary.

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

Run the full design pipeline.

Because AWS App Runner enforces a 120-second per-request timeout, the API uses an **async submit-then-poll** flow:

1. Submit the job with `POST /design` (returns immediately).
2. Poll `GET /status` until it returns `"idle"`.
3. Fetch the last completed result with `GET /result`.

```bash
curl -X POST http://localhost:8080/design \
  -H "Content-Type: application/json" \
  -d @input.json
```

```json
{
  "status": "accepted",
  "message": "Design started. Poll GET /status until idle, then GET /result for the result."
}
```

When the server is busy, `POST /design` enqueues the request and returns:

```json
{
  "status": "queued",
  "message": "Request queued; will run after current job completes."
}
```

### GET /result

Fetch the last completed design result after a `POST /design` submission. Clients should poll `GET /status` until `"idle"` before calling this endpoint.

### GET /logs

Streaming design logs for long-running jobs. Pass a cursor `since` (integer) and the server returns the new lines since that cursor, plus the next cursor to use.

```bash
curl "http://localhost:8080/logs?since=0"
```

Response fields:

- `status`: `"idle"`, `"running"`, or `"queued"` (mirrors server state)
- `base`: the absolute index of the first line retained in the server ring buffer
- `next_since`: the cursor to use on the next request
- `lines`: an array of log lines

## Starting the Server

### Bootstrap Mode (Production)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
```

Bootstrap mode starts a lightweight HTTP server immediately with `/health`, `/status`, and `/debug` endpoints. It then loads `StructuralSynthesizer` in a background task. Once loaded, it registers the full route set (`/design`, `/validate`, `/schema`, `/result`, `/env-check`). This provides fast cold starts for container deployments while the heavy package precompilation happens in the background.

In bootstrap mode (before the full API is loaded), `GET /status` returns:

```json
{"state":"warming","message":"Full API not ready yet"}
```

### Full Service Mode (Development)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_service.jl
```

Full service mode loads everything upfront with `using StructuralSynthesizer`, registers all routes, and starts serving. This is simpler but has a longer startup time.
## Implementation Details

### Request Queuing

If the server is already processing a design request, it keeps a **single-slot queue** (the most recent queued request wins):

1. `POST /design` attempts to start work via `try_start!(SERVER_STATUS)`
2. If busy → `enqueue!(SERVER_STATUS, input)` and return `{"status": "queued", ...}`
3. If accepted → the server runs the design in a background task and returns HTTP 202
4. Clients poll `GET /status` until `"idle"`, then fetch the last result with `GET /result`

### Geometry Caching

Repeated requests with the same building geometry (but different design parameters) skip skeleton reconstruction:

1. `compute_geometry_hash(input)` → SHA hash of vertices, edges, faces, supports, stories
2. If hash matches a cached skeleton, reuse it
3. Only `json_to_params` and `design_building` are re-run

This significantly speeds up parameter studies where only loads, materials, or floor options change.

## Options & Configuration

### Environment Variables

| Variable | Description | Default |
|:---------|:------------|:--------|
| `PORT` / `SIZER_PORT` | HTTP listen port | `8080` |
| `SIZER_HOST` | Bind address | `0.0.0.0` |
| `SS_ENABLE_VISUALIZATION` | Toggle heavy visualization dependencies (e.g., GLMakie) in interactive tooling; does not currently control JSON `visualization` output | `false` |
| `SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD` | Run the heavy precompile workload when `StructuralSynthesizer` loads | `false` for the API scripts (they set this unless already provided) |

## Limitations & Future Work

- The API processes one design at a time; true concurrent execution is not supported.
- WebSocket streaming of design progress is planned but not yet implemented.
- Authentication is not implemented; the API is intended for internal/VPC use.

## References

- `StructuralSynthesizer/src/api/routes.jl`
- `scripts/api/sizer_bootstrap.jl`
