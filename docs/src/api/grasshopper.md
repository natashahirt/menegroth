# Grasshopper Client

> ```csharp
> // In Grasshopper (Rhino), the Design Run component sends
> // building geometry to the Julia API and returns results.
> ```

## Overview

The Grasshopper client is a Rhino Grasshopper component (`DesignRun.cs`) that connects the parametric modeling environment to the menegroth API. Designers define building geometry in Grasshopper using standard Rhino primitives (points, lines, surfaces) and the component sends the geometry and parameters to the Julia API for structural design.

**Source:** `grasshopper/Menegroth.GH/Components/DesignRun.cs`

## Workflow

1. **Define geometry** in Grasshopper:
   - Vertices from `Point3d` objects
   - Beam/column/brace edges from `Line` objects
   - Floor faces from `Surface` or `Brep` objects
   - Support vertices from point indices

2. **Configure parameters** via the **Design Params** component:
   - Floor type, materials, loads, fire rating
   - Optimization objective

3. **Run design** via the **Design Run** component:
   - Pre-flight health check: `GET /health`
   - Submit design: `POST /design` with JSON body (returns immediately with `"accepted"` or `"queued"`)
   - Poll `GET /status` until the server returns `"idle"`
   - Fetch the last completed result from `GET /result`
   - Parse result: extract element results, summary, and visualization data

4. **Inspect results** via downstream components:
   - **Design Results** — parsed design results
   - Summary — material quantities and pass/fail
   - Statistics — compute time, convergence info
   - Element details — per-element D/C ratios
   - **Visualization** — 3D visualization meshes

## Grasshopper Components

| Component | Description |
|:----------|:------------|
| **Geometry Input** | Collect points, lines, surfaces into `GH_BuildingGeometry` |
| **Design Params** | Configure design parameters as `GH_DesignParams` |
| **Design Run** | Execute design via API — main component |
| **Design Results** | Parse and expose design results |
| Summary | Material quantities, EC, pass/fail |
| Statistics | Timing, iterations, convergence |
| Element details | Per-element detailed results |
| **Visualization** | 3D mesh output for Rhino viewport |

## Implementation Details

### Design Run Component

**Inputs:**

| Input | Type | Description |
|:------|:-----|:------------|
| Geometry | `GH_BuildingGeometry` | Building geometry from **Geometry Input** |
| Params | `GH_DesignParams` | Design parameters from **Design Params** |
| Server URL | `String` | API endpoint (default: `http://localhost:8080`). For AWS deployment, ask the project owner for the server URL. |
| Run | `Boolean` | Trigger design execution |

**Outputs:**

| Output | Type | Description |
|:-------|:-----|:------------|
| JSON | `String` | Raw JSON response |
| Status | `String` | `"ok"`, `"error"`, or `"cached"` |
| Compute Time | `Double` | Design time in seconds |

### HTTP Communication

- **Health check:** `GET /health` — verifies the server is reachable before submitting
- **Design request:** `POST /design` — starts an asynchronous design job (returns quickly; the design runs server-side in the background)
- **Result polling:** poll `GET /status` at 2-second intervals until the server returns `"idle"`, then fetch results via `GET /result`

### Caching

Two levels of caching reduce unnecessary API calls:

1. **Client-side cache** — hashes geometry + params; if unchanged from last run, returns cached response without API call
2. **Server-side geometry cache** — the server computes a deterministic geometry hash from the request geometry and reuses the last cached skeleton/structure when the hash matches (skipping skeleton reconstruction and only re-running the design pipeline). The `APIInput.geometry_hash` field exists but is not currently used by the server.

### Status Messages

The component displays real-time status in the Grasshopper canvas:

| Status | Display |
|:-------|:--------|
| Ready | "Ready" (grey) |
| Computing | "Computing…" (yellow) |
| Success | "✓ 2.3 s" (green) |
| Cached | "✓ Cached" (green) |
| Error | "✗ Error: message" (red) |

### Building Geometry from Grasshopper

The **Geometry Input** component converts Rhino geometry to API-compatible format:

| Rhino Primitive | API Field | Conversion |
|:----------------|:----------|:-----------|
| `Point3d` list | `vertices` | Coordinates extracted, unit-converted |
| `Line` list | `edges.beams`, `edges.columns` | Nearest-vertex matching for connectivity |
| `Surface` / `Brep` | `faces` | Boundary vertices extracted |
| Point indices | `supports` | User-specified support locations |

## Options & Configuration

| Setting | Description | Default |
|:--------|:------------|:--------|
| Server URL | API endpoint | `http://localhost:8080` (for AWS, ask the project owner for the server URL) |
| Timeout | HTTP request timeout | 300 seconds |
| Poll interval | Queue status polling interval | 2 seconds |

## Limitations & Future Work

- The Grasshopper client is C# (.NET); it requires Rhino 7+ with Grasshopper.
- Visualization mesh import back to Rhino is supported but large models may be slow.
- Real-time design-as-you-model (automatic re-run on geometry change) is planned but not yet implemented.
- The client does not support authentication; it assumes a local or VPC-accessible server.

## Using the AWS-deployed API

For the AWS-deployed API, ask the project owner for the server URL and set it in the **Server URL** input (or as the default in `DesignRun.cs`). The component default is `http://localhost:8080` for local development.
