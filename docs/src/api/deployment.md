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
2. Instantiates the Julia project and builds a **custom sysimage** (PackageCompiler) containing StructuralSynthesizer and API route registration
3. Runs `scripts/api/sizer_bootstrap.jl` with that sysimage (`julia -J /app/sys.so ...`) as the entry point

The bootstrap entry point binds the HTTP server quickly; StructuralSynthesizer is loaded from the custom sysimage in the background.

### Custom sysimage (build-time)

The Dockerfile builds a **custom sysimage** with [PackageCompiler.jl](https://julialang.github.io/PackageCompiler.jl/stable/):

- **Scripts:** `scripts/api/build_sysimage.jl` (runner) and `scripts/api/sysimage_precompile.jl` (execution file that runs `using StructuralSynthesizer; register_routes!()`).
- **Build step:** PackageCompiler is added at image build time; `create_sysimage` is run with that precompile script; the result is written to `/app/sys.so`.
- **Runtime:** The container starts with `julia -J /app/sys.so --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl`, so startup is “load one sysimage” plus the bootstrap script, rather than loading many `.ji` files (or re-precompiling).

Cold start is typically on the order of tens of seconds to about a minute (loading the sysimage and native libs). The Grasshopper client waits up to 1 hour for “API ready” and offers a **Cancel** option. Building the image takes longer (sysimage build can be 15–30 minutes) but that happens in CI, not at request time.

### Storing the environment so startup isn’t necessary

The environment (packages + precompiled code) is already stored in the image under `/app/.julia`. Every new container gets that copy. There is no separate “cloud store” of the environment: App Runner doesn’t support persistent volumes, so you can’t persist a depot between container restarts. You can still reduce or hide cold start in these ways:

1. **Keep one instance warm**  
   In App Runner, set **Minimum capacity** to **1**. One container stays running; its in-memory state (loaded packages) stays hot. Cold start only happens when that instance is replaced (e.g. after a deploy). Trade-off: you pay for that instance even when idle.

2. **Match build and run environment**  
   Build the image for the same architecture and OS as the cloud (e.g. `linux/amd64`). In GitHub Actions, the default runner is amd64; App Runner is typically amd64. If they match, Julia is less likely to invalidate the precompiled cache at runtime. Ensure `JULIA_DEPOT_PATH` is the same at build and run (`/app/.julia` in the Dockerfile).

3. **Custom sysimage (PackageCompiler)** — **Implemented.** The image is built with a custom sysimage at `/app/sys.so` and the process starts with `julia -J /app/sys.so ...`. See **Custom sysimage (build-time)** above. To build the sysimage locally (e.g. to run with faster startup without Docker): add PackageCompiler (`using Pkg; Pkg.add("PackageCompiler")` in the StructuralSynthesizer project), then run `julia --project=StructuralSynthesizer scripts/api/build_sysimage.jl [path]` (default output: `sys.so` in the current directory). Start the API with `julia -J sys.so --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl`.

4. **Persistent volume (other services only)**  
   If you move off App Runner to something that supports volumes (e.g. ECS with EFS, or an EC2 instance with an EBS volume), you could put `JULIA_DEPOT_PATH` on that volume. The first run would populate it; later runs (or new containers mounting the same volume) would reuse it. App Runner does not support this.

**Summary:** The image stores the environment in a custom sysimage and in `/app/.julia`. Cold start is “load the sysimage + bootstrap.” To avoid cold start entirely, keep one instance warm (min capacity 1).

## AWS App Runner

The deployment uses AWS App Runner for managed container hosting:

- **Automatic scaling** — scales from 0 to N instances based on request volume
- **Health checks** — `GET /health` used for liveness probing
- **HTTPS termination** — handled by App Runner's load balancer

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

The Docker image build includes a **custom sysimage** step that can take **15–30 minutes**. The full workflow (build → push → App Runner update → smoke test) may approach or exceed **1 hour**.

- **AWS credentials:** The workflow uses OIDC to assume an IAM role. Default temporary credentials last **1 hour**. The workflow requests **2 hours** (`role-duration-seconds: 7200`) so they don’t expire during a long build. The **IAM role** used for OIDC must allow this: in AWS IAM → your role → **Maximum session duration** set to at least **2 hours** (7200 seconds). If you leave it at 1 hour, the job can fail with expired credentials when pushing to ECR or updating App Runner.
- **Job timeout:** The deploy job has a **120-minute** limit (`timeout-minutes: 120`). If the build or deploy hangs, the job is cancelled instead of running for hours.
- **Sysimage step:** Inside the Dockerfile, the sysimage build has a **45-minute** timeout (`timeout 2700`). If PackageCompiler takes longer on the runner, that step fails; you can increase `2700` in the Dockerfile if needed.

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

Bootstrap mode is preferred for production because App Runner requires a health check response within a timeout. The bootstrap server responds to `/health` immediately and returns `{"status": "warming"}` for `/status` until the full package is loaded.

## Environment Variables

| Variable | Description | Default |
|:---------|:------------|:--------|
| `PORT` / `SIZER_PORT` | HTTP listen port | `8080` |
| `SIZER_HOST` | Bind address | `0.0.0.0` |
| `SS_ENABLE_VISUALIZATION` | Include visualization data in API output | `false` |
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
- **`SS_ENABLE_VISUALIZATION`** — visualization data (node positions, frame elements, deflected meshes) adds significant serialization overhead. Disable for API-only use cases.

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
