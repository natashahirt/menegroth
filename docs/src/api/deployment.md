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
2. Instantiates the Julia project and precompiles dependencies
3. Runs `scripts/api/sizer_bootstrap.jl` as the entry point

The bootstrap entry point provides fast cold starts: the HTTP server is available immediately for health checks, while StructuralSynthesizer loads in the background.

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

### Required Secrets

| Secret | Description |
|:-------|:------------|
| `APP_RUNNER_SERVICE_ARN` | ARN of the App Runner service |
| `ECR_REPOSITORY` | ECR repository name |
| `APP_URL` | Public URL of the deployed service |

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
