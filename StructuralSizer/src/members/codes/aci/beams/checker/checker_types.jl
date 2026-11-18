# ==============================================================================
# ACI 318-11 Capacity Checker for RC Beams
# ==============================================================================
# Implements AbstractCapacityChecker for ACI 318 beam design.
# Matches the interface used by ACIColumnChecker / AISCChecker for MIP
# optimization via `optimize_discrete`.
#
# Checks:
#   1. Flexural capacity: φMn ≥ Mu (sagging, catalog bottom steel)
#   2. Negative-moment section adequacy: φMn_neg ≥ Mu_neg (hogging, candidate top steel)
#   3. Shear section adequacy: Vu ≤ φ(Vc + Vs,max)
#   4. Depth constraint: h ≤ max_depth
#   5. Net tensile strain: εt ≥ 0.004 (ACI 318-11 §10.3.5)
#   6. Minimum reinforcement: As ≥ As,min (ACI 318-11 §10.5.1)
#
# Shear note: This checker verifies that the cross-section is geometrically
# large enough to resist the applied shear (i.e., Vs_required ≤ Vs_max).
# Detailed stirrup spacing design is performed after section selection.
# ==============================================================================

using Asap: kip, ksi, to_ksi, to_kip, to_kipft

# ==============================================================================
# Checker Type
# ==============================================================================

"""
    ACIBeamChecker <: AbstractCapacityChecker

ACI 318-11 capacity checker for reinforced concrete beams.
Implements the same interface as AISCChecker / ACIColumnChecker for use
with `optimize_discrete`.

# Fields
- `fy_ksi`: Longitudinal rebar yield strength (ksi)
- `fyt_ksi`: Transverse (stirrup) rebar yield strength (ksi)
- `Es_ksi`: Rebar elastic modulus (ksi)
- `λ`: Lightweight concrete factor (1.0 for NWC)
- `max_depth`: Maximum section depth constraint (meters, Inf = no limit)
- `shell_spans`: Per demand, the [`RCShellSpan`](@ref)s of its beams on the
  cracked story shell. A candidate must meet every span's deflection limits.
- `shell_limits`: Limit types for those spans (`deflection_limit`)
- `joist_spacing_in`: Center-to-center rib spacing (in) when the demands are
  ribs of ACI 318-11 §8.13 joist construction; `0` otherwise. A T-section that
  meets §8.13.2 and §8.13.3 at this spacing gets the §8.13.8 `Vc` increase.
- `joist_direction`: `:one_way` or `:two_orthogonal` (§8.13.1)
- `stirrup_shear`: when `false`, shear adequacy is ``Vu \\le \\phi V_c`` and `Vs`
  is not credited. ENGINEERING JUDGMENT: ACI 318-11 §11.1.1 permits
  ``V_n = V_c + V_s``. A rib at a solid-head face is checked on concrete alone.

# Usage
```julia
checker = ACIBeamChecker(;
    fy_ksi  = 60.0,     # Grade 60 rebar
    fyt_ksi = 60.0,
    Es_ksi  = 29000.0,
)
```
"""
struct ACIBeamChecker <: AbstractCapacityChecker
    fy_ksi::Float64
    fyt_ksi::Float64
    Es_ksi::Float64
    λ::Float64
    max_depth::Float64      # meters

    # ── Optional deflection check (service loads) ──
    # When w_dead_kplf > 0, is_feasible also checks ACI §24.2 deflection.
    w_dead_kplf::Float64    # Service dead load (kip/ft), 0.0 = no deflection check
    w_live_kplf::Float64    # Service live load (kip/ft)
    defl_support::Symbol    # :simply_supported, :cantilever, etc.
    defl_ξ::Float64         # Time-dependent factor (2.0 = 5+ years)
    # Share of service live load in the sustained load (R9.5.2.5). 0 = dead only.
    defl_sustained_live::Float64

    # ── Optional story-shell deflection (see `rc_shell_span_deflection`) ──
    # `shell_spans[i]` are the spans of demand `i`; empty means no shell check.
    shell_spans::Vector{Vector{RCShellSpan}}
    shell_limits::Vector{Symbol}

    # ── Optional joist construction (ACI 318-11 §8.13) ──
    joist_spacing_in::Float64
    joist_direction::Symbol
    # ENGINEERING JUDGMENT. `false` withholds Vs at a solid-head face.
    # ACI 318-11 §11.1.1 permits Vc + Vs (corpus: aci-318-11).
    stirrup_shear::Bool
end

function ACIBeamChecker(;
    fy_ksi::Real  = 60.0,
    fyt_ksi::Real = 60.0,
    Es_ksi::Real  = 29000.0,
    λ::Real       = 1.0,
    max_depth     = Inf,
    w_dead_kplf::Real = 0.0,
    w_live_kplf::Real = 0.0,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Real = 2.0,
    defl_sustained_live::Real = 0.0,
    shell_spans::AbstractVector = Vector{RCShellSpan}[],
    shell_limits::AbstractVector{Symbol} = [:immediate_ll, :total],
    joist_spacing::Union{Nothing, Length} = nothing,
    joist_direction::Symbol = :one_way,
    stirrup_shear::Bool = true,
)
    max_d = isa(max_depth, Length) ? ustrip(u"m", max_depth) : Float64(max_depth)
    s_in = joist_spacing === nothing ? 0.0 : Float64(ustrip(u"inch", joist_spacing))
    ACIBeamChecker(Float64(fy_ksi), Float64(fyt_ksi), Float64(Es_ksi),
                   Float64(λ), max_d,
                   Float64(w_dead_kplf), Float64(w_live_kplf),
                   defl_support, Float64(defl_ξ),
                   _as_sustained_live_fraction(defl_sustained_live),
                   Vector{RCShellSpan}[collect(RCShellSpan, s) for s in shell_spans],
                   collect(Symbol, shell_limits),
                   s_in, joist_direction, stirrup_shear)
end

"""1 when stirrups may carry shear, 0 when the section is checked on concrete alone."""
_checker_vs_factor(checker::ACIBeamChecker) = checker.stirrup_shear ? 1.0 : 0.0

"""Worst story-shell deflection ratio of `section` over demand `i`'s spans; 0 with none."""
function _shell_deflection_ratio(checker::ACIBeamChecker, i::Int, section)
    isempty(checker.shell_spans) && return 0.0
    worst = 0.0
    for sp in checker.shell_spans[i]
        r = rc_shell_span_deflection(sp, section; ξ = checker.defl_ξ,
                                     limits = checker.shell_limits).ratio
        worst = max(worst, r)
    end
    return worst
end

"""Append the story-shell deflection check to `checks` when demand `i` has spans."""
function _push_shell_deflection_check!(checks, checker::ACIBeamChecker, i::Int, section)
    (isempty(checker.shell_spans) || isempty(checker.shell_spans[i])) && return checks
    r = _shell_deflection_ratio(checker, i, section)
    push!(checks, CheckResult("shell_deflection", r <= 1, r, r, 1.0, "ACI 318-11 9.5.2"))
    return checks
end

"""Message for a failed story-shell deflection check, or `nothing`."""
function _shell_deflection_message(checker::ACIBeamChecker, i::Int, section)
    r = _shell_deflection_ratio(checker, i, section)
    r <= 1 && return nothing
    return "Deflection (story shell): Δ/limit = $(round(r, digits = 2)) > 1 (ACI 318-11 §9.5.2)"
end

