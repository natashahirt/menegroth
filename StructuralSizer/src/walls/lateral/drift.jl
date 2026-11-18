# Principal plan directions swept by the direction-complete stability check:
# +X = (1,0) and +Y = (0,1). ENGINEERING JUDGMENT: sweeping BOTH principal
# directions (not only the design load's direction) is a mechanism-prevention
# safeguard — a layout braced only along the design load leaves the orthogonal
# diaphragm-translation mode a near-zero-stiffness mechanism that a direction-aligned
# drift check cannot see. Motivated by (but NOT a verbatim magnitude from) ASCE 7-22
# §12.5 "Direction of Loading"; we deliberately do NOT invent the ASCE orthogonal-load
# combination magnitudes (that is Phase 6's job) — we reuse the SUPPLIED design
# resultant magnitude, swept into each axis.
const _DIRECTION_COMPLETE_DIRS = ((:X, 1.0, 0.0), (:Y, 0.0, 1.0))

"""
    direction_complete_interstory_drift(ev, walls, loads; active_ids=nothing, wall_half_lengths=nothing) -> (; directions, drift, corner_drift)

`active_ids` (optional) is the SIMP optimizer's Set of ACTIVE candidate ids; when supplied it
masks density-removed walls out of the per-story enclosure proxy (see [`_plate_encloses_walls`]).
`wall_half_lengths` (optional, candidate id → `lw/2`) upgrades that proxy to the endpoint-aware
body test (see [`_plate_encloses_walls`]); passed together with `active_ids`. Both `nothing`
(default) examines every wall by its centroid, leaving the one-shot CHECK / FEM paths unchanged.

DIRECTION-COMPLETE, origin-invariant per-story interstory drift sweep. Returns BOTH a
serviceability realization (`drift`, the CR translation) AND the physical drift SAFETY
quantity (`corner_drift`, the EXACT max-corner interstory drift):

  * `drift[s, d]` — magnitude of the CENTER-OF-RIGIDITY translation (`_cr_translation`),
    the translational demand / serviceability realization. It is mathematically blind to
    the twist DOF φ (the CR translation is independent of φ by the CR's defining property),
    so it is NOT the stability/drift-limit authority; it is retained for serviceability and
    for the existing origin-invariant known-answer tests.
  * `corner_drift[s, d]` — the EXACT max-corner interstory drift over the FOUR TRUE occupant
    corners `plate_center ± (hx, hy)`. The rigid-diaphragm displacement of corner `p` is
    `disp(p) = (δx − φ·p_y, δy + φ·p_x)` (= `CR translation + φ × (p − CR)`), and
    `corner_drift = max_p hypot(disp(p)) / h` — EXACT, with NO slack, and CORRECT even when
    the CR lies outside the plate (the non-orthogonal rev6 case). This is the quantity ASCE
    7-22 §12.12.1 limits: the design story drift Δ ≤ allowable Δ_a from Table 12.12-1, with Δ
    taken AT THE BUILDING EDGES including diaphragm rotation (ASCE 7-22 §12.8.6.5); torsion
    enters it DIRECTLY and UNCAPPED through φ, and it is what `constraint_fns` /
    `solve_wall_layout` use for the drift feasibility check (corpus: asce-7-22; §12.12.1 PDF
    p. 194; §12.8.6.5 PDF p. 188). When `ev.plate_center === nothing` the corners cannot be
    located, so `corner_drift` FAILS CLOSED to `Inf` (certification unavailable) — it NEVER
    falls back to the wall centroid, the DOF origin, or a plate-span lever bound (crit5/rev6/
    crit6). The Phase 10 unified-FEM survivor check (true geometry) is the accuracy authority.

For each story `s` it forms the cumulative applied lateral-load RESULTANT MAGNITUDE
`F_s = hypot(ΣFx, ΣFy)` over all loads at/above `s` (exactly the story-shear resultant
the primal `evaluate_lateral` already forms), then evaluates the drift under a CANONICAL
load set that does NOT depend on the design load's direction: the full resultant swept
into `+X = (F_s, 0)` and `+Y = (0, F_s)` (see `_DIRECTION_COMPLETE_DIRS`). Each canonical
case carries the SAME accidental-eccentricity torsion companion used by `evaluate_lateral`
— identical `eax`/`eay`, `sign_nonzero`, and `ev.accidental_ecc` (ASCE 7-22 §12.8.4.2.2) —
applied at the force-weighted participation centroid of the loads at/above `s`.

Both metrics are origin-invariant: the CR translation (`_cr_translation`) is the physical
displacement of a physical point, and the corners `plate_center ± (hx, hy)` translate WITH
the walls+loads (the `plate_center` is in the same frame as `WallLine.x, y`), so translating
walls+loads+plate_center jointly leaves `corner_drift` and `drift` unchanged.

A near-dead principal direction produces a large FINITE value there (good Ipopt gradient,
no throw), so the per-story MAX over directions smoothly becomes infeasible when any
principal mode is unbraced. Fails closed (`SingularStiffnessError`) only on a genuinely
singular `K` via `_solve_spd`.
"""
function direction_complete_interstory_drift(ev::ReducedDiaphragmEvaluator,
                                             walls::Vector{WallLine},
                                             loads::Vector{StoryLoad};
                                             active_ids::Union{Nothing,AbstractSet}=nothing,
                                             wall_half_lengths::Union{Nothing,AbstractDict{Int,Float64}}=nothing)
    nstory = length(ev.story_heights)
    ndir = length(_DIRECTION_COMPLETE_DIRS)
    D = zeros(nstory, ndir)
    C = zeros(nstory, ndir)
    Lx = 2 * ev.plan_halfwidth[1]; Ly = 2 * ev.plan_halfwidth[2]
    for s in 1:nstory
        walls_s = [w for w in walls if w.story == s]
        isempty(walls_s) && continue
        K = _assemble_story_K(walls_s)
        Lref = _reference_length(ev, walls_s)
        h = ev.story_heights[s]

        # Cumulative story-shear resultant magnitude F_s = hypot(ΣFx, ΣFy) and the
        # force-weighted participation centroid (ex_c, ey_c) of the loads at/above s,
        # where the equivalent resultant is applied for the torsion companion.
        Fx = 0.0; Fy = 0.0; wsum = 0.0; exc = 0.0; eyc = 0.0
        for ld in loads
            ld.story < s && continue
            Fx += ld.Fx; Fy += ld.Fy
            wl = hypot(ld.Fx, ld.Fy)
            wsum += wl; exc += wl * ld.ex; eyc += wl * ld.ey
        end
        F_s = hypot(Fx, Fy)
        if wsum > 0
            exc /= wsum; eyc /= wsum
        end
        eax = ev.accidental_ecc * Lx
        eay = ev.accidental_ecc * Ly

        # CR is the reference for the (origin-invariant) serviceability drift; the EXACT
        # corner metric anchors the four occupant corners to the TRUE plate center. Both are
        # safe when the canonical solve below does not throw — i.e. K is PD, so the
        # translational block is PD and the CR is well-defined.
        cr = _center_of_rigidity(K)
        center = ev.plate_center
        hx, hy = ev.plan_halfwidth
        # ENCLOSURE GUARD (crit7, fail-closed): the EXACT four-corner drift below is exact only
        # when the plate `plate_center ± plan_halfwidth` ENCLOSES the drift-relevant points. An
        # UNDER-COVERING plate (the two FREE fields are not otherwise cross-checked against the
        # walls) would make this metric under-state the real edge drift — the exact formula
        # fails OPEN. Fail closed to `Inf` when this story's walls are not ⊆ plate (see
        # `_plate_encloses_walls`); computed ONCE per story (direction-independent). `active_ids`
        # masks density-removed candidates and `wall_half_lengths` upgrades the proxy to the
        # endpoint-aware body test (both nothing ⇒ all walls, centroid-only, as CHECK/FEM require).
        encloses = _plate_encloses_walls(ev, walls_s, active_ids, wall_half_lengths)

        for (di, (_, dx, dy)) in enumerate(_DIRECTION_COMPLETE_DIRS)
            Fxc = F_s * dx; Fyc = F_s * dy
            # Accidental-eccentricity torsion companion, term-for-term as in
            # `evaluate_lateral` (ASCE 7-22 §12.8.4.2.2), for the equivalent resultant
            # acting at (exc, eyc): Mz = Fy·(ex + sign·eax) − Fx·(ey + sign·eay).
            Mz = Fyc * (exc + sign_nonzero(Fyc) * eax) -
                 Fxc * (eyc + sign_nonzero(Fxc) * eay)
            u = _solve_spd(K, [Fxc, Fyc, Mz], Lref)   # fail-closed on singular K
            # (1) CR-translation drift (serviceability realization, φ-blind). PRESERVED.
            tx, ty = _cr_translation(u, cr)
            D[s, di] = h > 0 ? sqrt(tx^2 + ty^2) / h : 0.0
            # (2) EXACT max-corner interstory drift over the four TRUE occupant corners
            # `plate_center ± (hx, hy)` (ASCE 7-22 §12.12.1, Δ at the building edges incl.
            # diaphragm rotation per §12.8.6.5). The rigid-diaphragm displacement of corner
            # `p` is `(δx − φ·p_y, δy + φ·p_x)`; `corner_drift = max_p hypot(disp(p))/h`,
            # EXACT (no slack) and correct even when the CR lies outside the plate (rev6).
            # FAIL CLOSED to `Inf` when `plate_center === nothing` — no wall-centroid / origin
            # / plate-span proxy (crit5/rev6/crit6; corpus: asce-7-22, §12.12.1 PDF p. 194;
            # §12.8.6.5 PDF p. 188). Also fail closed when the plate UNDER-COVERS this story's
            # walls (`!encloses`, crit7) — same reason the exact metric would otherwise fail OPEN.
            if center === nothing || !encloses
                C[s, di] = Inf
            else
                cx, cy = center
                cdrift = 0.0
                for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
                    px = cx + sx * hx; py = cy + sy * hy
                    cdrift = max(cdrift, hypot(u[1] - u[3] * py, u[2] + u[3] * px))
                end
                C[s, di] = h > 0 ? cdrift / h : 0.0
            end
        end
    end
    return (directions = Symbol[d[1] for d in _DIRECTION_COMPLETE_DIRS],
            drift = D, corner_drift = C)
end
