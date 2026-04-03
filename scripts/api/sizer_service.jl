# =============================================================================
# Sizer REST API Service — Runner Script
# =============================================================================
#
# Start the structural sizing API server:
#   julia --project=StructuralSynthesizer scripts/api/sizer_service.jl
#
# Options (environment variables):
#   PORT       — HTTP port (AWS App Runner uses this, default 8080)
#   SIZER_PORT — HTTP port (legacy, default 8080)
#   SIZER_HOST — Bind address (default "0.0.0.0")
# =============================================================================

# API runtime is headless; avoid compiling visualization stack on startup.
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using StructuralSynthesizer

const PORT = parse(Int, get(ENV, "PORT", get(ENV, "SIZER_PORT", "8080")))
const HOST = get(ENV, "SIZER_HOST", "0.0.0.0")

@info "Registering API routes..."
register_routes!()

@info "Starting Structural Sizer API on http://$HOST:$PORT"
@info "Endpoints: POST /design, POST /validate, POST /reset, GET /health, GET /status, GET /schema, GET /env-check, GET /result, GET /logs"

# Oxygen.serve blocks until interrupted (Ctrl-C)
using Oxygen
serve(; host=HOST, port=PORT)
