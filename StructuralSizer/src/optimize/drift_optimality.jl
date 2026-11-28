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

# ==============================================================================
# Multi-constraint resizer (several simultaneous drift limits)
# ==============================================================================
#
# A tall building is governed by many drift limits at once: an allowable
# inter-story drift at every story (ASCE 7 §12.12 under seismic) and a total-
# height wind serviceability limit (≈ H/400). Each limit j is a separable
# constraint on the same shared sizing variables s_e:
#
#     δ_j(s') = Σ_e γ_{e,j} / s'_e ≤ δ_allow_j,     γ_{e,j} = c_{e,j} · s_e,
#
# where c_{e,j} is member e's participation in drift j (one virtual load case per
# constraint; inter-story participations are differences of nodal ones, which is
# exact by linearity of the unit-load solve).
#
# Minimizing W = Σ w_e s'_e subject to all the limits gives the multi-constraint
# optimality criterion with one multiplier λ_j ≥ 0 per constraint (KKT):
#
#     w_e = Σ_j λ_j γ_{e,j} / s'^2_e   ⇒   s'_e = sqrt( (Σ_j λ_j γ_{e,j}) / w_e ),
#
# with complementary slackness λ_j (δ_j − δ_allow_j) = 0. The multipliers are the
# maximizer of the (concave) dual φ(λ); its gradient is the constraint residual
# g_j(λ) = δ_j(λ) − δ_allow_j and its Hessian is
#
#     H_{jk} = −Σ_e γ_{e,j} γ_{e,k} / (2 w_e s_e(λ)^3)   (members off their floor),
#
# so we solve g = 0 by a damped Newton method (quadratic convergence, robust to
# the near-degeneracy of coupled story-drift limits that cripples a first-order
# recursion), wrapped in an active set: start from the violated limits, drop any
# whose multiplier goes to zero (slack), and add any inactive limit that becomes
# violated. Strength floors enter through max(s_min, ·) in the size update and
# are simply excluded from the Hessian. Reduces to the single-constraint closed
# form when m = 1. (Khot/Berke; Chan, Grierson & Sherbourne 1995.)

"""
    MultiDriftOptimalityResult

Output of [`drift_optimality_resize_multi`](@ref):

- `sizes`  — new stiffness variable per member.
- `λ`      — one optimality multiplier per constraint (≈ 0 ⇒ non-binding).
- `frozen` — `true` where a member sits at its strength floor.
- `predicted_drift` — `δ_j = Σ γ_{e,j}/s'_e` per constraint at the new sizes.
- `active` — `true` where the constraint binds (`λ_j` meaningfully positive).
- `iterations` — total Newton iterations taken across the active-set passes.
- `converged`  — feasible and the sizes reached a fixed point within tolerance.
"""
struct MultiDriftOptimalityResult
    sizes::Vector{Float64}
    λ::Vector{Float64}
    frozen::Vector{Bool}
    predicted_drift::Vector{Float64}
    active::Vector{Bool}
    iterations::Int
    converged::Bool
end

"""
    drift_optimality_resize_multi(C, s, w, s_min, δ_allow; max_iters=50,
                                  tol=1e-8, λ_floor=1e-30) -> MultiDriftOptimalityResult

Size `s` against several simultaneous drift limits by a Newton dual over an
active set of constraints. `C` is the `n×m` participation matrix (`C[e,j]` =
member `e`'s participation in constraint `j`, with `sum(C[:,j]) == δ_j`, the
current drift for limit `j`); `w`, `s_min` are length-`n`; `δ_allow` is length
`m`. All inputs are plain `Float64` in consistent SI units. `tol` is the
relative constraint-residual tolerance and `max_iters` the Newton cap per
active-set pass.

Returns a [`MultiDriftOptimalityResult`](@ref). When every limit is already met
the sizes are returned unchanged.
"""
function drift_optimality_resize_multi(C::AbstractMatrix{<:Real}, s::AbstractVector{<:Real},
                                       w::AbstractVector{<:Real}, s_min::AbstractVector{<:Real},
                                       δ_allow::AbstractVector{<:Real};
                                       max_iters::Integer = 50, tol::Real = 1e-8,
                                       λ_floor::Real = 1e-30)
    n, m = size(C)
    (length(s) == n && length(w) == n && length(s_min) == n) || throw(ArgumentError(
        "drift_optimality_resize_multi: s, w, s_min must have length size(C,1) = $n."))
    length(δ_allow) == m || throw(ArgumentError(
        "drift_optimality_resize_multi: δ_allow must have length size(C,2) = $m."))
    all(>(0), δ_allow) || throw(ArgumentError("drift_optimality_resize_multi: δ_allow must be > 0."))
    all(>(0), s)       || throw(ArgumentError("drift_optimality_resize_multi: current sizes s must be > 0."))
    all(>(0), w)       || throw(ArgumentError("drift_optimality_resize_multi: weights w must be > 0."))
    all(≥(0), s_min)   || throw(ArgumentError("drift_optimality_resize_multi: strength floors s_min must be ≥ 0."))

    wv = Float64.(collect(w))
    smin = Float64.(collect(s_min))
    dall = Float64.(collect(δ_allow))
    γ = Float64[C[e, j] * s[e] for e in 1:n, j in 1:m]   # stiffness-free coefficients
    δ_now = zeros(m)                                       # current drift per constraint
    @inbounds for j in 1:m
        δ_now[j] = sum(C[e, j] for e in 1:n)              # = Σ γ_{e,j}/s_e at current s
    end

    # All limits already satisfied → leave the members alone.
    if all(δ_now[j] ≤ dall[j] for j in 1:m)
        return MultiDriftOptimalityResult(Float64.(collect(s)), zeros(m), falses(n),
                                          δ_now, falses(m), 0, true)
    end

    sbuf = zeros(n)
    floored = falses(n)
    # s_e(λ) = max(s_min_e, sqrt( (Σ_j λ_j γ_{e,j}) / w_e )); mark floored members.
    compute_sizes! = function (λ)
        @inbounds for e in 1:n
            num = 0.0
            for j in 1:m
                num += λ[j] * γ[e, j]
            end
            se = num > 0 ? sqrt(num / wv[e]) : 0.0
            if se < smin[e]
                sbuf[e] = smin[e]; floored[e] = true
            else
                sbuf[e] = se;      floored[e] = false
            end
        end
    end
    drift(j) = begin
        acc = 0.0
        @inbounds for e in 1:n
            sbuf[e] > 0 && (acc += γ[e, j] / sbuf[e])
        end
        acc
    end
    single_λ(j) = begin
        S = 0.0
        @inbounds for e in 1:n
            γ[e, j] > 0 && (S += sqrt(γ[e, j] * wv[e]))
        end
        (S / dall[j])^2
    end

    # Active set of binding constraints; warm-start the violated ones.
    active = falses(m)
    λ = zeros(m)
    @inbounds for j in 1:m
        if δ_now[j] > dall[j]
            active[j] = true
            λ[j] = single_λ(j)
        end
    end

    iters = 0
    for _pass in 1:(m + 2)
        A = findall(active)
        isempty(A) && break
        k = length(A)

        # Newton on the active set: solve g_A(λ_A) = 0, g_j = δ_j(λ) − δ_allow_j.
        for _ in 1:max_iters
            iters += 1
            compute_sizes!(λ)
            g = Float64[drift(A[a]) - dall[A[a]] for a in 1:k]
            maxrel = 0.0
            @inbounds for a in 1:k
                maxrel = max(maxrel, abs(g[a]) / dall[A[a]])
            end
            maxrel < tol && break

            # Hessian H_{ab} = −Σ_{e off floor} γ_{e,A[a]} γ_{e,A[b]} / (2 w_e s_e^3).
            H = zeros(k, k)
            @inbounds for e in 1:n
                floored[e] && continue
                f = 1.0 / (2 * wv[e] * sbuf[e]^3)
                for a in 1:k
                    ga = γ[e, A[a]]
                    ga == 0 && continue
                    for b in a:k
                        H[a, b] -= ga * γ[e, A[b]] * f
                    end
                end
            end
            @inbounds for a in 1:k, b in (a + 1):k   # symmetrize
                H[b, a] = H[a, b]
            end

            # Newton step for the concave dual: Δ = −H⁻¹ g (gradient step if singular).
            Δ = try
                -(H \ g)
            catch
                -g
            end

            # Largest α ≤ 1 keeping every active λ ≥ 0, then backtrack on ‖g‖.
            αmax = 1.0
            @inbounds for a in 1:k
                Δ[a] < 0 && (αmax = min(αmax, -λ[A[a]] / Δ[a]))
            end
            α = min(1.0, αmax)
            g0 = sum(abs2, g)
            λtrial = copy(λ)
            accepted = false
            for _ls in 1:40
                @inbounds for a in 1:k
                    λtrial[A[a]] = max(0.0, λ[A[a]] + α * Δ[a])
                end
                compute_sizes!(λtrial)
                gt = 0.0
                @inbounds for a in 1:k
                    gt += abs2(drift(A[a]) - dall[A[a]])
                end
                if gt ≤ g0 || α < 1e-12
                    @inbounds for a in 1:k
                        λ[A[a]] = λtrial[A[a]]
                    end
                    accepted = true
                    break
                end
                α /= 2
            end
            accepted || break
        end

        # Active-set update: drop slack limits (λ → 0), add newly violated ones.
        changed = false
        @inbounds for j in A
            if λ[j] ≤ λ_floor
                active[j] = false; λ[j] = 0.0; changed = true
            end
        end
        compute_sizes!(λ)
        @inbounds for j in 1:m
            if !active[j] && drift(j) > dall[j] * (1 + tol)
                active[j] = true; λ[j] = single_λ(j); changed = true
            end
        end
        changed || break
    end

    compute_sizes!(λ)
    s_new = copy(sbuf)
    frozen = copy(floored)
    δ_pred = Float64[drift(j) for j in 1:m]
    feasible = all(δ_pred[j] ≤ dall[j] * (1 + 1e-6) for j in 1:m)
    active_out = Bool[λ[j] > λ_floor for j in 1:m]
    # Converged = feasible with every binding limit tight.
    converged = feasible && all(!active_out[j] || abs(δ_pred[j] / dall[j] - 1) ≤ 1e-5
                                for j in 1:m)
    return MultiDriftOptimalityResult(s_new, copy(λ), frozen, δ_pred, active_out, iters, converged)
end
