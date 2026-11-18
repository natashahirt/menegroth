
function evaluate_lateral(ev::ReducedDiaphragmEvaluator,
                          walls::Vector{WallLine},
                          loads::Vector{StoryLoad};
                          active_ids::Union{Nothing,AbstractSet}=nothing,
                          wall_half_lengths::Union{Nothing,AbstractDict{Int,Float64}}=nothing)
    nstory = length(ev.story_heights)
    story_disp = zeros(nstory, 3)
    drift = zeros(nstory)
    torsion = ones(nstory)
    wall_forces = Dict{Int,Float64}()
    for w in walls
        wall_forces[w.id] = 0.0
    end

    # Cumulative story shear: the shear a story resists is the sum of the lateral
    # forces applied at and above it (shear-building idealization).
    for s in 1:nstory
        walls_s = [w for w in walls if w.story == s]
        isempty(walls_s) && continue
        K = _assemble_story_K(walls_s)

        # Cumulative force + torsional moment about the origin from all loads
        # at/above this story, including ASCE 7 accidental eccentricity (VERIFY).
        Fx = 0.0; Fy = 0.0; Mz = 0.0
        Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
        for ld in loads
            ld.story < s && continue
            Fx += ld.Fx; Fy += ld.Fy
            eax = ev.accidental_ecc * Lx
            eay = ev.accidental_ecc * Ly
            # Mz = Fy·x − Fx·y ; accidental eccentricity worsens the moment.
            Mz += ld.Fy * (ld.ex + sign_nonzero(ld.Fy) * eax) -
                  ld.Fx * (ld.ey + sign_nonzero(ld.Fx) * eay)
        end
        f = [Fx, Fy, Mz]

        u = _solve_spd(K, f, _reference_length(ev, walls_s))
        story_disp[s, :] .= u

        # Center of rigidity for this story (origin-invariant drift/torsion reference).
        # Safe: `_solve_spd` above has already confirmed `K` is positive-definite, so
        # the translational block is PD ⇒ `_center_of_rigidity`'s determinant is > 0.
        cr = _center_of_rigidity(K)

        # Interstory drift ratio for this story. This is a TRUE per-story
        # relative (interstory) displacement, NOT an absolute/cumulative-from-
        # base quantity: story `s` is modeled as an isolated 3-DOF spring whose
        # stiffness `K` is assembled only from story-`s` walls (`walls_s`), and
        # `u = K⁻¹ f` is therefore the deformation ACROSS story `s` alone under
        # that story's cumulative shear `f`. No base-to-floor accumulation enters
        # `u`, so `sqrt(u[1]^2 + u[2]^2)` is the relative translation between the
        # floors bounding story `s`, and dividing by the story height `h` gives
        # the interstory drift ratio Δ/h_sx compared against the allowable story
        # drift Δ_a (ASCE 7-22 §12.12.1 / Table 12.12-1, PDF p. 194-195).
        #
        # IDEALIZATION & LIMITATION: this is a shear-building model — stories are
        # DECOUPLED springs with NO cantilever flexural coupling across stories,
        # so this drift intentionally omits the rigid-body rotation a lower story
        # imposes on the ones above. Rigorous coupled multistory (cantilever)
        # drift is delegated to the unified-FEM tier (`FEMLateralEvaluator`); this
        # reduced value is a fast, differentiable inner-loop proxy, not a
        # substitute for it.
        #
        # ORIGIN INVARIANCE: the interstory drift is the magnitude of the rigid-body
        # translation of the diaphragm CENTER OF RIGIDITY (`_cr_translation`), not of
        # the arbitrary input origin. Both are identical when there is no twist (φ = 0)
        # or when the layout is symmetric (CR = origin), so this is backward-compatible
        # with the known-answer tests; it differs only for a torsionally-responding
        # asymmetric layout, where the CR translation is the physically meaningful,
        # origin-independent drift.
        h = ev.story_heights[s]
        tx, ty = _cr_translation(u, cr)
        drift[s] = h > 0 ? sqrt(tx^2 + ty^2) / h : 0.0

        # Torsional amplification δ_max/δ_avg (ASCE 7 §12.8.4.3 torsional-irregularity
        # metric; VERIFY) — EXACT realization at the four TRUE occupant corners. δ_avg is
        # taken at the CR so the ratio is origin-invariant; δ_max is evaluated EXACTLY over
        # the corners `plate_center ± (hx, hy)` (`_torsion_amplification` 4-arg; exact lever
        # `hypot(hx + |xr − cx|, hy + |yr − cy|)`), correct even when the CR lies outside the
        # plate. This GATES feasibility (the `res.torsion/torsion_limit` slot in
        # `constraint_fns` / `solve_wall_layout`). When `plate_center === nothing` the corners
        # cannot be located, so torsion certification is UNAVAILABLE and we FAIL CLOSED with
        # `Inf` — never a wall-centroid / origin / plate-span proxy (crit5/rev6/crit6); the
        # callers then refuse the layout (status=:geometry_required).
        #
        # ENCLOSURE GUARD (crit7, fail-closed): the four-corner metric is EXACT only if the
        # plate `plate_center ± plan_halfwidth` ENCLOSES the drift-relevant points. The two
        # FREE fields `plate_center`/`plan_halfwidth` are not otherwise cross-checked against
        # the wall positions, so an UNDER-COVERING plate would make this gate silently under-
        # state the twist (exact formula fails OPEN). When this story's walls are not ⊆ plate
        # we therefore also FAIL CLOSED to `Inf` (see `_plate_encloses_walls`); callers refuse
        # with `status = :geometry_inconsistent`.
        # `active_ids` masks density-removed candidates out of the enclosure proxy so a removed
        # wall parked outside the plate cannot fail-close this gate (nothing ⇒ all walls, as the
        # one-shot CHECK path and FEM tier require). `wall_half_lengths` (when supplied with the
        # mask) upgrades the proxy to the endpoint-aware body test so an over-hanging wall fails
        # closed (nothing ⇒ centroid-only, unchanged).
        torsion[s] = (ev.plate_center === nothing ||
                      !_plate_encloses_walls(ev, walls_s, active_ids, wall_half_lengths)) ? Inf :
                     _torsion_amplification(u, ev.plan_halfwidth, cr, ev.plate_center)

        # Recover per-wall in-plane shear force: V_i = k_i (b_i · u).
        for w in walls_s
            b = _wall_geometry_vector(w)
            wall_forces[w.id] = w.k * (b[1]*u[1] + b[2]*u[2] + b[3]*u[3])
        end
    end

    return LateralResult(story_disp, drift, wall_forces, torsion)
end

"""Sign that returns +1 for zero (so accidental eccentricity is always additive)."""
@inline sign_nonzero(x::Real) = x < 0 ? -1.0 : 1.0

"""
    _solve_spd(K, f, L_ref) -> u

Solve the 3×3 story system `K u = f` for a well-conditioned, positive-definite `K`.
FAILS CLOSED: a singular or near-singular `K` (a story with insufficient or
collinear walls to be laterally stable) raises [`SingularStiffnessError`](@ref)
rather than returning a pseudo-inverse or `K + εI`-perturbed solution that would
look plausible for an unstable layout. `L_ref` is the plan reference length used
to scale-normalize the conditioning test (see [`_assert_nonsingular_K`](@ref));
the SOLVE itself is an exact, unperturbed Cholesky on the UNSCALED `K`, so valid
results are not altered."""
function _solve_spd(K::Matrix{Float64}, f::Vector{Float64}, L_ref::Float64)
    Ksym = Symmetric(K)
    _assert_nonsingular_K(Ksym, L_ref)  # fail closed on singular / near-singular K
    return cholesky(Ksym) \ f
end

"""
    _torsion_amplification(u, halfwidth, cr, plan_center) -> δ_max/δ_avg

Corner drift amplification `δ_max/δ_avg` from the rigid-body displacement `u = [δx, δy,
φ]`, evaluating `δ_max` over the four corners `plan_center ± (hx, hy)`. `δ_avg` is the
translation magnitude at the diaphragm CENTER OF RIGIDITY `cr = (xr, yr)` (`_cr_translation`,
origin-invariant); each corner displacement is the rigid-diaphragm field
`disp(p) = (δx − φ·p_y, δy + φ·p_x) = δ_avg(CR) + φ × (p − CR)`.

USED BY the reduced evaluator (4-arg) once `ReducedDiaphragmEvaluator.plate_center` is known:
the corners are anchored to that TRUE plate center `(cx, cy)`, so the amplification is EXACT
regardless of where the CR sits (crit5/rev6 showed the earlier wall-centroid and plate-span-
bound proxies UNDER-stated an eccentric / non-orthogonal core, and both are removed). The FEM
tier (`fem_evaluator.jl`) uses the 2-arg form, whose master-node displacements are already
referenced to the diaphragm master at the DOF origin.
"""
function _torsion_amplification(u::Vector{Float64}, halfwidth::NTuple{2,Float64},
                                cr::NTuple{2,Float64}, plan_center::NTuple{2,Float64})
    tx, ty = _cr_translation(u, cr)
    δavg = sqrt(tx^2 + ty^2)
    δavg < 1e-12 && return 1.0
    hx, hy = halfwidth
    cx, cy = plan_center
    φ = u[3]
    δmax = δavg
    for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
        px = cx + sx * hx; py = cy + sy * hy     # TRUE corner anchored to the plan center
        dx = u[1] - φ * py                       # rigid-diaphragm displacement about the
        dy = u[2] + φ * px                       # DOF origin: (δx − φ·p_y, δy + φ·p_x)
        δmax = max(δmax, sqrt(dx^2 + dy^2))
    end
    return δmax / δavg
end

# 3-arg form: plan center defaults to the DOF origin (the model's natural frame, in which
# the plan is centered at the origin). Reduces exactly to evaluating the corners at
# `(±hx, ±hy)`.
_torsion_amplification(u::Vector{Float64}, halfwidth::NTuple{2,Float64},
                       cr::NTuple{2,Float64}) =
    _torsion_amplification(u, halfwidth, cr, (0.0, 0.0))

# Backward-compatible 2-arg form (CR AND plan center at the origin): preserves the prior
# behavior EXACTLY for callers that reference displacements to the plan origin — e.g. the
# FEM tier's master-node displacements in `fem_evaluator.jl`, which are already measured at
# the diaphragm master and NOT part of this origin-invariance change.
_torsion_amplification(u::Vector{Float64}, halfwidth::NTuple{2,Float64}) =
    _torsion_amplification(u, halfwidth, (0.0, 0.0), (0.0, 0.0))

