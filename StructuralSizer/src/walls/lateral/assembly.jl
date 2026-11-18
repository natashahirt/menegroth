"""
    _wall_geometry_vector(w) -> (cx, cy, r)

The rank-1 geometry vector `b = [cx, cy, cy·x − cx·y]` for a wall: the axial
deformation of the pier under a rigid-diaphragm displacement `u = [δx, δy, φ]`
is `b·u`, and the pier force is `k·(b·u)`. `(cx, cy)` is the in-plane axis unit
vector; the third term is the moment arm about the origin.
"""
@inline function _wall_geometry_vector(w::WallLine)
    cx = cos(w.θ); cy = sin(w.θ)
    return (cx, cy, cy * w.x - cx * w.y)
end

"""
    _assemble_story_K(walls_in_story) -> (K::Matrix, walls)

Assemble the 3×3 story stiffness `K = Σ k_i b_i b_iᵀ` about the plan origin.
"""
function _assemble_story_K(walls::Vector{WallLine})
    K = zeros(3, 3)
    for w in walls
        b = _wall_geometry_vector(w)
        bv = (b[1], b[2], b[3])
        @inbounds for a in 1:3, c in 1:3
            K[a, c] += w.k * bv[a] * bv[c]
        end
    end
    return K
end

"""
    _center_of_rigidity(K) -> (xr, yr)

Plan coordinates of the story CENTER OF RIGIDITY (CR) — the point at which a pure
diaphragm translation induces no twist — from the 3×3 story stiffness `K = Σ k_i
b_i b_iᵀ` assembled about the plan origin (see [`_assemble_story_K`](@ref)). The CR is
where the translation–rotation coupling vanishes: measuring the torsional arms about
`(xr, yr)` zeros the `K[1,3]`/`K[2,3]` coupling terms. Setting those shifted coupling
terms to zero gives the 2×2 system

    [ K12  −K11 ] [xr]   [K13]
    [ K22  −K12 ] [yr] = [K23]      (det = K11·K22 − K12² = |translational block| > 0).

The determinant is the translational-block determinant, which is strictly positive for
any story braced in two independent directions (and hence whenever `_solve_spd` has not
already failed closed on a singular `K`). Using the CR as the drift/torsion reference
makes the reported response ORIGIN-INVARIANT: for a symmetric core `K13 = K23 = 0`, so
`CR = (0,0)` and the arithmetic is identical to the origin-referenced form (existing
known-answer tests are unchanged).
"""
@inline function _center_of_rigidity(K::AbstractMatrix{Float64})
    K11 = K[1, 1]; K12 = K[1, 2]; K22 = K[2, 2]
    K13 = K[1, 3]; K23 = K[2, 3]
    det = K11 * K22 - K12 * K12          # translational-block determinant (> 0 if 2-way braced)
    # CR GUARD: a non-SPD translational block (det ≤ 0) means the two translational modes
    # are not independent — the layout is a translational MECHANISM — and the CR is
    # undefined. Fail closed here rather than dividing by a zero/negative determinant and
    # propagating NaN CR coordinates into drift/torsion. `_solve_spd` normally catches this
    # first; this guard makes the helper robust regardless of call ordering.
    det > 0 || throw(SingularStiffnessError(
        "translational block is singular (det(K_tt)=$(det) ≤ 0): the two translational " *
        "modes are not independent (a translational mechanism); center of rigidity undefined."))
    xr = (K11 * K23 - K12 * K13) / det
    yr = (K12 * K23 - K22 * K13) / det
    return (xr, yr)
end

"""
    _translational_block_spectrum(K) -> (; λmin, λmax, det, vmin)

Closed-form spectrum of the 2×2 TRANSLATIONAL block `K_tt = K[1:2, 1:2]` of a 3-DOF story
stiffness. `K_tt` is ORIGIN-INVARIANT (the translation–translation coupling does not involve
the moment arm) and BOTH of its entries carry units N/m, so its eigenvalues are directly
comparable without the rotational-DOF scaling the full 3×3 needs.

For the symmetric block `[K11 K12; K12 K22]` the eigenvalues are closed form,
`λ = (tr ± √(tr² − 4·det))/2`, with `tr = K11 + K22` and `det = K11·K22 − K12²`. The
discriminant equals `(K11 − K22)² + 4·K12² ≥ 0` exactly, so it is CLAMPED at 0 to absorb
tiny-negative round-off before the square root. `λmin` is the SOFTEST translational mode
(its interstory stiffness in the worst translational direction) and `vmin` is that mode's
unit eigenvector — the TRUE worst translational direction, which subsumes a discrete +X/+Y
drift sweep and closes the √2 diagonal-weak-mode gap. `det` (the translational-block
determinant) is returned for the CR / mechanism guards.
"""
@inline function _translational_block_spectrum(K::AbstractMatrix{Float64})
    K11 = K[1, 1]; K12 = K[1, 2]; K22 = K[2, 2]
    tr  = K11 + K22
    det = K11 * K22 - K12 * K12
    disc = tr * tr - 4 * det
    disc < 0 && (disc = 0.0)                 # clamp tiny-negative-from-roundoff
    s = sqrt(disc)
    λmax = 0.5 * (tr + s)
    λmin = 0.5 * (tr - s)
    # Eigenvector for λmin of the symmetric block ((K_tt − λmin·I)·v = 0). Choose the
    # larger-norm of the two row-orthogonal candidates for numerical robustness.
    v1 = (K12, λmin - K11)
    v2 = (λmin - K22, K12)
    v  = (abs(v1[1]) + abs(v1[2])) >= (abs(v2[1]) + abs(v2[2])) ? v1 : v2
    nrm = hypot(v[1], v[2])
    vmin = nrm > 0 ? (v[1] / nrm, v[2] / nrm) : (1.0, 0.0)
    return (λmin = λmin, λmax = λmax, det = det, vmin = vmin)
end

"""
    _torsional_stiffness_cr(K) -> K_theta_cr

Condensed TORSIONAL stiffness about the center of rigidity, via the SCHUR COMPLEMENT of the
translational block of the 3-DOF story stiffness:

    K_theta_cr = K33 − [K13 K23]·inv(K_tt)·[K13; K23]
               = K33 − (K22·K13² − 2·K12·K13·K23 + K11·K23²)/det(K_tt).

This is the rotational stiffness that remains once the diaphragm is free to translate to its
CR (the two translation DOFs statically condensed out). It is ORIGIN-INVARIANT and DIRECTLY
observes twist stiffness — the quantity the center-of-rigidity-translation drift metric is
mathematically blind to (the CR translation is independent of φ by the CR's defining
property). For a positive-definite `K` the Schur complement is strictly positive; it → 0
exactly when the diaphragm can twist about the CR as a mechanism. Requires `det(K_tt) > 0`
(the translational block invertible); callers guard that first.
"""
@inline function _torsional_stiffness_cr(K::AbstractMatrix{Float64})
    K11 = K[1, 1]; K12 = K[1, 2]; K22 = K[2, 2]
    K13 = K[1, 3]; K23 = K[2, 3]; K33 = K[3, 3]
    det = K11 * K22 - K12 * K12
    quad = (K22 * K13 * K13 - 2 * K12 * K13 * K23 + K11 * K23 * K23) / det
    return K33 - quad
end

"""
    _cr_translation(u, cr) -> (tx, ty)

Rigid-body translation of the CENTER OF RIGIDITY `cr = (xr, yr)` given the origin-
referenced story displacement `u = [δx, δy, φ]`. A rigid diaphragm displaces the
physical point `(x, y)` by `(δx − φ·y, δy + φ·x)`, so the CR translation is
`(δx − φ·yr, δy + φ·xr)`. This is the ORIGIN-INVARIANT translation component used for
interstory drift and torsional-amplification `δ_avg`: it is the physical displacement
of a physical point, independent of the arbitrary input origin.
"""
@inline function _cr_translation(u::AbstractVector{Float64}, cr::NTuple{2,Float64})
    xr, yr = cr
    return (u[1] - yr * u[3], u[2] + xr * u[3])
end

"""
    _wall_centroid(walls_s) -> (cx, cy)

Per-story geometric centroid (arithmetic mean) of the wall plan positions.

SUPERSEDED AS A PLAN-CENTER ANCHOR (crit5): this was formerly used as an origin-covariant
PROXY for the plan center — the anchor the TRUE plan corners `plan_center ± (hx, hy)` and the
CR-to-corner lever were measured from. `crit5` proved that proxy UNSAFE: for an eccentric
service core (walls clustered at one end) the wall centroid coincides with the center of
rigidity, so corners anchored to it miss the true far plate corner and the corner-drift /
torsional-lever metrics UNDER-state the twist. The corner-drift and torsional-floor metrics
now anchor the corners to the TRUE floor-plate center `ReducedDiaphragmEvaluator.plate_center`
(the four occupant corners `plate_center ± (hx, hy)`) and FAIL CLOSED when it is absent —
they never use this wall centroid.

This helper is RETAINED only as a plain geometric utility (and for tests that reference it);
it must NOT be reintroduced as the corner-drift plan-center anchor. Returns `(0.0, 0.0)` for
an empty wall list.
"""
@inline function _wall_centroid(walls_s::Vector{WallLine})
    isempty(walls_s) && return (0.0, 0.0)
    sx = 0.0; sy = 0.0
    for w in walls_s
        sx += w.x; sy += w.y
    end
    n = length(walls_s)
    return (sx / n, sy / n)
end

"""
    _reference_length(ev, walls_s) -> Float64

Plan reference length `L_ref` [m] used to non-dimensionalize the rotational DOF of
a 3×3 story stiffness before the conditioning test in [`_assert_nonsingular_K`](@ref).
Prefers a plan dimension (the larger of the two plan extents `2·plan_halfwidth`).
If `plan_halfwidth` is unset `(0,0)`, falls back to the largest wall radial offset
from the plan origin (ENGINEERING JUDGMENT: a defensible geometric length scale for
the torsional arm when no plan extent is supplied); if that is also zero (all walls
at the origin) returns `1.0`, under which a genuinely unrestrained rotational mode
still reads as singular.
"""
function _reference_length(ev::ReducedDiaphragmEvaluator, walls_s::Vector{WallLine})
    Lplan = max(2 * ev.plan_halfwidth[1], 2 * ev.plan_halfwidth[2])
    Lplan > 0 && return Lplan
    Lgeom = maximum((hypot(w.x, w.y) for w in walls_s); init = 0.0)
    return Lgeom > 0 ? Lgeom : 1.0
end

"""
    _plate_encloses_walls(ev::ReducedDiaphragmEvaluator, walls_s, active_ids=nothing,
                          wall_half_lengths=nothing) -> Bool

ENCLOSURE GUARD (fail-closed) for the reduced-tier corner-drift / torsion certification.
Returns `true` iff `plate_center` is present AND every ACTIVE `WallLine` `w` in `walls_s` lies
inside (or exactly on) the plate rectangle `plate_center ± plan_halfwidth`:

    cx − hx − tol ≤ w.x ≤ cx + hx + tol    AND    cy − hy − tol ≤ w.y ≤ cy + hy + tol

with `(cx, cy) = plate_center`, `(hx, hy) = plan_halfwidth`.

ENDPOINT-AWARE BODY TEST (`wall_half_lengths`, ENGINEERING JUDGMENT — not a code clause):
a `WallLine` carries no length, so the CENTROID-only test above passes a long wall whose
centroid is inside the plate but whose BODY over-hangs the plate edge (crit8 residual). When
the caller supplies `wall_half_lengths` (candidate id → `lw/2`) and an active wall has `hl > 0`,
the guard extends the enclosure test from the centroid to the wall's TWO endpoints
`(w.x ± hl·cos θ, w.y ± hl·sin θ)` against the SAME `tol` bounds. The test is applied PER AXIS
and the endpoint extension on an axis is ARMED ONLY where that axis has a POSITIVE half-extent:

  • X: test `{w.x ± hl·cos θ}` within `[cx − hx − tol, cx + hx + tol]` IF `hx > 0` (and the body
    test is active); otherwise (`hx == 0`, or body test inactive) test just the centroid `w.x`.
  • Y: symmetric with `hy` and `{w.y ± hl·sin θ}`.

On a NORMAL plate (`hx > 0` AND `hy > 0`) this is mathematically IDENTICAL to requiring both
endpoints inside: the endpoints are symmetric about the centroid, so their X-extent is exactly
`{w.x ± hl·cos θ}` and their Y-extent `{w.y ± hl·sin θ}`, and the plate is an axis-aligned CONVEX
rectangle — requiring each axis's extent within that axis's bounds ⇔ both endpoints inside. On a
DEGENERATE (zero-half-extent) axis the endpoint extension would wrongly flag a legitimate wall
whose body runs ALONG the thin axis (crit7: a line of X-walls at `x = cx` declared with
`plan_halfwidth = (0, hy)`, bodies reaching `x = cx ± lw/2`), so that axis instead REVERTS to the
CENTROID coordinate (`w.x`) — the exact pre-endpoint crit7 behavior: on-axis walls within `tol`
are enclosed, off-axis walls fail closed — while the OTHER, positive-extent axis stays endpoint-
checked. The body test is strictly MORE conservative on the armed axes: a fully-inside wall still
passes, a perimeter wall running ALONG a positive-extent plate edge has both endpoints ON the
edge (within `tol`) and still passes, and only a genuinely over-hanging body now FAILS CLOSED.
Falls back to the CENTROID test (byte-for-byte as before) when `wall_half_lengths === nothing`,
the id is absent from the map, or its half-length is `≤ 0`, so the one-shot CHECK path and the
FEM tier (both pass `nothing`) are unchanged.

ARMING PATH (where the body test actually fires): because a `WallLine` carries no length, the
id → half-length map is injected ONLY on the OPTIMIZER path — `solve_wall_layout` and the
`constraint_fns` / `objective_fn` / survivor re-validation it drives (layout_problem.jl), which
hold the `WallCandidate` lengths. The DIRECT one-shot `evaluate_lateral` / reduced-tier check
path passes `wall_half_lengths === nothing` and stays CENTROID-only; it defers the crit8 body-
overhang case to the Phase-10 unified-FEM survivor (true geometry). That one-shot residual is an
UNCHANGED pre-existing gap, not a new hole, and is NOT closed by adding `lw` to `WallLine`.

WHY (crit7): the four-corner max-drift / torsion metrics are EXACT only over the rectangle
`plate_center ± plan_halfwidth` (convexity of `|disp(p)|²` in the plan point `p`), and are
exact for the TRUE occupant diaphragm ONLY when that rectangle ENCLOSES every drift-relevant
point. `plate_center` and `plan_halfwidth` are two FREE, caller-supplied fields and nothing
else cross-checks them against the wall positions, so an UNDER-COVERING plate (e.g. the core
half-extent mistaken for the full floor) makes BOTH plate-anchored gates (corner drift AND the
`res.torsion` amplification ratio) silently UNDER-state the real edge drift while the only
plate-independent gate (`util_trans`) is twist-blind — the exact formula then fails OPEN.

This predicate enforces the CHECKABLE proxy WALLS ⊆ plate for the real (uncheckable here)
requirement occupants ⊆ plate: the reduced model carries no independent occupant outline, so
the caller's `plate_center`/`plan_halfwidth` is CONTRACTUALLY the true occupant diaphragm in
the `WallLine` frame. The Phase 10 unified-FEM survivor check (true geometry) is the FINAL
authority. RESIDUAL NOT CAUGHT: a plate that encloses the walls but is declared SMALLER than
the true occupant diaphragm (walls ⊆ plate ⊂ occupants) is uncatchable here — it is delegated
to the caller contract + the FEM survivor check.

ENGINEERING JUDGMENT (tolerance, not a code clause): `tol = 1e-9 + 1e-9·hypot(hx, hy)` — an
absolute floor plus a plate-SCALED relative term — so a wall EXACTLY on the plate boundary
(`|w.x − cx| == hx`) PASSES despite floating-point assembly noise, while a genuine over-hang
(even a few mm beyond a plan-scale plate) FAILS closed. The CENTROID test is EXACTLY ORIGIN-
INVARIANT: walls and plate translate together, so a joint origin shift leaves every inequality
unchanged. The ENDPOINT/body test is NOT exactly origin-invariant: the `w.x + hl·cos θ` endpoint
evaluation rounds at a magnitude that scales with `|w.x|` (and `w.y + hl·sin θ` with `|w.y|`), so
a plate declared very far from the `WallLine`-frame origin could read a legitimately on-edge wall
a hair outside `tol`. This is negligible for physical coordinates — biting only near
`|coord| / plate ≈ 4e6` (double-precision ε against the plate-scaled `tol` term) — but the exact
invariance claim holds for the centroid test ONLY, not the body test.

ENGINEERING JUDGMENT (degenerate plate, not a code clause): a NEGATIVE half-extent (`hx < 0`
or `hy < 0`) is a nonsensical / inverted plate and is treated as NON-enclosing (fail closed). A
ZERO half-extent (a thin, axis-aligned plate) is NOT force-failed: it is left to the per-wall
bounds below, which ENCLOSE walls lying ON that axis (within `tol`) and FAIL-CLOSE any wall OFF
it. This keeps legitimately degenerate plans certifiable (e.g. a line of walls all at `x = cx`
declared with `plan_halfwidth = (0, hy)`) while a genuinely SPREAD layout declared under a
zero-extent plate still fails closed through the per-wall bounds. An empty `walls_s` is
vacuously enclosed.

ACTIVE-ID MASK (`active_ids`, ENGINEERING JUDGMENT — not a code clause): the SIMP optimizer
drives REMOVED candidates to the void floor `ρ_min` but keeps them in `walls_s` (their stiffness
is floored to prevent an exactly-singular `K`, never deleted). A removed candidate parked
OUTSIDE the plate must NOT flip this gate — it is physically absent. The OPTIMIZER (which alone
holds the densities `x`, `ρ_min`, and `penal`) computes the Set of ACTIVE candidate ids and
passes it in; when `active_ids !== nothing` any wall with `w.id ∉ active_ids` is SKIPPED before
the bounds test. `active_ids === nothing` (the default) treats EVERY wall as active, so the
one-shot CHECK path and the FEM tier are byte-for-byte unchanged.

HOW ACTIVITY IS DEFINED (and why `ρ_min`'s magnitude is IRRELEVANT): a candidate is ACTIVE iff
its PENALIZED stiffness fraction `ρ^penal > ε_abs` — the fraction of `k_max` actually assembled
into `K` (`_active_candidate_ids`; `k = ρ^penal·k_max`). This is a PER-WALL ABSOLUTE test against
a fixed constant, so it degrades to "ALL active" (guard fully armed) as `ρ_min → 1` and NEVER to
"all removed": at `ρ_min=1.0` every `ρ^penal = 1 > ε_abs`, so no wall is masked and this gate
cannot silently disable itself. The earlier LINEAR test (`ρ` vs `ρ_min·(1+ε)`) FAILED OPEN at a
legal `ρ_min=1.0`, where every density is pinned at the floor yet still carries full stiffness —
the whole active set went empty and the gate became vacuously true for all layouts. The absolute
`ρ^penal` test removes that dependence on `ρ_min`'s magnitude entirely.

An all-removed / empty-after-mask set is vacuously enclosed (same rule as an empty `walls_s`).
This is a BACKSTOP, not a hole — but the GOVERNING backstop for a LOADED all-masked story is the
LOAD-DEPENDENT eigenstructure TRANSLATIONAL floor `util_trans`, NOT the scale-invariant singular
guard. An empty active set means every wall is floored to `ρ^penal ≤ ε_abs`, so the story `K` is
UNIFORMLY softened; with cumulative shear `F_s > 0` the softest translational mode `λmin(K_tt)`
→ ~0 drives `util_trans = F_s/(h·DL·λmin(K_tt)) → ∞`, so the story fails closed through the drift
slot (`eigenstructure_stability`). The SCALE-INVARIANT singular / `rcond` guard — whose ratio
`λmin/λmax` stays healthy under a UNIFORM softening — would NOT catch a uniformly-softened-but-
well-conditioned story on its own; it is the SECONDARY catch for genuinely ill-conditioned cases.
(An UNLOADED all-masked story has `F_s ≈ 0`, so there is no drift demand to under-state.) The
negative-half-extent (inverted plate) branch, by contrast, fires
BEFORE the mask (crit-P2): a NON-EMPTY `walls_s` with an inverted plate fails closed regardless of
which walls are active.

WHY RELATIVE STIFFNESS IS NEVER USED TO INFER REMOVAL: a relative-stiffness threshold (comparing
one wall's `k` to OTHERS') would be UNSAFE — one very stiff inside wall could push a genuinely
REAL outside wall below the threshold and silently skip it, under-stating the certified drift (the
exact-formula-fails-OPEN failure mode this guard exists to prevent). "Removed" is therefore the
optimizer's PER-WALL ABSOLUTE `ρ^penal` density fact, never a quantity this predicate reconstructs
by comparing `w.k` across walls.
"""
function _plate_encloses_walls(ev::ReducedDiaphragmEvaluator, walls_s::Vector{WallLine},
                               active_ids::Union{Nothing,AbstractSet}=nothing,
                               wall_half_lengths::Union{Nothing,AbstractDict{Int,Float64}}=nothing)
    ev.plate_center === nothing && return false
    isempty(walls_s) && return true                 # vacuously true: nothing to enclose
    cx, cy = ev.plate_center
    hx, hy = ev.plan_halfwidth
    # NEGATIVE (inverted) half-extent on a NON-EMPTY wall set ⇒ cannot enclose (fail closed),
    # INDEPENDENT of the active-ID mask (crit-P2). An inverted / garbage `plan_halfwidth` must
    # never report "enclosed", so this fires BEFORE the per-wall loop and mask skip: a non-empty
    # `walls_s` with an inverted plate fails closed regardless of WHICH walls are active (the
    # empty-`walls_s` case already returned vacuously-true above). A ZERO half-extent is NOT
    # force-failed — it is left to the per-wall bounds below (encloses on-axis walls within
    # `tol`, fails closed on off-axis walls) so a valid thin/axis-aligned plan is not rejected.
    (hx < 0 || hy < 0) && return false
    tol = 1e-9 + 1e-9 * hypot(hx, hy)               # absolute + plate-scaled boundary tolerance
    for w in walls_s
        # ACTIVE-ID MASK (ENGINEERING JUDGMENT, not a code clause): when `active_ids` is
        # supplied, SKIP any wall the optimizer has driven to negligible penalized stiffness
        # (`w.id ∉ active_ids`). A density-REMOVED candidate is physically absent, so it can
        # neither be enclosed nor fail-close the gate — it is simply not examined. Activity is
        # the optimizer's PER-WALL ABSOLUTE `ρ^penal > ε_abs` fact (`_active_candidate_ids`),
        # never a RELATIVE comparison to other walls, so a genuinely real outside wall can never
        # be silently skipped (see docstring). `active_ids === nothing` ⇒ every wall is examined,
        # byte-for-byte identical to the one-shot CHECK / FEM tiers.
        active_ids === nothing || w.id in active_ids || continue
        # ENDPOINT-AWARE BODY TEST (ENGINEERING JUDGMENT, not a code clause): when the optimizer
        # supplies a per-candidate half-length `hl = lw/2 > 0`, extend the enclosure test from
        # the centroid to the wall's TWO endpoints `(w.x ± hl·cos θ, w.y ± hl·sin θ)`, catching a
        # wall whose centroid is inside but whose BODY over-hangs the plate edge (crit8). The
        # plate is an axis-aligned CONVEX rectangle, so both endpoints inside ⇒ the whole pier
        # inside. Strictly MORE conservative (a fully-inside wall and an edge-aligned perimeter
        # wall both still pass; only a genuine over-hang fails closed).
        #
        # ENGINEERING JUDGMENT (lw ≤ 0 ⇒ degenerate point wall, not a code clause): `get(…, 0.0)`
        # ⇒ a missing map / id / NON-POSITIVE half-length gives `hl ≤ 0` and reverts to the
        # CENTROID test exactly as before. A zero-length wall IS its own centroid (no body to
        # over-hang), so this is INTENDED degenerate-point-wall behavior, NOT a silent disarm.
        hl = wall_half_lengths === nothing ? 0.0 : get(wall_half_lengths, w.id, 0.0)
        body = hl > 0                                # body test ARMED for this wall?
        dx = body ? hl * cos(w.θ) : 0.0              # half-body X-extent (0 when disarmed)
        dy = body ? hl * sin(w.θ) : 0.0              # half-body Y-extent (0 when disarmed)
        # PER-AXIS half-extent gating (ENGINEERING JUDGMENT, not a code clause): extend to the
        # endpoints on an axis ONLY where the plate declares a POSITIVE half-extent; on a ZERO-
        # extent (thin / degenerate) axis REVERT that axis to the CENTROID coordinate (crit7).
        # The endpoints are symmetric about the centroid, so their X-extent is exactly
        # {w.x ± hl·cos θ} and their Y-extent {w.y ± hl·sin θ}; requiring the former within the X
        # bounds AND the latter within the Y bounds is EQUIVALENT to requiring both endpoints
        # inside the convex rectangle — so on a NORMAL plate (hx > 0 AND hy > 0) this is
        # mathematically IDENTICAL to the both-endpoints test. On a degenerate axis (e.g. hx == 0,
        # a thin plate of X-walls declared with `plan_halfwidth = (0, hy)`) the X-check reverts to
        # the centroid `w.x` (on-axis walls within `tol` enclosed, off-axis walls fail closed —
        # the pre-endpoint crit7 contract) while the positive-hy axis is still endpoint-checked.
        if body && hx > 0
            (cx - hx - tol <= w.x + dx <= cx + hx + tol) || return false
            (cx - hx - tol <= w.x - dx <= cx + hx + tol) || return false
        else
            (cx - hx - tol <= w.x <= cx + hx + tol) || return false
        end
        if body && hy > 0
            (cy - hy - tol <= w.y + dy <= cy + hy + tol) || return false
            (cy - hy - tol <= w.y - dy <= cy + hy + tol) || return false
        else
            (cy - hy - tol <= w.y <= cy + hy + tol) || return false
        end
    end
    # EMPTY-AFTER-MASK BACKSTOP: if the mask skipped every wall (empty active set) this returns
    # vacuously true. This is SAFE, not a hole — but the GOVERNING backstop for a LOADED all-
    # masked story is the LOAD-DEPENDENT eigenstructure TRANSLATIONAL floor `util_trans`, NOT the
    # scale-invariant singular guard. An empty active set floors every wall to ρ^penal ≤ ε_abs, so
    # the story K is UNIFORMLY softened; with cumulative shear F_s > 0 the softest translational
    # mode λmin(K_tt) → ~0 drives `util_trans = F_s/(h·DL·λmin) → ∞`, failing closed through the
    # drift slot (`eigenstructure_stability`). The scale-invariant singular / rcond guard — whose
    # λmin/λmax ratio stays healthy under a uniform softening — would NOT catch a uniformly-
    # softened-but-well-conditioned story on its own; it is the SECONDARY catch for genuinely ill-
    # conditioned cases. (An UNLOADED all-masked story has F_s ≈ 0, so there is no drift to under-
    # state.)
    return true
end

# FEM tier (and any non-reduced evaluator) carries TRUE geometry and is NOT subject to the
# reduced-tier enclosure proxy, so it always "encloses" — mirrors
# `_plate_center_missing(::AbstractLateralEvaluator) = false`. Keeps FEM unaffected. The
# optional `active_ids` and `wall_half_lengths` args are accepted (and ignored) so the two arities
# match the reduced method and both the mask and the endpoint map thread transparently through
# evaluator-agnostic call sites.
_plate_encloses_walls(::AbstractLateralEvaluator, ::Vector{WallLine},
                      ::Union{Nothing,AbstractSet}=nothing,
                      ::Union{Nothing,AbstractDict{Int,Float64}}=nothing) = true
