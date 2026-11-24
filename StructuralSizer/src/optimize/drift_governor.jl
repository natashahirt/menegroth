# ==============================================================================
# Drift governor — catalog-aware outer loop driving a model to its drift limits
# ==============================================================================
#
# Ties the virtual-work participation query (Asap) to the optimality-criteria
# resizer and a discrete section catalog, iterating resize → snap → re-solve
# until every drift limit is met on the actual (discrete) structure:
#
#   1. solve the model and measure the current drifts;
#   2. assemble each limit's virtual-load column (a linear functional on the
#      DOFs) and query every limit's member participation c_{e,j} in ONE batched
#      multi-RHS solve (`drift_participation(model, V; links)`);
#   3. subtract the drift carried by *non-sized* members (a concrete core, say)
#      so the sized frame members are held to the remaining budget;
#   4. run `drift_optimality_resize_multi` for continuous target stiffnesses;
#   5. snap each target up to the lightest catalog section that is at least the
#      target and at least the member's strength floor;
#   6. apply, re-solve, and repeat until the real drifts are within tolerance.
#
# The model coupling is through two callbacks (`current_I`, `apply_I!`) and a
# per-member `catalog`, so the same driver serves steel W-shapes, HSS, or RC
# columns; wiring it to a specific lateral system and its strength checks is the
# caller's job. Snapping *up* keeps the discrete structure on the safe side of
# the continuous optimum (never softer than the sizing target).
#
# Rigid-diaphragm models: pass `links` (the model's rigid links). Both the
# re-solve and the batched participation query then run on the reduced
# master/slave system, so the diaphragm-master story DOFs the drift constraints
# reference stay consistent between the solve and the sensitivity.

"""
    DriftConstraint(dofs, coeffs, δ_allow)

A single drift limit `Σ_i coeffs[i]·u[dofs[i]] ≤ δ_allow` on the model's free
DOFs. Use [`total_drift_constraint`](@ref) for a single DOF against ground and
[`interstory_drift_constraint`](@ref) for an inter-story difference.
"""
struct DriftConstraint
    dofs::Vector{Int}
    coeffs::Vector{Float64}
    δ_allow::Float64
end

"""
    total_drift_constraint(dof, δ_allow)

Limit on a single DOF measured from the (fixed) base — e.g. a wind
serviceability cap `H/400` at the roof.
"""
total_drift_constraint(dof::Integer, δ_allow::Real) =
    DriftConstraint([Int(dof)], [1.0], Float64(δ_allow))

"""
    interstory_drift_constraint(top_dof, bottom_dof, δ_allow)

Inter-story drift limit `u[top_dof] − u[bottom_dof] ≤ δ_allow` (ASCE 7 §12.12).
"""
interstory_drift_constraint(top_dof::Integer, bottom_dof::Integer, δ_allow::Real) =
    DriftConstraint([Int(top_dof), Int(bottom_dof)], [1.0, -1.0], Float64(δ_allow))

"""
    DriftGovernorResult

Outcome of [`resize_for_drift!`](@ref):

- `converged` — every drift limit (and, with `floor_I_fn`, the strength floor)
                met on the re-solved discrete structure.
- `status`    — `:converged`, `:max_iters`, or `:background_infeasible`
                (non-sized members alone exceed a limit).
- `outer_iterations` — resize/re-solve passes taken.
- `drift`, `ratio`   — final actual drift and `drift/δ_allow` per constraint.
- `sizes`     — final stiffness variable per sized member.
"""
struct DriftGovernorResult
    converged::Bool
    status::Symbol
    outer_iterations::Int
    drift::Vector{Float64}
    ratio::Vector{Float64}
    sizes::Vector{Float64}
end

"""
    snap_up(target, catalog) -> value

Smallest catalog entry `≥ target`; if none qualifies, the largest entry (and the
caller should treat the member as catalog-limited). `catalog` need not be sorted.
"""
function snap_up(target::Real, catalog::AbstractVector{<:Real})
    best = -Inf
    found = false
    lo = Inf
    @inbounds for c in catalog
        c < lo && (lo = c)
        if c ≥ target && (!found || c < best)
            best = c
            found = true
        end
    end
    isinf(lo) && throw(ArgumentError("snap_up: catalog is empty."))
    found ? best : maximum(catalog)
end

"""
    resize_for_drift!(model, constraints; kwargs...) -> DriftGovernorResult

Drive `model` to satisfy every [`DriftConstraint`](@ref) by iterating
optimality-criteria resizing, catalog snapping, and re-solving. `model` is a
solved-capable Asap model.

Keyword arguments:
- `sized_elements` — indices (into `model.elements`) of members to size
  (default: all). Members outside this set are treated as fixed background.
- `weight`   — marginal weight-per-stiffness per sized member (length matches
  `sized_elements`).
- `floor_I`  — a hard strength-floor stiffness per sized member (absolute lower
  bound, held across the whole loop).
- `floor_I_fn` — optional callback `(model, u::Vector) -> Vector{Float64}`
  (length `sized_elements`) giving the strength-governed stiffness floor at a
  displacement `u`. Supplied, the **strength↔drift coupling** is folded into the
  loop: the floor is recomputed each outer iteration from the just-solved
  (exact) forces, and (with `accelerate`) *predicted* at the proposed sizes via
  one cached-factor back-substitution so redistribution is anticipated before
  the next re-solve. Must be a pure function of `(model, u)`. Convergence then
  requires both drift and strength to be met.
- `accelerate` (default `true`) — use the first-order `linear_response`
  predictor to pre-floor against redistributed demands (no effect without
  `floor_I_fn`). `accel_trust` (default `0.3`) is the step trust region: the
  predictor is used only when the proposed relative stiffness change is below it,
  since first-order prediction is unreliable for large jumps.
- `catalog`  — discrete stiffness values to snap to, or `nothing` for continuous.
- `current_I`, `apply_I!` — read/write the member's stiffness variable on an
  `Asap` element: `current_I(el)::Float64` and `apply_I!(el, I)`.
- `links` — the model's rigid links for a rigid-diaphragm model (default
  `nothing`). When given, the re-solve, the participation query, and the
  predictor all run on the reduced master/slave system.
- `max_outer` (default 10), `tol` (default 1e-2 on `drift/δ_allow`).
- `resize_kwargs` — forwarded to `drift_optimality_resize_multi`.

Each iteration sizes every member to the larger of its drift target and its
strength floor, recomputed from the current exact solve, and re-solves; the loop
stops when both are satisfied. The optional accelerator only pre-floors against
*predicted* redistribution to reach that joint fixpoint in fewer iterations — it
does not change the design the loop converges to.
"""
function resize_for_drift!(model, constraints::AbstractVector{DriftConstraint};
                           sized_elements::AbstractVector{<:Integer} = collect(1:length(model.elements)),
                           weight::AbstractVector{<:Real},
                           floor_I::AbstractVector{<:Real},
                           floor_I_fn::Union{Nothing,Function} = nothing,
                           accelerate::Bool = true, accel_trust::Real = 0.3,
                           catalog::Union{Nothing,AbstractVector{<:Real}} = nothing,
                           current_I::Function, apply_I!::Function,
                           links::Union{Nothing,AbstractVector} = nothing,
                           max_outer::Integer = 10, tol::Real = 1e-2,
                           resize_kwargs = (;))
    ns = length(sized_elements)
    m = length(constraints)
    length(weight) == ns || throw(ArgumentError("resize_for_drift!: weight must match sized_elements ($ns)."))
    length(floor_I) == ns || throw(ArgumentError("resize_for_drift!: floor_I must match sized_elements ($ns)."))

    drift_of(con) = sum(con.coeffs[i] * model.u[con.dofs[i]] for i in eachindex(con.dofs))
    # Route the solve through the reduced system when the model has a rigid
    # diaphragm, so model.u and the cached factor match the participation query.
    dosolve!() = links === nothing ? Asap.solve!(model) : Asap.solve!(model, links)

    # Strength floor at a displacement field (hard floor_I ∨ the callback).
    strength_floor(u) = floor_I_fn === nothing ? Float64.(floor_I) :
                        max.(Float64.(floor_I), Float64.(floor_I_fn(model, u)))

    # First-order predictor (optimality accelerator): the strength floor the next
    # re-solve will see at `target` sizes, WITHOUT a fresh factorization.
    #   1. Δu ≈ −K⁻¹(ΔK u) from one cached-factor back-substitution, where ΔK_e
    #      is the element stiffness delta at the trial section (Asap's
    #      non-mutating `global_K`).
    #   2. evaluate `floor_I_fn` at the predicted displacement AND the target
    #      element stiffnesses, so member demands are consistent with where the
    #      resize is going; `el.K`/`el.section` and `model.S`/the factor are all
    #      restored, so this never perturbs the real state.
    # The prediction only informs this iteration's target; the next exact solve
    # corrects any first-order error, so it changes convergence speed, not the
    # design it converges to.
    predict_floor(target) = begin
        f = zeros(model.nDOFs)
        K_save = Vector{Matrix{Float64}}(undef, ns)
        K_new = Vector{Matrix{Float64}}(undef, ns)
        @inbounds for (i, e) in enumerate(sized_elements)
            el = model.elements[e]
            I_old = current_I(el)
            K_save[i] = copy(el.K)
            apply_I!(el, target[i])              # trial section
            K_new[i] = Asap.global_K(el)         # target global stiffness
            apply_I!(el, I_old)                   # restore section (el.K intact)
            g = el.globalID
            f[g] .-= (K_new[i] .- K_save[i]) * view(model.u, g)   # −ΔK u
        end
        u_pred = model.u .+ Asap.linear_response(model, f; links = links)
        @inbounds for (i, e) in enumerate(sized_elements)   # el.K ← target
            copyto!(model.elements[e].K, K_new[i])
        end
        fl = strength_floor(u_pred)
        @inbounds for (i, e) in enumerate(sized_elements)   # el.K ← original
            copyto!(model.elements[e].K, K_save[i])
        end
        return fl
    end

    # One virtual-load column per constraint: V[:, j] = Σ_i coeffs[i]·e_{dofs[i]}.
    # (Built once — the DOFs and coefficients are fixed across outer iterations.)
    V = zeros(model.nDOFs, m)
    @inbounds for (j, con) in enumerate(constraints)
        for i in eachindex(con.dofs)
            V[con.dofs[i], j] += con.coeffs[i]
        end
    end

    sizes = Float64[current_I(model.elements[e]) for e in sized_elements]
    status = :max_iters
    outer_done = 0
    for outer in 1:max_outer
        outer_done = outer
        dosolve!()
        floor_now = strength_floor(model.u)      # exact strength floor this solve

        # Converged when BOTH drift and strength are satisfied at the current
        # (discrete) sizes.
        drift_ok = maximum(drift_of(con) / con.δ_allow for con in constraints) ≤ 1 + tol
        strength_ok = all(sizes[i] ≥ floor_now[i] * (1 - 1e-9) for i in 1:ns)
        if drift_ok && strength_ok
            status = :converged
            break
        end

        # Every limit's member participation from ONE batched multi-RHS solve on
        # the (reduced, if rigid-link) cached factor; then subtract the non-sized
        # background so the sized members own only the remaining budget.
        bdp = Asap.drift_participation(model, V; links = links)
        C = zeros(ns, m)
        δ_eff = zeros(m)
        background_infeasible = false
        @inbounds for j in 1:m
            for (i, e) in enumerate(sized_elements)
                C[i, j] = bdp.c[e, j]
            end
            background = drift_of(constraints[j]) - sum(@view C[:, j])
            δ_eff[j] = constraints[j].δ_allow - background
            δ_eff[j] ≤ 0 && (background_infeasible = true)
        end
        if background_infeasible
            status = :background_infeasible
            break
        end

        s = Float64[current_I(model.elements[e]) for e in sized_elements]
        res = drift_optimality_resize_multi(C, s, weight, floor_now, δ_eff; resize_kwargs...)
        drift_target = Float64[max(res.sizes[i], floor_now[i]) for i in 1:ns]

        # Accelerator: predict the redistributed demands at the drift target and
        # pre-floor against them, so the next re-solve finds strength already met
        # (folds the strength↔drift coupling into this iteration). The first-order
        # prediction is only trusted within a step trust region — a large
        # stiffness jump makes Δu ≈ −K⁻¹(ΔK u) unreliable (it overshoots), so on
        # the big early steps the exact `floor_now` is used and the predictor
        # refines only the small steps near convergence (where it is accurate and
        # cannot lock in an overshoot, since slack members are never shrunk).
        floor_ref = floor_now
        if accelerate && floor_I_fn !== nothing
            rel_step = maximum(abs(drift_target[i] - s[i]) / s[i] for i in 1:ns)
            if rel_step ≤ accel_trust
                floor_ref = max.(floor_now, predict_floor(drift_target))
            end
        end

        # Size each member to the larger of its drift target and strength floor,
        # recomputed fresh each iteration (no ratchet): a first-order prediction
        # overshoot is corrected by the next exact solve, so the accelerator
        # changes convergence speed, not the converged design.
        @inbounds for i in 1:ns
            t = max(drift_target[i], floor_ref[i])
            v = catalog === nothing ? t : snap_up(t, catalog)
            apply_I!(model.elements[sized_elements[i]], v)
            sizes[i] = v
        end
        Asap.update!(model; values_only = true)
    end

    dosolve!()   # reflect the last applied sizes
    drift = Float64[drift_of(con) for con in constraints]
    ratio = Float64[drift[j] / constraints[j].δ_allow for j in 1:m]
    return DriftGovernorResult(status == :converged, status, outer_done, drift, ratio, sizes)
end
