# ==============================================================================
# Drift optimality-criteria resizer (virtual-work drift participation)
# ==============================================================================
#
# Given per-member drift-participation coefficients `c` (from Asap's
# `drift_participation`: c_e = u_vᵀ K_e u_r, with Σ c_e = δ, the current drift at
# a controlled DOF) and the current stiffness variables `s` (e.g. the second
# moment of area I), the drift is separable to first order — real and virtual
# forces held fixed within a resize step:
#
#     δ(s') = Σ_e γ_e / s'_e,     γ_e = c_e · s_e   (the stiffness-free coefficient).
#
# Minimizing weight W = Σ w_e s'_e subject to δ(s') ≤ δ_allow and s'_e ≥ s_min_e
# gives the optimality criterion: for members off their strength floor,
#
#     s'_e = sqrt(λ γ_e / w_e),     w_e s'_e² / γ_e = λ   (KKT stationarity),
#
# with a single multiplier λ fixed by the active drift budget
#
#     √λ = (Σ_active √(γ_e w_e)) / (δ_allow − Σ_frozen γ_e/s_min_e).
#
# Members whose optimal size falls below the strength floor are frozen there and
# still spend γ_e/s_min_e of the budget; the rest share what remains. This is a
# small active-set loop over the one scalar λ.
#
# Material is allocated where drift-participation-per-unit-weight (γ_e/w_e) is
# highest — the general, near-minimum-weight distribution for a drift constraint,
# replacing any uniform step-up heuristic.
#
# This routine is PURE (vectors in, vectors out, consistent SI units): the FE
# participation comes from Asap, and the catalog snap + outer re-solve loop live
# in the caller. Negative- or zero-participation members (growing them would not
# reduce the drift) are held at their strength floor.
#
# References: Baker (1990), energy-based design of lateral systems; Chan,
# Grierson & Sherbourne (1995), optimality criteria for drift-controlled tall
# steel buildings; Maxwell–Mohr unit-load theorem.

"""
    DriftOptimalityResult

Output of [`drift_optimality_resize`](@ref):

- `sizes`  — new stiffness variable per member (`s'`), with strength floors applied.
- `λ`      — the optimality multiplier (0 when the drift constraint is inactive).
- `frozen` — `true` where the member is pinned to its strength floor `s_min`.
- `predicted_drift` — `Σ γ_e / s'_e`, the first-order drift at the new sizes
                      (`== δ_allow` when the constraint binds and is feasible,
                      `< δ_allow` when strength floors over-satisfy it).
- `active` — `true` when the drift constraint was binding (sizes changed).
"""
struct DriftOptimalityResult
    sizes::Vector{Float64}
    λ::Float64
    frozen::Vector{Bool}
    predicted_drift::Float64
    active::Bool
end

"""
    drift_optimality_resize(c, s, w, s_min, δ_allow) -> DriftOptimalityResult

Size the drift-stiffness variables `s` (e.g. I per member) to the allowable
drift `δ_allow` by the virtual-work optimality criterion, given per-member drift
participation `c` (`Σ c == δ`, the current drift), marginal weights-per-stiffness
`w`, and strength floors `s_min`. All inputs are plain `Float64` in consistent
SI units; see the file header for the formulation.

Returns a [`DriftOptimalityResult`](@ref). When the current drift already meets
`δ_allow` the sizes are returned unchanged (`active = false`).
"""
function drift_optimality_resize(c::AbstractVector{<:Real}, s::AbstractVector{<:Real},
                                 w::AbstractVector{<:Real}, s_min::AbstractVector{<:Real},
                                 δ_allow::Real)
    n = length(c)
    (length(s) == n && length(w) == n && length(s_min) == n) || throw(ArgumentError(
        "drift_optimality_resize: c, s, w, s_min must have equal length; got " *
        "$(length(c)), $(length(s)), $(length(w)), $(length(s_min))."))
    δ_allow > 0 || throw(ArgumentError("drift_optimality_resize: δ_allow must be > 0; got $δ_allow."))
    all(>(0), s)     || throw(ArgumentError("drift_optimality_resize: all current sizes s must be > 0."))
    all(>(0), w)     || throw(ArgumentError("drift_optimality_resize: all weights w must be > 0."))
    all(≥(0), s_min) || throw(ArgumentError("drift_optimality_resize: strength floors s_min must be ≥ 0."))

    γ = Float64[c[e] * s[e] for e in 1:n]          # stiffness-free coefficients
    δ_now = sum(c)                                  # current drift = Σ γ_e/s_e

    # Inactive constraint: already within the limit → leave the members alone.
    if δ_now ≤ δ_allow
        return DriftOptimalityResult(Float64.(s), 0.0, falses(n), δ_now, false)
    end

    frozen = falses(n)
    # Members that cannot help (γ ≤ 0: zero or adverse participation) are pinned
    # to their floor up front; they still carry γ_e/s_min of the budget.
    @inbounds for e in 1:n
        γ[e] ≤ 0 && (frozen[e] = true)
    end

    s_new = Float64.(collect(s))
    @inbounds for e in 1:n
        frozen[e] && (s_new[e] = Float64(s_min[e]))
    end

    λ = 0.0
    for _pass in 1:(n + 1)
        δ_frozen = 0.0
        @inbounds for e in 1:n
            if frozen[e]
                fl = Float64(s_min[e])
                δ_frozen += fl > 0 ? γ[e] / fl : 0.0
            end
        end
        δ_active = δ_allow - δ_frozen

        # No active budget or no active members: floor the remainder and stop.
        if δ_active ≤ 0 || all(frozen)
            @inbounds for e in 1:n
                if !frozen[e]
                    s_new[e] = Float64(s_min[e])
                    frozen[e] = true
                end
            end
            break
        end

        # √λ from Σ_active γ_e/s'_e = δ_active with s'_e = √(λ γ_e/w_e).
        S = 0.0
        @inbounds for e in 1:n
            frozen[e] || (S += sqrt(γ[e] * w[e]))
        end
        sqrtλ = S / δ_active
        λ = sqrtλ^2

        newly_frozen = false
        @inbounds for e in 1:n
            frozen[e] && continue
            se = sqrt(λ * γ[e] / w[e])
            if se < Float64(s_min[e])
                s_new[e] = Float64(s_min[e])
                frozen[e] = true
                newly_frozen = true
            else
                s_new[e] = se
            end
        end
        newly_frozen || break
    end

    predicted = 0.0
    @inbounds for e in 1:n
        predicted += s_new[e] > 0 ? γ[e] / s_new[e] : 0.0
    end
    return DriftOptimalityResult(s_new, λ, frozen, predicted, true)
end
