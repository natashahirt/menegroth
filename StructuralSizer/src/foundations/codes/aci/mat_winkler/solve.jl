# ─────────────────────────────────────────────────────────────────────────────
# No-tension (compression-only) Winkler iteration
# ─────────────────────────────────────────────────────────────────────────────

"""
    _solve_winkler!(model, springs, loads;
                    no_tension, max_iters, tol) → active

Solve the shell-on-Winkler model in place on an already-`process!`-d
`model`.  When `no_tension == true`, iteratively deactivates soil springs
whose nodes lift (`w > 0`) and reactivates springs whose nodes are pushed
back into compression (`w < 0`); this is the standard compression-only
Winkler model used by production tools such as spMats.

Returns the per-spring active mask at convergence.

The model is updated in place each iteration via `Asap.update!(model;
values_only=true)`, which rewrites `model.S` in place from the current
shell `K` matrices (so any thickness mutation made by the caller before
calling this function takes effect) and clears the cached factorization.
The active-set subset of springs is then re-added to `model.S` and the
linear system is re-solved.

Raises an error if the active set fails to settle within `max_iters` (no
silent fallback).  A spring is treated as numerically pinned to `w = 0` if
`|w| ≤ 1e-9 m`; this hysteresis band prevents oscillation on near-zero
displacements without affecting any practical case.

The two-way model (`no_tension == false`) corresponds to the legacy linear
Winkler analysis kept for diagnostic comparisons.
"""
function _solve_winkler!(
    model::Model,
    springs::Vector{Spring},
    loads::Vector{<:NodeForce};
    no_tension::Bool = true,
    max_iters::Int = 20,
    tol::Float64 = 5e-3,
)
    n_springs = length(springs)
    active = trues(n_springs)
    eps_w  = 1e-9            # |w| below this is numerical zero (m)

    if !no_tension
        # Single-shot two-way Winkler (legacy diagnostic path)
        Asap.update!(model; values_only=true)   # refresh K + S from current section
        add_springs!(model, springs)
        solve!(model)
        return active
    end

    # No-tension iteration: deactivate uplift, reactivate re-engagement
    for it in 1:max_iters
        # Refresh element K from current properties and rewrite S in place,
        # then add the current active subset of springs on top.
        Asap.update!(model; values_only=true)
        active_springs = springs[active]
        isempty(active_springs) &&
            error("WinklerFEA no-tension solve diverged: every soil spring " *
                  "deactivated at iteration $it (model has lost all soil " *
                  "support — load case is non-physical or mesh is wrong).")
        add_springs!(model, active_springs)
        solve!(model)

        # Update active mask from the just-solved displacement field
        changed = false
        for i in 1:n_springs
            w = ustrip(u"m", springs[i].node.displacement[3])  # m, signed
            if active[i] && w >  eps_w
                active[i] = false; changed = true
            elseif !active[i] && w < -eps_w
                active[i] = true;  changed = true
            end
        end

        # Convergence: active set settled and net vertical residual within tol
        if !changed
            F_applied = sum(abs(ustrip(u"N", l.value[3])) for l in loads)
            F_react   = 0.0
            for i in 1:n_springs
                active[i] || continue
                kz = springs[i].stiffness[3]
                w  = ustrip(u"m", springs[i].node.displacement[3])
                F_react += kz * (-w)   # w < 0 ⇒ positive upward reaction
            end
            residual = F_applied > 0 ? abs(F_applied - F_react) / F_applied : 0.0
            residual ≤ tol && return active
            error("WinklerFEA no-tension solve: active set converged at " *
                  "iteration $it but residual " *
                  "$(round(100*residual, digits=2))% exceeds tol " *
                  "$(round(100*tol, digits=2))% (numerical issue — check " *
                  "spring stiffness and applied loads).")
        end
    end

    error("WinklerFEA no-tension solve did not converge in $max_iters " *
          "iterations (oscillating active set — consider raising " *
          "`max_no_tension_iters` or relaxing `no_tension_tol`).")
end

