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

The response shape is stable across modes, but **bootstrap mode** and **full service mode** differ slightly:

- In **bootstrap mode** (`scripts/api/sizer_bootstrap.jl`), `/status` is served by the bootstrap script while `StructuralSynthesizer` loads in the background. The payload uses `mode = "bootstrap"`. Once loading completes, `ready` flips to `true` and `state` becomes `"idle" | "running" | "queued"`; however **`mode` remains `"bootstrap"`** and **`has_result` remains `false`** in bootstrap mode.
- In **full service mode** (`scripts/api/sizer_service.jl`), `/status` is served by the main API routes (`StructuralSynthesizer/src/api/routes.jl`) and reports `mode = "full"`, `ready = true`, and a real `has_result` cache check.

- `status`: `"ok"`
- `mode`: `"bootstrap"` in bootstrap mode; `"full"` in full service mode
- `ready`: `false` while bootstrap is warming; `true` once the full API has been loaded (bootstrap) / always `true` in full service mode
- `state`: `"warming"` / `"error"` during bootstrap load; `"idle"` / `"running"` / `"queued"` once ready
- `has_result`: `false` in bootstrap mode; in full service mode, whether a completed design result is available via `GET /result`
- `message`: optional human-readable message (or `null`)
- `error`: optional load error details (or `null`, bootstrap only)

```bash
curl http://localhost:8080/status
```

Bootstrap load (before package load completes):

```json
{"status":"ok","mode":"bootstrap","ready":false,"state":"warming","has_result":false,"message":"Full API not ready yet","error":null}
```

Bootstrap after load completes (note `mode` remains `"bootstrap"` and `has_result` remains `false`):

```json
{"status":"ok","mode":"bootstrap","ready":true,"state":"idle","has_result":false,"message":null,"error":null}
```

Full service mode:

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

The schema route also exposes several more focused schema endpoints:

- `GET /schema/applicability` — compact floor-type compatibility + analysis-method applicability rules (for assistants / lightweight clients)
- `GET /schema/diagnose` — versioned contract for the `GET /diagnose` payload structure
- `GET /schema/tools` — structured registry of available agent tools and their argument/return contracts
- `GET /schema/llm_contract` — versioned machine-readable contract (capabilities, tool list, parameter list, scope limits, experiment types)

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

On acceptance, the server responds with **HTTP 202**:

```json
{
  "status": "accepted",
  "message": "Design started. Poll GET /status until idle, then GET /result for the result."
}
```

When the server is busy, `POST /design` enqueues the request and returns **HTTP 200**:

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
- `format`: `"json"` — when set, returns a structured JSON summary instead of plain text

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

### GET /diagnose

Returns a high-resolution, machine-readable diagnostic payload for the last completed design. This is intended for LLM agents and debugging tools: it includes per-element checks (with demand/capacity and governing check), suggested levers, embodied carbon, and a short architectural narrative.

Optional query parameter:

- `units`: `"imperial"` or `"metric"` — overrides the display units in the payload

Returns **503** if a design is still running/queued, or **404** if no design has been cached yet.

### POST /chat

LLM chat endpoint (SSE streaming). Returns **503** when `CHAT_LLM_API_KEY` is not configured.

The SSE stream emits the following event types (each as `data: <JSON>\n\n`):

| Event key | Description |
|---|---|
| `token` | Incremental text chunk (~80 chars). Suggestion/clarification markers are stripped; structured data is in `agent_turn_summary`. |
| `tool_progress` | Real-time tool execution status. Fields: `tool` (name), `label` (human-readable), `status` (`"running"` / `"ok"` / `"error"`), `round`, `index`, and `elapsed_ms` (present when done). |
| `agent_turn_summary` | End-of-turn structured data: `suggested_next_questions`, `clarification_prompt`, `tool_actions`, `context_usage`, and optionally `params_patch` (validated parameter changes for an "Apply & Run" button). |
| `geometry_init` | Geometry initialization acknowledgement (when `building_geometry` is provided in the request). |
| `design_wait` | Emitted when a full design is in progress at chat start. Phases: `"start"` then periodic `"polling"` with `elapsed_s` until the server is idle. |
| `design_ready` | Emitted once the in-flight design finishes; chat proceeds immediately after. |
| `error` | Error object with `error`, `message`, and `recovery_hint` fields. |
| `[DONE]` | Literal string (not JSON) signaling end of stream. |

### POST /chat/action

Agent tool dispatch endpoint used by the chat assistant.

### GET /chat/history

Retrieve stored conversation history (query `session_id`).

### DELETE /chat/history

Clear stored conversation history (query `session_id`; omit to clear all stored history).

### Starting the Server

#### Bootstrap Mode (Production)

```bash
julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
```

Bootstrap mode starts a lightweight HTTP server immediately with `/health`, `/status`, and `/debug` endpoints. It then loads `StructuralSynthesizer` in a background task. Once loaded, it registers the full route set (including `/design`, `/validate`, `/schema`, `/schema/applicability`, `/schema/diagnose`, `/schema/tools`, `/result`, `/env-check`, `/logs`, `/report`, `/diagnose`, `/chat`, `/chat/action`, `/chat/history`, `/rebuild_visualization`). This provides fast cold starts for container deployments while the heavy package precompilation happens in the background.

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
