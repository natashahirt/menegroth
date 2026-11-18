# ==============================================================================
# AISC Capacity Checker
# ==============================================================================
# Implements AbstractCapacityChecker for AISC 360 steel design.

"""
    AISCChecker <: AbstractCapacityChecker

AISC 360-16 capacity checker for steel members.

# Options
- `ϕ_b`: Resistance factor for flexure (default 0.9)
- `ϕ_c`: Resistance factor for compression (default 0.9)
- `ϕ_v`: Resistance factor for shear (`nothing` = per-provision: 1.00 only
  for AISC 360-16 §G2.1(a) rolled I-webs, else 0.90). An explicit value overrides.
- `ϕ_t`: Resistance factor for tension (default 0.9)
- `deflection_limit`: Optional L/δ LL-only limit (e.g., 1/360)
- `total_deflection_limit`: Optional L/δ DL+LL limit (e.g., 1/240)
- `max_depth`: Maximum section depth constraint
- `prefer_penalty`: Penalty factor for non-preferred sections (default 1.0 = no penalty)
- `shell_spans`: One vector of [`SteelShellSpan`](@ref) per demand, from the
  story shell. Each is a live-load check against `deflection_limit` on its own
  span, separate from the frame-model deflection. Empty skips it.

# Usage
```julia
checker = AISCChecker(; deflection_limit=1/360, total_deflection_limit=1/240)
feasible = is_feasible(checker, W("W14x22"), A992_Steel, demand, geometry)
```
"""
struct AISCChecker <: AbstractCapacityChecker
    ϕ_b::Float64
    ϕ_c::Float64
    ϕ_v::Union{Nothing, Float64}
    ϕ_t::Float64
    deflection_limit::Union{Nothing, Float64}
    total_deflection_limit::Union{Nothing, Float64}
    max_depth::Float64  # meters, Inf for no limit
    prefer_penalty::Float64
    shell_spans::Vector{Vector{SteelShellSpan}}
end

function AISCChecker(;
    ϕ_b = 0.9,
    ϕ_c = 0.9,
    ϕ_v = nothing,
    ϕ_t = 0.9,
    deflection_limit = nothing,
    total_deflection_limit = nothing,
    max_depth = Inf,
    prefer_penalty = 1.0,
    shell_spans = Vector{SteelShellSpan}[],
)
    max_d = to_meters(max_depth)
    spans = Vector{SteelShellSpan}[collect(SteelShellSpan, s) for s in shell_spans]
    AISCChecker(ϕ_b, ϕ_c, ϕ_v, ϕ_t, deflection_limit, total_deflection_limit, max_d,
                prefer_penalty, spans)
end

