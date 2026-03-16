# Deployment

> ```bash
> # Build and run locally
> docker build -t menegroth .
> docker run -p 8080:8080 menegroth
> curl http://localhost:8080/health
> ```

## Overview

The menegroth API is deployed as a Docker container on AWS App Runner. The CI/CD pipeline automates building, pushing to ECR, updating the App Runner service, and running smoke tests.

## Docker

The `Dockerfile` uses the official `julia:1.12.4` base image:

1. Copies the project files (manifests, source code, scripts)
2. Instantiates the Julia project (so dependencies are resolved in a cached build layer)
3. Performs a **build-time warmup** (`using StructuralSynthesizer; register_routes!()`) so common code paths are precompiled into the depot at `/app/.julia`
4. Runs `scripts/api/sizer_bootstrap.jl` as the default command

The bootstrap entry point binds the HTTP server quickly; `StructuralSynthesizer` is then loaded in the background, reusing the precompiled depot baked into the image.

### Build-time warmup (no sysimage)

The current image does **not** build a PackageCompiler sysimage. Instead, it warms up the runtime by precompiling:

- `Oxygen`, `HTTP`, and `Unitful` (so the bootstrap server binds quickly).
- `StructuralSynthesizer` route registration (so the full API loads faster once the background task completes).

Cold start is typically on the order of tens of seconds to about a minute, depending on cache reuse and native library load time. The Grasshopper client waits up to 1 hour for “API ready” and offers a **Cancel** option.

### Storing the environment so startup isn’t necessary

The environment (packages + precompiled code) is already stored in the image under `/app/.julia`. Every new container gets that copy. There is no separate “cloud store” of the environment: App Runner doesn’t support persistent volumes, so you can’t persist a depot between container restarts. You can still reduce or hide cold start in these ways:

1. **Keep one instance warm**  
   In App Runner, set **Minimum capacity** to **1**. One container stays running; its in-memory state (loaded packages) stays hot. Cold start only happens when that instance is replaced (e.g. after a deploy). Trade-off: you pay for that instance even when idle.

2. **Match build and run environment**  
   Build the image for the same architecture and OS as the cloud (e.g. `linux/amd64`). In GitHub Actions, the default runner is amd64; App Runner is typically amd64. If they match, Julia is less likely to invalidate the precompiled cache at runtime. Ensure `JULIA_DEPOT_PATH` is the same at build and run (`/app/.julia` in the Dockerfile).

3. **Build-time warmup** — **Implemented.** The image precompiles common API dependencies and calls `register_routes!()` during the build so the runtime can reuse precompiled artifacts from `/app/.julia`.

4. **Persistent volume (other services only)**  
   If you move off App Runner to something that supports volumes (e.g. ECS with EFS, or an EC2 instance with an EBS volume), you could put `JULIA_DEPOT_PATH` on that volume. The first run would populate it; later runs (or new containers mounting the same volume) would reuse it. App Runner does not support this.

**Summary:** The image stores the environment (packages + precompiled artifacts) in `/app/.julia`. Cold start is “bootstrap binds quickly, then the full API loads in the background.” To avoid cold start entirely, keep one instance warm (min capacity 1).

## AWS App Runner

The deployment uses AWS App Runner for managed container hosting:

- **Automatic scaling** — scales from 0 to N instances based on request volume
- **Health checks** — `GET /health` used for liveness probing
- **HTTPS termination** — handled by App Runner's load balancer

**Request timeout:** App Runner enforces a **fixed 120-second limit** on each HTTP request. The API uses an **async submit-then-poll** pattern so long designs do not hit this limit: `POST /design` returns **202 Accepted** immediately and runs the design in the background; the client polls `GET /status` until idle, then fetches the result with `GET /result`. Each of those requests is short, so the 120s limit does not apply to the design computation itself.

## CI Pipeline

**Source:** `.github/workflows/deploy-api.yml`

The GitHub Actions workflow triggers on pushes to `main` and `workflow_dispatch`:

| Step | Description |
|:-----|:------------|
| Checkout | Clone repository |
| AWS OIDC Auth | Authenticate via OpenID Connect (no long-lived credentials) |
| ECR Login | Authenticate to Amazon ECR |
| Docker Build & Push | Build image and push to ECR repository |
| App Runner Update | Update the App Runner service with the new image |
| Smoke Test (health) | Poll `GET /health` until `200 OK` (up to 24 attempts, 10s interval) |
| Smoke Test (schema) | Verify `GET /schema` returns valid response |

### Timeouts and credentials

The Docker image build includes dependency instantiation and a build-time warmup (`using StructuralSynthesizer; register_routes!()`) that can take several minutes on a cold cache. The full workflow (build → push → App Runner update → smoke test) may approach or exceed **1 hour** depending on cache hits and registry/network speed.

- **AWS credentials:** The workflow uses OIDC to assume an IAM role. Default temporary credentials last **1 hour**. The workflow requests **2 hours** (`role-duration-seconds: 7200`) so they don’t expire during a long build. The **IAM role** used for OIDC must allow this: in AWS IAM → your role → **Maximum session duration** set to at least **2 hours** (7200 seconds). If you leave it at 1 hour, the job can fail with expired credentials when pushing to ECR or updating App Runner.
- **Job timeout:** The deploy job has a **120-minute** limit (`timeout-minutes: 120`). If the build or deploy hangs, the job is cancelled instead of running for hours.
- **Warmup step:** Inside the Dockerfile, the build-time warmup is guarded by a timeout (currently 30 minutes). If precompilation hangs, the build fails so CI doesn’t stall indefinitely.

### Required Secrets

| Secret | Description |
|:-------|:------------|
| `APP_RUNNER_SERVICE_ARN` | ARN of the App Runner service |
| `ECR_REPOSITORY` | ECR repository name |
| `APP_URL` | Public URL of the deployed service (e.g. `https://xxx.us-east-1.awsapprunner.com`). Use this as the **Server URL** in the Grasshopper SizerRun component. |

## Bootstrap vs Service Mode

| Aspect | Bootstrap | Service |
|:-------|:----------|:--------|
| Startup time | ~5s (health available), ~60s (full) | ~60s (full) |
| Entry point | `sizer_bootstrap.jl` | `sizer_service.jl` |
| Cold start | Fast — serves `/health` immediately | Slow — blocks until loaded |
| Use case | Production (App Runner health checks) | Development |

Bootstrap mode is preferred for production because App Runner requires a health check response within a timeout. The bootstrap server responds to `/health` immediately and returns `{"state":"warming","message":"Full API not ready yet"}` for `/status` until the full package is loaded.

Once the full API is loaded, the bootstrap `/status` endpoint returns `{"state":"idle"|"running"|"queued"}` (with optional `message` when extra context is needed).

## Environment Variables

| Variable | Description | Default |
|:---------|:------------|:--------|
| `PORT` / `SIZER_PORT` | HTTP listen port | `8080` |
| `SIZER_HOST` | Bind address | `0.0.0.0` |
| `SS_ENABLE_VISUALIZATION` | Toggle heavy visualization dependencies in interactive tooling (e.g., GLMakie); does not currently control JSON `visualization` output | `false` |
| `SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD` | Run a precompilation workload on startup to warm the JIT | `false` |

### Gurobi license (optional)

To use Gurobi on the server instead of HiGHS, provide a license in one of these ways:

**Option A — Web License Service (WLS)**  
Set these environment variables in the App Runner service (e.g. in AWS Console → App Runner → your service → Configuration → Environment variables). Prefer storing values in AWS Secrets Manager and referencing them in App Runner.

| Variable | Description |
|:---------|:------------|
| `GRB_WLSACCESSID` | WLS access ID from [Gurobi Web License Manager](https://license.gurobi.com/) → API Keys |
| `GRB_WLSSECRET` | WLS secret from the same API key |
| `GRB_LICENSEID` | License ID (numeric) |

Gurobi will use these at runtime; no file is needed.

**Option B — License file path**  
If you have a `gurobi.lic` file in the image (e.g. baked in at build time via a Docker build secret):

| Variable | Description |
|:---------|:------------|
| `GRB_LICENSE_FILE` | Path to the license file, e.g. `/opt/gurobi/gurobi.lic` |

**Option C — License content via env var**  
If the container uses the optional entrypoint (see below), you can set:

| Variable | Description |
|:---------|:------------|
| `GRB_LICENSE_CONTENTS` | Full contents of `gurobi.lic` (single line or newlines). Written to a file at startup; `GRB_LICENSE_FILE` is set automatically. |

Store the value in AWS Secrets Manager and inject it as an environment variable in App Runner so the license is not in the image.

### Performance Tuning

- **`SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD`** — runs a representative design on startup to compile all code paths. Increases startup time by ~30s but eliminates first-request latency.
- **Visualization payload size** — use `visualization_detail: "minimal"` in params to skip deflected slab meshes and reduce payload size, or set `skip_visualization: true` to omit visualization entirely (`visualization = null`).

### Response format

The `GET /result` endpoint returns plain JSON (no gzip compression). Large design results may be several MB; ensure adequate timeouts and buffer sizes for your client.

## Health Check Configuration

App Runner health check settings:

| Setting | Value |
|:--------|:------|
| Path | `/health` |
| Protocol | HTTP |
| Interval | 10s |
| Timeout | 5s |
| Healthy threshold | 1 |
| Unhealthy threshold | 5 |

## Limitations & Future Work

- No horizontal scaling coordination; each instance is independent with its own in-memory cache.
- Blue/green deployment with traffic shifting is handled by App Runner but not explicitly configured.
- Container image size (~2 GB due to Julia + dependencies) could be reduced with a multi-stage build.
