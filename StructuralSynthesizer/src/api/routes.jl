# =============================================================================
# API Routes — Oxygen HTTP endpoint definitions
# =============================================================================

using HTTP
using Oxygen

include("routes/helpers.jl")
include("routes/schema_routes.jl")
include("routes/design_routes.jl")
include("routes/report_routes.jl")
include("routes/session_routes.jl")
include("../server/design_runner.jl")

# ─── Route registration ──────────────────────────────────────────────────────

"""Register all API routes with the Oxygen router."""
function register_routes!()
    _register_schema_routes!()
    _register_design_routes!()
    _register_report_routes!()
    _register_design_result_routes!()
    _register_session_routes!()
    register_chat_routes!()
    return nothing
end
