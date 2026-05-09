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
    loads = office_loads,                    # 50 psf LL (ASCE 7-22), 15 psf SDL
    materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
    fire_rating = 2.0,                      # 2-hour fire resistance
    fire_protection = SFRM(),               # steel coating type (ignored for RC-only systems)
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

1. `prepare!` — initialize the structure, estimate columns, build the Asap model, and snapshot the pristine state
2. Run the stage vector from `build_pipeline(params; tc=nothing)` (with `sync_asap!` where needed)
3. `capture_design` — populate the `BuildingDesign` (results + summary + timings)
4. `restore!` — revert `struc` to the pristine pre-design state

Note: `design_building` also attempts to build a separate frame+shell visualization model via
`build_analysis_model!` (unless `params.skip_visualization=true`). If that step fails (for example
due to an Asap shell-meshing API mismatch), the design still completes and visualization falls back
to the frame-only model.

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
| `CHAT_LLM_BASE_URL` | *(unset)* | LLM API base URL (e.g. `https://api.openai.com`). Required for `/chat`. |
| `CHAT_LLM_API_KEY` | *(unset)* | LLM API key. Required for `/chat`. |
| `CHAT_LLM_MODEL` | `gpt-4o` | Model name passed to the LLM completions endpoint. |

### Example requests

```bash
# Health check
curl http://localhost:8080/health

# Server status
curl http://localhost:8080/status

# Input schema (includes structured params with guidance text)
curl http://localhost:8080/schema

# Compact applicability/compatibility rules for assistants
curl http://localhost:8080/schema/applicability

# Submit a design (async)
curl -X POST http://localhost:8080/design \
  -H "Content-Type: application/json" \
  -d @input.json

# Poll until idle, then fetch the last result
curl http://localhost:8080/status
curl http://localhost:8080/result

# Engineering report (plain text)
curl http://localhost:8080/report

# Engineering report (structured JSON summary)
curl http://localhost:8080/report?format=json
```

### POST /chat — LLM Chat Endpoint

The `/chat` endpoint provides a conversational AI assistant for design parameter selection and results analysis. Responses are streamed via Server-Sent Events (SSE).

**Request body:**

```json
{
  "mode": "design",
  "messages": [
    {"role": "user", "content": "What floor system should I use for 35ft spans?"}
  ],
  "params": { "floor_type": "flat_plate", "column_type": "rc_rect" },
  "geometry_summary": "5-story building, 3x4 grid, 30ft bays..."
}
```

| Field | Type | Required | Description |
|:------|:-----|:---------|:------------|
| `mode` | `"design"` or `"results"` | Yes | Design mode injects parameter schema and guidance; results mode injects design results. |
| `messages` | Array of `{role, content}` | Yes | Full conversation history. At least one message required. |
| `params` | Object | No | Current design parameters (JSON matching APIParams). |
| `geometry_summary` | String | No | Building geometry summary text for context. |
| `building_geometry` | Object | No | Optional structured geometry (same shape as the geometry portion of `POST /design`, without `params`). Alias: `geometry`. When present, the server derives the same geometry hash used for caching and injects geometry context. |
| `client_geometry_hash` | String | No | Optional client-side geometry hash. Used for alignment/staleness checks when `building_geometry` is absent (or fails to parse). |
| `session_id` | String | No | Stable identifier for server-side conversation history persistence. Typically a geometry hash (derived or client-provided). |
| `reset_session` | Bool | No | When `true`, clears server-side conversation history, design history, and session insights before processing this message (use on Grasshopper restart / new session). |

**Response:** SSE stream with `Content-Type: text/event-stream`.

Token events are followed by a structured summary event before `[DONE]`:

```
data: {"token": "For 35ft spans"}
data: {"token": ", flat plate is a good starting point."}
data: {"type": "agent_turn_summary", "suggested_next_questions": ["What live load do you expect?", "Any aesthetic preferences for slab depth?"]}
data: [DONE]
```

**SSE event types** (each emitted as `data: <JSON>\n\n`):

| Event key | Description |
|---|---|
| `token` | Incremental text chunk (the assistant’s response). |
| `tool_progress` | Real-time tool execution status (`tool`, `label`, `status`, `round`, `index`, `elapsed_ms`). |
| `agent_turn_summary` | End-of-turn structured event with `suggested_next_questions` and optional `clarification_prompt` / `tool_actions`. |
| `geometry_init` | Geometry initialization trace when `building_geometry` is provided. |
| `design_wait` | Emitted when a `POST /design` run is in flight; chat waits until the server is idle, then continues automatically. |
| `design_ready` | Emitted when the in-flight design run finishes and chat begins generating a response. |
| `error` | Error object (`error`, `message`, `recovery_hint`). |
| `[DONE]` | Literal string signaling end of stream. |

**Error responses** (non-streaming JSON):

| Status | Error code | Condition |
|:-------|:-----------|:----------|
| 503 | `llm_not_configured` | `CHAT_LLM_BASE_URL` or `CHAT_LLM_API_KEY` not set |
| 400 | `invalid_json` | Malformed request body |
| 400 | `invalid_mode` | Mode not "design" or "results" |
| 400 | `empty_messages` | No messages provided |
| 404 | `no_design` | Results mode with no design available |

### POST /chat/action — Agent Tool Dispatch

Invoke a structural tool directly from the agent (or test it manually). Requires LLM to be configured.

```bash
curl -X POST http://localhost:8080/chat/action \
  -H 'Content-Type: application/json' \
  -d '{"tool": "validate_params", "args": {"params": {"floor_type": "vault", "column_type": "steel_w"}}}'
```

Available tools:

| Tool | Description |
|:-----|:------------|
| `validate_params` | Check a params patch for compatibility violations (no geometry required). |
| `get_result_summary` | Structured JSON summary of the latest design result. |
| `get_condensed_result` | Plain-text ~500-token condensed result for context injection. |
| `get_applicability` | Compact method/floor eligibility rules from the schema. |
| `run_design` | Fast parameter-only what-if check: skips visualization, caps iterations at 2, MIP at 20 s, 60 s total timeout. **Geometric changes (column layout, bay dimensions, story heights) cannot be applied here** — they must be made in Grasshopper. Purely geometric patches are rejected with a `geometric_change_required` error and actionable Grasshopper guidance. |

**Geometric vs. parameter changes:** The system has two separate layers. *Parameters* (floor type, material, loads, analysis method, sizing strategy) live in the API and can be tested with `run_design`. *Geometry* (column positions, span lengths, story heights, plan shape) lives in the Grasshopper model and must be changed there. The agent is aware of this distinction and will tell the user what to change in Grasshopper when a geometric recommendation is made.

### GET /chat/history — Retrieve Conversation History

```bash
curl "http://localhost:8080/chat/history?session_id=abc123"
```

Returns stored messages for the session. Session IDs are typically geometry hashes.

### DELETE /chat/history — Clear Conversation History

```bash
# Clear a specific session
curl -X DELETE "http://localhost:8080/chat/history?session_id=abc123"

# Clear all sessions
curl -X DELETE "http://localhost:8080/chat/history"
```

### GET /schema/applicability — Compact Applicability Rules

```bash
curl http://localhost:8080/schema/applicability
```

Returns a compact JSON with method/floor compatibility and applicability checks — useful for assistants to quickly determine method eligibility without the full schema.

### Grasshopper Components

**DesignAssistant** — Opens a chat dialog for conversational parameter selection. Connect BuildingGeometry, DesignParams, and a geometry summary. Toggle the Open input to launch the dialog. On first open, the assistant automatically analyzes the design space. Proposed parameter changes are shown with an Apply/Reject UI before being accepted. Outputs the accepted params and transcript.

**ResultsAssistant** — Opens a chat dialog for results analysis. Connect a DesignResult, BuildingGeometry, and geometry summary. On first open, the assistant automatically summarizes failures and governing limit states. Suggested follow-up questions appear as clickable buttons. Outputs the conversation transcript.

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
