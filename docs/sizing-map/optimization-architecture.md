# Optimization architecture: relaxation seeds, multi-objective fronts, cost-aware fidelity

Status: draft for discussion (2026-11-24). Companion to
[`architecture.md`](architecture.md) (component model + two-tier fidelity),
[`plan.md`](plan.md) (phases, objectives O1–O7, benchmarks B1–B7) and
[`README.md`](README.md) (current state). This document does **not** replace the
component model; it specifies the control layer that drives the owners, the
round controller and the fidelity service.

## 0. What this adds

`architecture.md` already commits to: sequential approximate optimisation (one
real analysis + a cheap approximate subproblem per round), a design-state
registry, pure checks, owners that pick the lightest feasible value, clusters
for tight couplings, a hybrid cycle-guard, a simple final verifier, and a
fast/full two-tier fidelity. Those stand.

Three cross-cutting layers are implied by that design but not yet first-class.
This plan makes them explicit, because the recent dual-system work showed they
pay off and because the user wants *all objectives (including compounded / Pareto
fronts), a consistently lowest-x design, no ratcheting, and compute spent
cheap-first*:

- **Pillar A — a continuous-relaxation layer** that produces, every round, a
  *certified lower bound* on the objective and a *warm start* for every discrete
  owner. This is the engine proved on the 30-story dual system (continuous
  section properties + optimality criteria + a cached reduced factorization,
  converging in 3–5 solves).
- **Pillar B — multi-objective / Pareto** as a capability, via *continuation*
  along the relaxed front: the relaxed optimum moves smoothly as objective
  weights sweep, so the whole front is cheap and only chosen points are
  projected to discrete/detailed fidelity.
- **Pillar C — a cost-aware (value-of-information) scheduler** that rations the
  expensive solves (fine slab FEA, rib grillage, second-order frame, bracing
  nonlinearity) and drives them from *surrogates* learned on cheap evaluations.

Each pillar extends an existing objective: A sharpens **O4** (lightweight →
*measured* gap), B generalises **O7** (switchable → vector objective + fronts),
C deepens **O5** (efficient → compute allocated by information value). None
weakens **O1** (safety): the relaxation never ships a design — it only *guides*,
and every reported design still passes the independent full-fidelity verifier.

## 1. One-sentence reframe

Size by solving a cheap **continuous relaxation globally** to settle the
coupling and get a lower bound + warm start, **project to discrete by bounded
search** around that warm start, and **verify at full fidelity with shrink
allowed** — with a scheduler spending the next unit of compute wherever it most
tightens the bound or improves the objective, and the objective itself a swept
parameter.

The current pipeline is the degenerate case of this: one objective, one
resolution (catalog), one fidelity, a fixed stage order, grow-only.

## 2. The three axes, made independent

The pipeline today entangles four things. Separating them is the refactor that
makes every goal a dial rather than a feature.

| Axis | Values | Today | Target |
|---|---|---|---|
| **Objective** | carbon, cost, weight, drift-margin, … (and weighted sums) | one carbon model, half-wired | a vector functional; every element reports marginal objective per unit of each variable |
| **Variable resolution** | continuous → catalog → detailed | catalog only | a ladder; each level relaxes, bounds, and projects up |
| **Physics fidelity** | per subsystem, F0 … Fk | mostly one, embedded in each designer | a property of the analysis service; cheap warm-starts expensive |
| **Search / order** | which variable moves, in what order | fixed stages, first-failure greedy | coupling graph settled global-cheap-first, then scheduled by information value |

Resolution and fidelity are **orthogonal**: you can evaluate a continuous design
at fine FEA, or a catalog design at coarse FEA. Keeping them separate is what
lets the cheap models guide the expensive ones.

## 3. Pillar A — continuous relaxation and the bound ladder

### 3.1 The relaxation

Replace each sizing-governed member's discrete section with **continuous section
properties** (A, Iₓ, I_y, Z, J). On that relaxation, minimize the objective
subject to the governing global constraints (drift, stiffness, a strength floor
per member) with an **optimality-criteria / dual update** — the KKT stationarity
condition for minimum weight under a displacement constraint, which equalizes
virtual-strain-energy-per-unit-objective across members. A handful of linear
solves on a cached factorization.

Already built: `resize_for_drift!`, Asap's `drift_participation`
(cₑ = u_vᵀ Kₑ u_r on the cached factor, Σ cₑ = δ), the governor's trust-region
accelerator, and `RigidLinkFactorCache` (reuses the reduced factorization across
P-Δ / exclude-shells solves). The dual-system proof is the single-constraint
case of this.

### 3.2 The bound ladder (the certificate)

Minima chain across the resolution ladder:

```
objective(continuous*)  ≤  objective(catalog*)  ≤  objective(detailed*)
     (relaxation)             (projection)            (verified design)
```

The continuous optimum is a **valid lower bound** on the discrete minimum, so
every design carries a *measured* optimality gap — the certificate O4 asks for,
which the current iterative pipeline cannot produce. "Lowest-x" becomes
"within g% of the proven lower bound", reported per element and per building.

### 3.3 Projection = bounded discrete optimisation (not round-up)

Owners consume the continuous target as a warm start **and a narrow candidate
band** (±1–2 catalog steps / grid steps), then run today's discrete owner (MIP,
binary search, NLP) *inside that band*. This keeps the owner's discrete
optimality while collapsing its search, because the answer is bracketed. Naive
snap-up is explicitly rejected: it is coupling-blind (the true discrete optimum
sometimes sizes one member down and compensates at a neighbour) and reintroduces
weight.

### 3.4 Anti-ratchet

Every variable is **anchored to the relaxation bound and may move in both
directions**; the bound tells the controller when to stop, so monotonicity is no
longer needed as a safety crutch. The signed-off **hybrid cycle-guard**
(a cycling variable becomes grow-only for the rest of the run) remains as the
stability fallback — but with a good warm start it is rarely triggered. Section
"floors" become demand rows that lapse when their source changes (plan.md 3.5),
not permanent masks. Verify is **shrink-and-grow**, not grow-only.

### 3.5 Where it applies — and where it does not

- **Strong:** drift- and global-stiffness-governed members, walls, and the LFRS.
  These have a stiffness relaxation with meaningful sensitivities. This is
  exactly the pipeline's worst hot-spot (beam⇄column up to 20 passes,
  walls⇄members up to 4× the member stage).
- **No stiffness relaxation:** punching shear, panel-zone shear, connection and
  anchorage design — local and nonlinear. Their "cheap model" is a closed-form
  capacity, not a global solve, and must be *validated*, never bounded by a
  stiffness relaxation. The ladder is per-subsystem for this reason.

### 3.6 Correctness obligations (safety-critical)

The relaxation under-constrains; the verifier re-imposes everything. Specifically:

1. **A↔I coupling.** Continuous space treats section properties as nearly
   independent; real catalogs couple them. Needs a per-family scaling law
   (fit A, Zₓ, Iₓ vs depth) so the warm start lands close; the verifier catches
   the residual on real properties.
2. **Strength floors are approximate** (I_min uses the section depth, which the
   section determines). Strength-governed members are near fully-stressed, and
   fully-stressed ≠ global min weight for indeterminate structures — so these
   regions rely on the bounded discrete step (3.3), not the OC update, for
   lightness.
3. **Second-order.** The cached *linear* factor does not capture P-Δ/P-δ. The
   verifier runs the real B1/B2 (AISC App. 8) and δs (ACI §10.10) pass — the
   `StoryStability` / `design_column_moments` machinery already built.
4. **Multiple active constraints** (per-story drift, wind serviceability,
   strength) need a **multi-λ dual update** for a true KKT point; the
   single-λ OC is a heuristic beyond one binding constraint
   (todo `drift-multi-constraint`).

### 3.7 Work packages (Workstream R — relaxation)

| WP | Work | Acceptance |
|---|---|---|
| R.1 | Continuous section abstraction + per-family scaling laws (A, Zₓ, Iₓ, J vs a size parameter) for steel W/HSS/Pipe and RC rect/T | Projection of a continuous target lands within one catalog step of the full-MIP pick on B1–B5 members |
| R.2 | Global continuous relaxation across the sizing-governed members/walls on the assembled model (cached factor), multi-λ dual update for drift + strength-floor box constraints | Converges in ≤ ~10 solves on B6/B7; objective is a valid lower bound (never exceeds any verified design) |
| R.3 | Owner warm-start + candidate-band interface: owners accept a continuous target and a band, run the existing discrete search inside it | B1–B7 final sizes identical-or-lighter than baseline; beam⇄column pass count drops (target set at baseline) |
| R.4 | Bound certificate in the round controller + run JSON: per-element and per-building optimality gap | Gap reported on B1–B7; shrink-and-grow verify enabled |

## 4. Pillar B — multi-objective and Pareto fronts

### 4.1 Objective as a vector functional

Every element exposes *marginal objective per unit of each design variable* for
a vector of objectives (embodied carbon, cost, weight, and derived quantities
like drift-margin or a constructability penalty), behind one interface. Every
sizing operator — the OC weight vector, the owner/MIP objective coefficients,
the verify shrink-preference — reads the **same** functional. Extends O7's
"switchable objective" and finishes the half-wired carbon model (plan.md 2.5:
rebar must count in every RC objective, or the relaxation's weights are wrong).

> Note: for the OC update, the weight vector must be the *marginal objective*
> (e.g. marginal embodied carbon), not the geometric-volume proxy used in the
> dual-system demo. OC drives min-x only when wₑ is the gradient of x.

### 4.2 Fronts by continuation

Scalarize with weights w (weighted sum) or ε-constraints. The **relaxed**
optimum moves *smoothly* as w sweeps, so trace the relaxed Pareto front by
continuation — warm-start each weight from its neighbour — at near-zero marginal
cost. Then project only the **front points of interest** to discrete/detailed
fidelity. You never pay full discrete cost per Pareto point.

Compounded objectives (e.g. carbon *and* drift-margin) are just another weight
vector; nothing special is needed.

### 4.3 Honest limits

- The **discrete** Pareto front is not continuous; continuation gives the
  *relaxed* front, which **seeds** discrete points. Each projected point reports
  its own gap (Pillar A).
- Non-convex objectives (cost with fixed charges, carbon with threshold
  effects) break single-sweep continuation — use ε-constraint scans or
  multi-start, and expect a coarser front.

### 4.4 Work packages (Workstream P — Pareto)

| WP | Work | Acceptance |
|---|---|---|
| P.1 | Vector objective interface; finish RC rebar in carbon for beams/walls/footings (completes plan.md 2.5) | Objective matches the takeoff for every element type; a second objective (cost or weight) selectable |
| P.2 | Continuation sweep over scalarization weights on the relaxation; cache warm starts between weights | Relaxed front on B6/B7 traced in ≪ N× a single solve |
| P.3 | Project a chosen set of front points to verified designs; report the front with per-point gaps | A 2-objective (carbon, cost) verified front on one benchmark, each point gap-certified |

## 5. Pillar C — cost-aware fidelity scheduler

### 5.1 The idea

Treat the build as a **budgeted optimisation**: each subsystem has a
cost-vs-information profile and a fidelity ladder F0…Fk. A scheduler spends the
next unit of compute where it most tightens the bound or improves the objective.

- Run all **F0 / continuous / global** solves to convergence first — pennies,
  and they localise the answer and settle the coupling.
- For each expensive subsystem, build a **surrogate** from its cheap
  evaluations (e.g. punching capacity or rib-story deflection as a function of
  column size / rib depth, fit from a few coarse solves). The outer loop queries
  the surrogate; the **true** expensive model is invoked only (a) near the
  current best design, (b) when the surrogate predicts a binding constraint, and
  (c) warm-started — then the surrogate is refit.
- **Escalation rule:** escalate fidelity only when the expected objective gain
  (or bound tightening) from the higher-fidelity correction exceeds its solve
  cost.

### 5.2 Fidelity ladders (per subsystem)

| Subsystem | F0 (cheap) | … | Fk (expensive) |
|---|---|---|---|
| Members / lateral | continuous + linear + rigid-diaphragm + cached factor | catalog + checks | second-order (P-Δ, B1/B2); connections, panel zones, seismic capacity |
| Slabs | closed-form table pick | DDM/EFM; coarse FEA (superposition) | fine FEA + punching + **rib grillage** (the e0c0 case) |
| Foundations | closed-form bearing | rigid statics | Winkler / Shukla FE, per-combination |

This is the two-tier fidelity of `architecture.md` generalised to a *ladder*
with a scheduler deciding escalation, and it sits on the Phase-7 machinery
(superelements 7.10, coarse-to-fine 7.11, content-addressed caching 7.12). The
scheduler is the *policy layer* over those mechanisms; it does not re-implement
them.

### 5.3 Coupling settled global-cheap-first

The fixed stage order (slab→member→wall→foundation, no outer loop) causes both
staleness and the grow-only ratchets. Replace it with the documented coupling
graph (the 11 feedback edges, README §2) settled **once at F0** before any
discrete MIP or FEA runs. When the global coupling is resolved cheaply, the
high-fidelity passes are near-fixed-points: one corrective pass, not 20.

### 5.4 Determinism and safety

- **Determinism (O2).** Scheduler decisions must be a deterministic function of
  the design state (no wall-clock or worker-count dependence), so path
  independence holds under threads/processes (consistent with 7.13).
- **Safety (O1).** Surrogates and cheap fidelities only *guide*. Every reported
  design terminates in the independent full-fidelity verifier. Surrogates carry
  a **measured error band** per subsystem/system (reuse the F-workstream
  calibration, architecture.md §5 rule 3); a prediction within a band of a
  constraint boundary forces a true evaluation.

### 5.5 The e0c0 payoff

The chirality bistability being debugged in the other session is partly a
*discrete tie-break* instability in the inner loop between symmetric diagonals.
A continuous relaxation seed breaks that symmetry **deterministically** (the
continuous optimum is unique); the discrete step rounds it. So this architecture
removes a class of tie-break instabilities, and turns the rib-grillage FEA into
a validated surrogate rather than a per-column-step remesh (README §5 #4).

### 5.6 Work packages (extends Workstream F / Phase 7)

| WP | Work | Acceptance |
|---|---|---|
| C.1 | Fidelity ladder as an explicit per-subsystem property behind the owner interface (generalises F.3); scheduler API: given state + budget, choose the next (subsystem, fidelity) to evaluate | One subsystem runs at every ladder rung with identical checks |
| C.2 | Surrogate interface: fit from cheap evaluations, predict with an error band, trigger a true evaluation near a constraint boundary; refit after | Punching-vs-column-size surrogate on B1–B3 within band of the FEA; true FEA calls per run drop (target at baseline) |
| C.3 | Global F0 coupling solve over the feedback graph before discrete/FEA passes | Slab h can fall after a later column/wall change on B7 (no staleness ratchet) |
| C.4 | VOI escalation policy (deterministic); budget accounting in the run JSON | O2 holds under threads; full analyses/FEA calls reported and reduced |

## 6. The unified control loop

```text
settle_coupling_at_F0:                      # Pillar C.3 + Pillar A
    build one continuous, linear, rigid-diaphragm model of the whole building
    repeat (block coordinate over the feedback graph):
        OC / dual update of continuous sizes toward the objective
            s.t. global constraints + per-member strength-floor boxes
    until the continuous design is a fixed point
    record objective(continuous*) as the LOWER BOUND            # Pillar A.2

for each objective weight w on the swept front (continuation):  # Pillar B
    warm-start from the neighbouring weight
    continuous* (w) = settle_coupling_at_F0 under w

project_to_discrete (for the chosen w, or each front point):    # Pillar A.3
    scheduler orders subsystems by value of information          # Pillar C
    for each sizing-governed owner:
        run the discrete owner INSIDE the band around continuous*(w)
        for expensive subsystems: query the surrogate; escalate to the
            true model only near the optimum / near a binding constraint
    shrink-and-grow until no variable improves within its band

verify (unchanged trust anchor):                                # O1
    one full-fidelity analysis + all code checks at final sizes
    any failure -> local repair (bounded, may shrink) -> re-verify
report:
    verified design(s), per-element governing check + size driver,
    optimality gap vs the lower bound, and the Pareto set if swept
```

## 7. Mapping onto the existing component model

Nothing here is a parallel system; each mechanism lives in an `architecture.md`
component.

| New mechanism | Lives in | Relationship |
|---|---|---|
| Continuous relaxation / OC update | Analysis service (new F0 mode) + a relaxation driver | New fast-tier analysis; owners unchanged in spirit |
| Lower-bound certificate | Round controller + verifier report | New output, extends O4 |
| Vector objective + continuation | Objective component | Generalises O7; finishes 2.5 |
| Candidate band / warm start | Owner interface | Owners gain two inputs; internals (MIP/NLP) unchanged |
| Surrogates | Demand models + caching (7.12) | Demand models generalised to learned response surfaces with bands |
| Fidelity ladder + scheduler | Analysis service (fidelity) + round controller (policy) | Generalises the two-tier design |
| Shrink-and-grow, bound-anchored vars | Round controller | Replaces grow-only; cycle-guard stays as fallback |
| Final verifier | Verifier | **Unchanged** — stays simple and independent |

## 8. Phasing and dependencies

This layer is additive and should land **after** the Phase-2 design-state
registry and owner interface exist (it drives them). Suggested order:

1. **Depends on** plan.md Phase 2 (registry, owner interface, verifier) and the
   Phase-1 baseline (so gaps and pass-count drops are *measured*, not asserted).
2. **R.1–R.4** (relaxation + bound + warm-start band) — the core; proves the
   speed and the certificate on members first (overlaps Phase 3 columns).
3. **C.1–C.4** (fidelity ladder + scheduler + surrogates + global F0 coupling) —
   extends Workstream F and Phase 7; needed for the heavy subsystems (FEA slab,
   rib grillage, bracing).
4. **P.1–P.3** (vector objective + fronts) — last, once a single-objective
   relaxation+projection is trusted; P.1 (finish carbon) can land early since
   plan.md already wants it (2.5).

Every WP obeys the plan.md working rules: rerun touched benchmarks, report
O1–O5 deltas against the frozen baseline, and (new) report the optimality gap.

## 9. First proving slice

Smallest end-to-end validation, on a path the pipeline already supports:

- Wire the **global F0 relaxation** as a *warm start* into the **existing member
  MIP** on a mid-rise benchmark (B2/B3). Single objective (carbon), no
  scheduler, no fronts.
- Measure: (i) final sizes identical-or-lighter than today; (ii) beam⇄column
  pass-count collapse (the 20→~1 claim); (iii) the reported optimality gap.

If that holds, it validates Pillars A and C.3 on a supported path before taking
on the steel-LFRS wiring or the heavy-FEA scheduler.

## 10. API surface: every toggle reachable from the request

A toggle nobody can set is dead. Every knob these three pillars introduce must
be a first-class field on `DesignParameters` (`design/parameters.jl`) and travel
the **same plumbing chain** the existing `optimize_for` does, so it is reachable
from the REST `/design` + `/schema` path and from the agent/chat tools — not
buried as an internal kwarg. That chain, for one scalar toggle, is:

1. **DTO field** — `APIParams` (`api/schema/input_types.jl`), typed, with a
   today-preserving default.
2. **Deserialize** — `json_to_params` (`api/deserialize/floors.jl`) maps it onto
   `DesignParameters`.
3. **Validate fail-loud** — an enum/range check in `api/validation.jl` against a
   published constant (pattern: `API_OPTIMIZE_FOR` + `_push_enum!`), so a bad
   value fails at the boundary, not deep in sizing.
4. **Publish** — `/schema` via `api/schema/input_schema.jl` +
   `api/schema/params_schema.jl` (enum line + description + default).
5. **Agent/chat exposure** — `api/ontology.jl`, `api/design_state.jl`,
   `api/agent_tools/orientation.jl`, and the chat allow-list
   `api/chat/param_patches.jl`, so the design-assistant tools can read and set it.

**Default-preserving rule.** Every new toggle defaults to *today's behavior*
(relaxation off, full fidelity, single `optimize_for`), so flag-off runs stay
byte-identical — the same discipline the plan already uses for member-group
overrides and framing auto-generation. A test asserts the flag-off path is a
no-op.

### Toggle registry (target)

| Toggle | Pillar | Type / values | Default | Notes |
|---|---|---|---|---|
| `optimize_for` | B | `weight \| carbon \| cost` (exists) | `weight` | generalise to a vector below |
| `objective_terms` | B | list of (objective, weight) | `[(optimize_for, 1)]` | compounded / scalarized objective |
| `pareto_sweep` | B | nothing \| {objectives, n_points} | `nothing` | **response-shape change** — see below |
| `relaxation_seed` | A | `off \| on` | `off` | continuous warm start into the owners |
| `candidate_band` | A | int ≥ 0 (catalog steps) | owner default | width of the bounded discrete search |
| `report_optimality_gap` | A | bool | `false` | emit the certified gap in the result |
| `allow_shrink` | A | bool | current policy | shrink-and-grow vs grow-only in verify |
| `fidelity` | C | `fast \| full` | `full` | selects the analysis-service tier (architecture.md §5) |
| `compute_budget` | C | nothing \| budget spec | `nothing` | scheduler ration; surrogate enable + escalation threshold |

### One deeper change, flagged early

`optimize_for` → `objective_terms` and `fidelity` are ordinary scalar/enum
toggles and fit the chain above unchanged. **`pareto_sweep` is different: it
changes the response shape** — a sweep returns a *set* of verified designs with
their gaps, not one `DesignResult`. That needs a `/design` response schema
addition (a `front: [...]` block) and a viewer that can hold multiple designs,
so it is scoped as its own WP (part of P.3) rather than a drop-in field. The
single-objective toggles (A, C, and `objective_terms`) land with no response
change.

### Work package

| WP | Work | Acceptance |
|---|---|---|
| API.1 | Thread A/C toggles + `objective_terms` through all five chain stages; fail-loud enums; `/schema` publishes them; chat allow-list updated | Each toggle settable via `/design` JSON and visible in `/schema`; flag-off runs byte-identical on B1–B7 |
| API.2 | `pareto_sweep` response-shape extension (`front` block) + multi-design result | A 2-objective sweep returns N gap-certified designs over REST |

## 11. Open questions / sign-offs

- **Multi-λ update** stability and the exact dual scheme for several
  simultaneously-active constraints (drift per story + wind + strength).
- **VOI metric**: the concrete form of "expected objective gain per unit solve
  cost", and how it reconciles with the move-limit / trust-region rule already
  signed off.
- **Surrogate model class** per subsystem (interpolation vs GP vs low-order
  physics) and how error bands are estimated and certified.
- **Scaling laws** (R.1): fit quality per section family, and the residual the
  verifier must absorb.
- **Non-convex objectives** (cost with fixed charges): continuation vs
  ε-constraint vs multi-start, and the front resolution we promise.
- Safety-critical items (second-order, strength floors, A↔I coupling) are
  handled only in the verifier by contract — this must be enforced by a test
  that the relaxation path never writes a final size.
