
# ------------------------------------------------------------------------------
# Analytic sensitivities (∂ of drift / wall force w.r.t. each wall stiffness k_i)
# ------------------------------------------------------------------------------
# For u = K⁻¹ f with K = Σ k_i b_i b_iᵀ (f independent of k_i):
#   ∂u/∂k_i = −K⁻¹ (b_i b_iᵀ) u
# These support gradient-based layout optimization without finite differences.

"""
    story_drift_sensitivity(ev, walls, loads, story) -> Dict{Int,Float64}

Analytic `∂(drift_story)/∂k_i` for every wall `i` in `story`. Uses the adjoint of
the 3×3 story system (no finite differences).
"""
function story_drift_sensitivity(ev::ReducedDiaphragmEvaluator,
                                 walls::Vector{WallLine},
                                 loads::Vector{StoryLoad},
                                 story::Int)
    walls_s = [w for w in walls if w.story == story]
    sens = Dict{Int,Float64}(w.id => 0.0 for w in walls_s)
    isempty(walls_s) && return sens

    K = _assemble_story_K(walls_s)
    # Assemble the SAME load vector `f` as `evaluate_lateral`, INCLUDING the ASCE
    # 7-22 §12.8.4.2 accidental-eccentricity terms (5% of the plan dimension
    # perpendicular to each force direction; corpus: asce-7-22 §12.8.4.2.2, PDF
    # p. 187), so this analytic gradient is the exact derivative of the drift the
    # evaluator actually reports. Must stay term-for-term identical to the Mz
    # built in `evaluate_lateral` (same eax/eay, same `sign_nonzero` convention,
    # same `ev.accidental_ecc`); a mismatch here silently differentiates a
    # different load case than the primal.
    Fx = 0.0; Fy = 0.0; Mz = 0.0
    Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
    for ld in loads
        ld.story < story && continue
        Fx += ld.Fx; Fy += ld.Fy
        eax = ev.accidental_ecc * Lx
        eay = ev.accidental_ecc * Ly
        # Mz = Fy·x − Fx·y ; accidental eccentricity worsens the moment.
        Mz += ld.Fy * (ld.ex + sign_nonzero(ld.Fy) * eax) -
              ld.Fx * (ld.ey + sign_nonzero(ld.Fx) * eay)
    end
    f = [Fx, Fy, Mz]
    # Fail closed on a singular / near-singular story before solving (mirrors
    # `_solve_spd`): no `K + εI` fudge, no silent sensitivity on an unstable layout.
    # Same scale-normalized conditioning test (same L_ref) as the primal.
    Ksym = Symmetric(K)
    _assert_nonsingular_K(Ksym, _reference_length(ev, walls_s))
    Kfac = cholesky(Ksym)
    u = Kfac \ f
    h = ev.story_heights[story]
    δ = sqrt(u[1]^2 + u[2]^2)
    (h <= 0 || δ < 1e-12) && return sens

    # NOTE: this analytic sensitivity differentiates the ORIGIN-referenced translation
    # drift `sqrt(u₁²+u₂²)/h`, which equals the CENTER-OF-RIGIDITY drift that
    # `evaluate_lateral` now reports whenever there is no twist (φ = 0) or the layout
    # is symmetric (CR = origin) — the regime of the known-answer FD test. It is a
    # verified standalone utility, NOT the optimizer's gradient source: Ipopt uses
    # numerical gradients of the direction-complete `constraint_fns`, so the layout
    # solve is differentiating the actual (origin-invariant, direction-complete) drift.
    # d(drift)/dk_i = (1/h) * (u_xy · du_xy/dk_i)/δ, with du/dk_i = −K⁻¹(b b')u
    for w in walls_s
        b = collect(_wall_geometry_vector(w))
        du = -(Kfac \ (b * (b' * u)))
        sens[w.id] = (u[1]*du[1] + u[2]*du[2]) / (δ * h)
    end
    return sens
end
