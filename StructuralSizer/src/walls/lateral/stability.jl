
"""
    eigenstructure_stability(ev, walls, loads, drift_limit; active_ids=nothing, wall_half_lengths=nothing) -> NamedTuple

`active_ids` (optional) is the SIMP optimizer's Set of ACTIVE candidate ids; when supplied it
masks density-removed walls out of the torsional-floor enclosure proxy (see
[`_plate_encloses_walls`]). `wall_half_lengths` (optional, candidate id → `lw/2`) upgrades that
proxy to the endpoint-aware body test (see [`_plate_encloses_walls`]); passed together with
`active_ids`. Both `nothing` (default) examines every wall by its centroid, leaving the one-shot
CHECK / FEM paths unchanged.

EIGENSTRUCTURE STABILITY GATE (reduced tier) — the stability authority for the cheap tier.
It reads the story stiffness EIGENSTRUCTURE directly (translational spectrum + condensed
torsional stiffness about the center of rigidity) and compares each against a PHYSICAL
anti-mechanism floor derived from the SAME drift limit `DL = drift_limit`. One check catches
translation + diagonal + torsion; the Phase 10 unified-FEM survivor cross-check is the FINAL
authority, and this is its fast proxy.

Per story `s`, from the assembled 3-DOF `K` over `[ux, uy, θ]`:

  * TRANSLATIONAL floor — require `λmin(K_tt) ≥ k_req_trans = F_s/(h·DL)`.
    Derivation: a resultant-equivalent edge load `F_s` acting on a translational mode of
    stiffness `k` produces interstory drift `δ/h = F_s/(k·h)`; requiring `δ/h ≤ DL` gives
    `k ≥ F_s/(h·DL)`. `λmin(K_tt)` is the softest translational mode (its eigenvector is the
    true worst direction), so this subsumes the discrete +X/+Y drift sweep and closes the √2
    diagonal-weak-mode gap. Utilization `util_trans = k_req_trans/λmin(K_tt)`.

  * TORSIONAL floor — require `K_theta_cr ≥ k_req_tors = F_s·e_acc·r_ref/(h·DL)`.
    Derivation: the accidental-torsion moment `M_acc = F_s·e_acc` twists the diaphragm by
    `φ = M_acc/K_theta_cr`; a plan corner at radius `r` from the CR then drifts `φ·r`, and
    `φ·r/h ≤ DL` gives `K_theta_cr ≥ M_acc·r/(h·DL)`. `r_ref` is the EXACT max CR-to-corner
    lever `max_corner hypot(corner − CR) = hypot(hx + |xr − cx|, hy + |yr − cy|)` over the four
    TRUE occupant corners `plate_center ± (hx, hy)` — correct even when the CR lies outside the
    plate. `K_theta_cr` (the Schur complement of `K_tt`) DIRECTLY observes the twist stiffness
    the CR-translation drift cannot. Utilization `util_tors = k_req_tors/K_theta_cr`. When
    `plate_center === nothing` the lever cannot be located: the torsional floor is UNAVAILABLE
    and FAILS CLOSED (`k_req_tors = util_tors = Inf`); the TRANSLATIONAL floor and the load-
    independent mechanism guards need no `plate_center` and still run.

`F_s = hypot(ΣFx, ΣFy)` is the per-story cumulative design-shear resultant magnitude —
EXACTLY the resultant `evaluate_lateral` / `direction_complete_interstory_drift` form. `e_acc`
and the plan dimensions are taken identically to `evaluate_lateral` so the two stay
consistent (see the ENGINEERING JUDGMENT comment below for `e_acc`).

The demand floors SCALE with `F_s`: a story with ~zero cumulative resultant has ~zero floor
and so cannot be the authority for a mechanism in an UNLOADED story. That case is handled by
the LOAD-INDEPENDENT mechanism guards here — a translational block at/below the numeric
singular threshold, or a condensed torsional stiffness at/below the numeric singular scale,
throws [`SingularStiffnessError`](@ref) regardless of load — plus the fail-closed `rcond`
backstop in `_solve_spd`. So a zero-shear story can NEVER silently waive the stability gate
for a genuine mechanism.

Returns per-story vectors `λmin_tt`, `λmax_tt`, `K_theta_cr`, `k_req_trans`, `k_req_tors`,
`util_trans`, `util_tors` (NaN/0 entries for stories with no walls). Throws
[`SingularStiffnessError`](@ref) on a genuine (load-independent) translational or torsional
mechanism; callers in the differentiable optimizer loop wrap it to a penalty sentinel.
"""
function eigenstructure_stability(ev::ReducedDiaphragmEvaluator,
                                  walls::Vector{WallLine},
                                  loads::Vector{StoryLoad},
                                  drift_limit::Real;
                                  active_ids::Union{Nothing,AbstractSet}=nothing,
                                  wall_half_lengths::Union{Nothing,AbstractDict{Int,Float64}}=nothing)
    nstory = length(ev.story_heights)
    λmin_tt = fill(NaN, nstory); λmax_tt = fill(NaN, nstory)
    K_theta = fill(NaN, nstory)
    k_req_trans = zeros(nstory); k_req_tors = zeros(nstory)
    util_trans = zeros(nstory); util_tors = zeros(nstory)

    Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
    # `r_ref` (the EXACT max CR-to-corner lever) is computed PER STORY in the loop below as
    # `max_corner hypot(corner − CR)` over the four TRUE occupant corners `plate_center ±
    # (hx, hy)` = `hypot(hx + |xr − cx|, hy + |yr − cy|)`. This is correct even when the CR
    # lies outside the plate (the non-orthogonal rev6 case). It REPLACES the removed plate-span
    # bound `hypot(2·hx, 2·hy)` and the earlier wall-centroid-eccentric estimate, both of which
    # could MIS-state the lever (crit5/rev6/crit6). When `plate_center === nothing` the corners
    # cannot be located and the torsional floor FAILS CLOSED (`util_tors = Inf`).
    # ENGINEERING JUDGMENT (direction-complete accidental eccentricity, not a code clause):
    # `evaluate_lateral` applies accidental eccentricity `accidental_ecc·L` about each plan
    # axis (eax = accidental_ecc·Lx, eay = accidental_ecc·Ly; accidental torsion per
    # ASCE 7-22 §12.8.4.2.2, as cited in `evaluate_lateral`). For the direction-complete
    # torsional floor we use the LARGER plan dimension, `e_acc = accidental_ecc·max(Lx, Ly)`,
    # so the floor bounds the accidental twist for a resultant in the worst direction
    # (conservative, consistent with sweeping both principal directions per §12.5). Reuses
    # the SAME `ev.accidental_ecc` as the primal — no invented ASCE magnitude.
    e_acc = ev.accidental_ecc * max(Lx, Ly)

    for s in 1:nstory
        walls_s = [w for w in walls if w.story == s]
        isempty(walls_s) && continue
        K = _assemble_story_K(walls_s)
        Lref = _reference_length(ev, walls_s)
        h = ev.story_heights[s]

        spec = _translational_block_spectrum(K)
        # LOAD-INDEPENDENT translational-mechanism guard (also the CR guard): K_tt is
        # unit-homogeneous (N/m), so λmin/λmax is a true reciprocal condition number. At or
        # below the numeric singular threshold the translational modes are a mechanism.
        if spec.λmax <= 0 || spec.λmin <= SINGULAR_STIFFNESS_RCOND * spec.λmax
            throw(SingularStiffnessError(
                "story $s translational block is singular / a mechanism " *
                "(λmin_tt=$(spec.λmin), λmax_tt=$(spec.λmax), rcond ≤ $(SINGULAR_STIFFNESS_RCOND)): " *
                "under-braced in a principal translational direction."))
        end

        Kθ = _torsional_stiffness_cr(K)
        # LOAD-INDEPENDENT torsional-mechanism guard. `K_theta_cr` carries units N·m; its
        # natural scale is λmax(K_tt)·L_ref² (translational stiffness × plan length²). A
        # condensed torsional stiffness at/below the numeric singular scale is a twist
        # mechanism — caught here REGARDLESS of applied shear, so a zero-shear story with a
        # torsional mechanism is not silently waived by the demand-scaled floor below.
        tors_scale = spec.λmax * Lref * Lref
        if Kθ <= SINGULAR_STIFFNESS_RCOND * tors_scale
            throw(SingularStiffnessError(
                "story $s condensed torsional stiffness about the CR is singular / a mechanism " *
                "(K_theta_cr=$(Kθ) ≤ rcond·λmax·L_ref² = $(SINGULAR_STIFFNESS_RCOND * tors_scale)): " *
                "the diaphragm can twist freely about the center of rigidity."))
        end

        # Cumulative design-shear resultant magnitude F_s (same resultant as the primal).
        Fx = 0.0; Fy = 0.0
        for ld in loads
            ld.story < s && continue
            Fx += ld.Fx; Fy += ld.Fy
        end
        F_s = hypot(Fx, Fy)

        # TRANSLATIONAL anti-mechanism floor from the SAME drift limit DL (derivation above).
        # Frame-independent — needs no plate_center — so it always runs.
        kqt = (h > 0 && drift_limit > 0) ? F_s / (h * drift_limit) : 0.0
        λmin_tt[s] = spec.λmin; λmax_tt[s] = spec.λmax; K_theta[s] = Kθ
        k_req_trans[s] = kqt
        util_trans[s] = kqt / spec.λmin

        # TORSIONAL floor. Both guards above have passed, so the translational block is PD and
        # the CR is well-defined. When plate_center is known, use the EXACT max CR-to-corner
        # lever `r_ref = max_corner hypot(corner − CR)` over the four TRUE occupant corners
        # `plate_center ± (hx, hy)`. When plate_center === nothing the lever cannot be located:
        # FAIL CLOSED (util_tors = Inf) — never a plate-span / origin proxy (crit5/rev6/crit6).
        # ENCLOSURE GUARD (crit7): also fail closed when the plate UNDER-COVERS this story's
        # walls (`!_plate_encloses_walls`) — the exact CR-to-corner lever is a valid torsional
        # floor only over a plate that encloses the drift-relevant points; an under-covering
        # plate would under-state `r_ref` and let the floor fail OPEN. The TRANSLATIONAL floor
        # and the load-independent mechanism guards above do NOT consult the guard and still run.
        # `active_ids` masks density-removed candidates out of the enclosure proxy and
        # `wall_half_lengths` upgrades it to the endpoint-aware body test (both nothing ⇒ all
        # walls, centroid-only, as the one-shot CHECK path and FEM tier require).
        if ev.plate_center === nothing || !_plate_encloses_walls(ev, walls_s, active_ids, wall_half_lengths)
            k_req_tors[s] = Inf
            util_tors[s]  = Inf
        else
            cr = _center_of_rigidity(K)
            cx, cy = ev.plate_center
            hx, hy = ev.plan_halfwidth
            r_ref = 0.0
            for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
                r_ref = max(r_ref, hypot(cx + sx * hx - cr[1], cy + sy * hy - cr[2]))
            end
            kqr = (h > 0 && drift_limit > 0) ? F_s * e_acc * r_ref / (h * drift_limit) : 0.0
            k_req_tors[s] = kqr
            util_tors[s]  = kqr / Kθ
        end
    end

    return (λmin_tt = λmin_tt, λmax_tt = λmax_tt, K_theta_cr = K_theta,
            k_req_trans = k_req_trans, k_req_tors = k_req_tors,
            util_trans = util_trans, util_tors = util_tors)
end
