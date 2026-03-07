# =============================================================================
# Run the lightweight Sizer API bootstrap (same entrypoint as Docker).
# From repo root:  julia scripts/runners/run_bootstrap_api.jl
# Server: GET http://127.0.0.1:8080/health and /status (then /design, /schema when ready).
# =============================================================================

using Pkg
repo = normpath(joinpath(@__DIR__, "..", ".."))
Pkg.activate(repo)
# StructuralSynthesizer is the API project; use it so deps match the image.
proj = joinpath(repo, "StructuralSynthesizer")
Pkg.activate(proj)

include(joinpath(repo, "scripts", "api", "sizer_bootstrap.jl"))
