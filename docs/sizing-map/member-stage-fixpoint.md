# Flat-plate member stage as a fixed-point solver

Design note for turning `_design_flat_plate_members!` (loop **L4**) from an
oscillating, throwing, remesh-per-round loop into a convergence-guaranteed,
speed-optimized fixed-point solver. Companion to `audit-2026-11-18/speed.md`
(opportunity numbers below are its §3 ranking) and `audit-2026-11-18/pipeline.md`
(loop ids L0–L15).

Status: **design + exact core**. Approximations are scoped but gated (§7).

---

## 1. What the stage is

Strip the ACI-clause accretion away and the member stage is a **coupled fixed
point** over member sizes `s` (column plan sizes + sections; slab thickness,
reinforcement, studs/drops):

- **A: sizes → demands.** `D = A(s)` — the FEA / frame analysis. Expensive:
  a flat-plate slab analysis is 27–36 s on a remesh, 4–6 s value-only
  (`speed.md §1b`). This is the *only* expensive map.
- **B: demands → required sizes.** `s' = B(D)` — the ACI checks (P-M §10,
  two-way shear §11.11, slenderness §10.12). Cheap, analytic, per member.

A design is self-consistent: `s* = B(A(s*))`.

The current L4 is an **undamped Picard iteration** `s_{k+1} = B(A(s_k))` that
(a) re-runs the expensive map A every round, (b) has no contraction or
monotonicity guarantee, and (c) stops on **exact size equality**
(`_slab_checked_at_installed_columns`). That is the worst available design and
it produces the two measured failure modes (both confirmed pre-merge on
`78940b2a`, `find-3ed41c8d`):

- **Mode 1 — `uniform_column_sizing = :off`.** L6 (`check_flat_plate_columns!`)
  is a *two-sided* fit: it can **shrink** a column to the lightest passing
  section. The slab was stamped at the old size, so the shrink re-stales it;
  the redesign shifts demand; L6 re-fits; repeat. The `floors` ratchet only
  floors columns that *grew* this round, so a shrink slips under it.
- **Mode 2 — `uniform = :per_story/:building`.** `harmonize` promotes every
  column in a group to the group **max**. One slab's growth bumps all its
  group peers; exact-equality staleness then marks every peer slab stale even
  though its column only got *bigger*. Shared columns make this a standing
  ripple.

Compounding both: the default `punching_strategy = :grow_columns` makes a
slab's reflex to a punching failure to grow its own column, and "a stiffer
column attracts more moment" (`punching_resolution.jl`), so growth on one
column re-stales another.

---

## 2. Design principles

- **P1 — Converge on demand stability, not size equality.** A discrete section
  fixed point need not exist (two stiffnesses can each make the sizer pick the
  other — the exact premise of `_check_settle!`). Size equality is the most
  brittle possible stop; a demand tolerance plus cycle detection is robust.
- **P2 — Call A rarely and make each call cheap.** A is the cost. Fewer rounds
  (demand tolerance), and a *value-only* re-check instead of a remesh on the
  common path, do more than any kernel tuning.
- **P3 — Decouple B per member against frozen demands.** Against one analysis
  snapshot, every member sizes independently (Jacobi, not Gauss–Seidel): the
  slab reads the column sizes *as of the analysis*, the column reads the slab
  joint moments *as of the analysis*. That is embarrassingly parallel and
  deterministic; a single reconcile pass resolves shared/uniform groups.
- **P4 — Guaranteed termination.** Finite catalog ⇒ finite states ⇒ a repeat
  must occur within `n_states + 1` rounds. On a repeat, resolve to the
  **passing envelope** (reuse the `_check_settle!` philosophy) instead of
  `error(...)`.
- **P5 — Exact by default; approximations gated.** No capacity check and no
  engineering policy changes by default (`code-accuracy.mdc`). Fixed/coarse
  mesh, Woodbury, and predict-then-confirm are opt-in behind a confirm gate
  with accuracy bands pending sign-off (`speed.md` open Qs 5–7).

---

## 3. The algorithm

`analyze` here is the loop's existing stiffness refresh
(`refresh_flat_plate_analysis!` + `_reconcile_columns!`'s value-only re-solve),
not a new call: a column grows, the frame is re-solved value-only, and the new
demands are read from that solve. "Demand snapshot `D`" is the per-column
`(Vu, Mub, Muy)` and per-slab governing joint moments at the current solve.

```
# state s = (column plan sizes + sections, slab stamps).
seen = []                       # column-section states this call has produced
D_prev = nothing
loop (bounded by max_iterations and by n_states + 1):
    # B, in parallel against the current solve (Jacobi): each member reads the
    # sizes/demands as of this solve, designs independently, then one reconcile.
    size columns for axial / P-M / slenderness   (L5 + L6, two-sided fit allowed)
    size slabs for punching at those columns      (per configured punching_strategy)
    reconcile shared + uniform groups ONCE        (deterministic max per group)
    D = demands at the (value-only re-solved) model
    record state s in `seen`
    if s repeats a state in `seen`:               # cycle (Mode 1/2)
        install the passing-envelope state (§5); break with a diagnostic, not a throw
    if no slab is stale (§4) AND ‖D − D_prev‖∞ / ‖D‖∞ < tol: break   # converged
    D_prev = D
```

`tol` is a small relative demand tolerance (start 1 %, a named constant, not a
magic literal); the first round always proceeds. Correctness: at exit either
(a) demands are stable and every member passes its own checker at the installed
sizes, or (b) a cycle was resolved to a state where every member passes
(envelope), recorded in `stage_diagnostics` when no single state passed. No
capacity check is weakened; only the orchestration changes.

**Scope / non-goals.** This note is the flat-plate member stage only; the beam
path (L9) already has `_check_settle!`. The ACI checkers (`flat_plate_column_checks`,
the punching kernels, `_fit_flat_plate_columns!`) are reused **verbatim** — the
change is orchestration (the settle loop + staleness rule), so the blast radius
is one loop, not the checks. Parallel per-member design must be **bit-identical**
to the sequential result (the reconcile max is order-independent; spawns write
disjoint members), preserving the determinism contract the design graph relies
on.

---

## 4. Re-check, not redesign (approximate under remesh; speed #12)

> ⚠️ Exactness caveat. A slab's punching *demand* (`Vu`, `Mub`) depends on the
> column through the FEA mesh (the column patch is in `fea_mesh_key`), so a
> truly exact demand at a grown column needs a remesh — the expensive thing we
> want to avoid. Re-checking with the *last* demands and the *new* `b0` is only
> **approximately** conservative (bigger `b0` ⇒ more capacity is first-order;
> the demand shift from the stiffer column is second-order). So this lever is
> **gated**, not default-on, until it rides on the fixed mesh (#1), where the
> re-check becomes exact. The default convergence fix is §5 (cycle-settle),
> which needs no re-check and is exact-ish.


Today a stale slab is redesigned from scratch (a new `fea_mesh_key` ⇒ a
remesh). Replace the staleness rule:

> A slab is stale only if its stamp ≠ installed columns **and** a *re-check*
> of its two-way shear at the installed columns, on the existing value-only
> re-solve, fails.

When harmonize / reconcile only made a supporting column **bigger**
(conservative), re-run just that slab's two-way shear check — ACI 318-11
§11.11.7 (shear from the unbalanced moment, `γv`) and the §13.5.3.2 flexural
transfer fraction — at the installed column, reading the value-only re-solve the
reconcile step already performed (no new expensive analysis). Pass ⇒ re-stamp
the slab as checked-at-installed and keep its design unchanged (**exact** — the
slab is now verified against the actual installed column). Fail ⇒ redesign per
the configured strategy. This removes the harmonize ripple and replaces a full
remesh+redesign with a value-only check on the common path. (A column that
*shrank* is handled by cycle resolution, §5, not by re-check.)

---

## 5. Cycle resolution (exact-ish; kills Mode 1)

Record the column-section state each round. On a repeat (a 1- or k-cycle),
take the **per-column envelope** (max plan size / costliest section) over the
states in the cycle, install it, and do one confirming pass. Floors engage
*only* to break a detected cycle, so the common converging case keeps the
two-sided fit's minimal material — no blanket "never shrink", no
over-conservatism. This mirrors `_check_settle!`'s "keep the cheapest section
that passed in some state, else the costliest" rule, specialized to columns
+ slab stamps.

---

## 6. Where each speed optimization attaches

Isolating A and B (P2/P3) gives every `speed.md` idea a clean home:

| Lever | speed.md # | Exact? | Attaches to | Default |
|---|---|---|---|---|
| Demand-tolerance + cycle-settle (fewer A calls, no throw) | new | exact-ish | the loop (§3) | **on** |
| Re-check not redesign (value-only on common path) | 12 | approx (exact on #1) | staleness (§4) | gated |
| Hoist P-M caches / memo catalogs once per call | 10 | exact | B (column checks) | **on** |
| Parallel per-member design against frozen D | 13 | exact | B (Jacobi + reconcile) | **on** |
| Content-addressed FEA cache (key by content, not slab_idx) | 4 | exact | A (slab analysis) | **on** |
| Fixed slab mesh (patch re-tag, no remesh) | 1 | approx | A | **gated** (sign-off) |
| Woodbury / low-rank refactor for column-only changes | 2 | exact* | A (Asap) | gated (conditioning) |
| Predict-then-confirm punching | 3 | approx | B→A trial count | gated (predictor policy) |
| Coarse-mesh fast tier | 5 | approx | A | gated (band) |
| Rigid-link solve cache in Asap | 7 | exact | A (Asap) | separable |

`exact*` = exact to round-off. The approximations (1, 3, 5, and 2's
conditioning) have open accuracy bands in `speed.md §4`; they are designed for
but not switched on by default here.

---

## 7. Judgment calls (made here)

1. **Punching ownership — keep the configured `punching_strategy` (default
   `:grow_columns`).** Convergence is achieved *algorithmically* (cycle-settle
   + re-check), not by flipping who owns punching. We decouple the *iteration*,
   not the *engineering*, so no code-compliant design silently changes. A
   future "slab owns punching via studs/thickening at a fixed column" mode is a
   clean decoupling for speed, but it changes results and stays a gated,
   signed-off option.
2. **Convergence criterion — demand tolerance as the fast exit, cycle-settle
   as the backstop.** Reuse the `_check_settle!` philosophy rather than invent.
3. **No spurious throw.** Replace L4's `error("...did not settle...")` with a
   settled, passing-envelope result plus a `stage_diagnostics[:members]` entry
   when a genuine cap-bound infeasibility remains — consistent with how the
   beam path and L6 already report non-settling.
4. **Both paths.** The imperative L4 (`_design_flat_plate_members!`) and the
   DAG lock node (`_push_two_level_slab_nodes!`) share one settle helper.

---

## 8. Validation

## 8. What was implemented (evidence-based)

The cycle was captured with an env-gated per-round trace
(`SS_DEBUG_MEMBER_SETTLE=1`, `scripts/runners/repro_member_settle.jl`). Findings:

- On the current tree the **DDM** fixtures converge fast — the small 3×3×1
  per-story case in **1 round** (nothing stale), a 4-story DDM office in **2
  rounds** (3 slabs stale → redesign → 0 stale). The loop is *not* broken for
  these.
- The throw reproduces on the **four-story core office** (FEA strip + core
  walls, `uniform_column_sizing` defaulting to `:off`). The trace shows **Mode
  1**: round 1 lower columns grow to 16 in (floored); round 2 they ratchet to
  20 in (floored) **while upper-story columns shrink 12 in → 10 in** — a shrink
  that `_raise_column_floors!` never floors (it floors only growth). The four
  stale slabs never clear, and the budget throws.

Root cause in code: `_fit_flat_plate_columns!` sets
`shrink = params.uniform_column_sizing === :off` and, in shrink mode, does **not**
raise the per-column floor to the installed size — so a column absent from the
`floors` dict shrinks freely, re-staling the slab it supports, which regrows it.

Fix (`StructuralSynthesizer/src/workflow/graph_builder.jl`): a new
`_floor_columns_at_installed!(floors, struc)` pins *every* installed column into
`floors` (a) once after the pre-loop reconcile (one initial right-size is still
allowed) and (b) at the start of every settle round. The two-sided fit still
respects `floors` as a hard lower bound, so the stage becomes **grow-only /
monotone** and terminates. The throw is kept as the genuine-infeasibility
backstop (cap exceeded). Cost: a column may finish one catalog step above its
lightest passing section — conservative, never unsafe (§5).

> Note: this fixes the imperative member stage (stage 2). The stage-1 shared-
> column DAG lock node (`_push_two_level_slab_nodes!`) is a separate path with
> its own settle; it did not throw in these traces and is tracked separately.

## 9. Validation

Oracles already encode the target:
`test/design_graph/test_design_graph_equivalence.jl` (coarse path == fine DAG)
and `test/design_graph/test_design_graph_incremental.jl` (shared-column
propose/envelope/commit/lock). Add focused unit tests: a shared-column flat
plate settles in bounded rounds; a harmonize bump that still passes triggers no
redesign; a constructed 2-cycle resolves to a passing envelope. Then the
`core/` + `design_graph/` suites, then the stage-split measurement (`speed.md`
open Q1) on the now-converging core office.
