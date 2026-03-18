# HTTP API Overview

> ```julia
> # Start the API server
> julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
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
```

## Functions

```@docs
register_routes!
```

## Implementation Details

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

The response shape is stable. In the production **bootstrap script** (`scripts/api/sizer_bootstrap.jl`), the server initially serves a lightweight `/status` implementation (`mode = "bootstrap"`) while `StructuralSynthesizer` loads in the background. Once the load completes, the full route set is registered (replacing `/status`), and the response switches to the full service payload (`mode = "full"`).

- `status`: `"ok"`
- `mode`: `"bootstrap"` during background load, then `"full"` once routes are registered
- `ready`: `true` only once the full route set is registered and design endpoints are available
- `state`: `"warming"` / `"error"` during bootstrap load; `"idle"` / `"running"` / `"queued"` in full mode
- `has_result`: whether a completed design result is available via `GET /result` (full mode only; always `false` during bootstrap load)
- `message`: optional human-readable message (or `null`)
- `error`: optional load error details (or `null`, bootstrap only)

```bash
curl http://localhost:8080/status
```

Bootstrap load (before full routes are registered):

```json
{"status":"ok","mode":"bootstrap","ready":false,"state":"warming","has_result":false,"message":"Full API not ready yet","error":null}
```

Full service mode (or bootstrap after load completes):

```json
{"status":"ok","mode":"full","ready":true,"state":"idle","has_result":false,"message":null,"error":null}
```

### GET /env-check

Returns whether expected Gurobi Web License Service environment variables are set (presence only; values are never returned). This is useful for debugging AWS/App Runner secret injection.

```bash
curl http://localhost:8080/env-check
```

Example response:

```json
{"GRB_WLSACCESSID":true,"GRB_WLSSECRET":true,"GRB_LICENSEID":true}
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
2. Poll `GET /status` until `state == "idle"`.
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

### POST /rebuild\_visualization

Rebuild **only** the visualization mesh at a different target edge length, without re-running the full design. Requires a completed design in cache (i.e. a successful `POST /design` has been run previously). The server re-meshes all shell elements at the requested resolution, re-solves the FEA, and returns the new visualization payload.

Request body:

```json
{ "target_edge_m": 0.5 }
```

- `target_edge_m` (**required**, positive float): target mesh edge length in meters.

Returns a JSON object with `"status": "ok"` and a `"visualization"` key containing the same visualization structure as the full design result. The cached `GET /result` is also updated with the new visualization.

Returns **503** if the server is busy, **404** if no design has been cached yet, or **400** if `target_edge_m` is missing/invalid.

### GET /report

Fetch a plain-text engineering report for the last completed design. Clients should poll `GET /status` until `"idle"` before calling this endpoint.

Optional query parameter:

- `units`: `"imperial"` or `"metric"` — overrides the report display units (default: uses the last design’s `params.unit_system`)

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

### Starting the Server

#### Bootstrap Mode (Production)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
```

Bootstrap mode starts a lightweight HTTP server immediately with `/health`, `/status`, and `/debug` endpoints. It then loads `StructuralSynthesizer` in a background task. Once loaded, it registers the full route set (`/design`, `/validate`, `/schema`, `/result`, `/env-check`). This provides fast cold starts for container deployments while the heavy package precompilation happens in the background.

In bootstrap mode (before the full API is loaded), `GET /status` returns:

```json
{"status":"ok","mode":"bootstrap","ready":false,"state":"warming","has_result":false,"message":"Full API not ready yet","error":null}
```

#### Full Service Mode (Development)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_service.jl
```

Full service mode loads everything upfront with `using StructuralSynthesizer`, registers all routes, and starts serving. This is simpler but has a longer startup time.

### Request Queuing

If the server is already processing a design request, it keeps a **single-slot queue** (the most recent queued request wins):

1. `POST /design` attempts to start work via `try_start!(SERVER_STATUS)`
2. If busy → `enqueue!(SERVER_STATUS, input)` and return `{"status": "queued", ...}`
3. If accepted → the server runs the design in a background task and returns HTTP 202
4. Clients poll `GET /status` until `state == "idle"`, then fetch the last result with `GET /result`

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
| `SS_ENABLE_VISUALIZATION` | Toggle heavy interactive visualization dependencies (e.g., GLMakie) in tooling; JSON `visualization` output is controlled by request params like `skip_visualization` / `visualization_detail` | `false` |
| `SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD` | Run the heavy precompile workload when `StructuralSynthesizer` loads | `false` for the API scripts (they set this unless already provided) |

## Limitations & Future Work

- The API processes one design at a time; true concurrent execution is not supported.
- WebSocket streaming of design progress is planned but not yet implemented.
- Authentication is not implemented; the API is intended for internal/VPC use.

## References

- `StructuralSynthesizer/src/api/routes.jl`
- `scripts/api/sizer_bootstrap.jl`
