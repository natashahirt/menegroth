# Sizing pipeline plan

Status: revised 2026-11-11. Target design: [`architecture.md`](architecture.md).
Current state: [`README.md`](README.md) ("rank N" = row N of its size-impact
table). Benchmarks: [`phase1-benchmarks.md`](phase1-benchmarks.md).

## Why

The pipeline is built for guaranteed termination and code-cited feasibility,
and does both well. It is not built to find a light design, for three
reasons:

1. **Sizes are the only shared state.** Each failing check writes a bigger
   size onto `BuildingStructure`. Columns have seven writers, each grow-only.
   Nothing records why a size was set, so nothing notices when the reason
   goes away.
2. **Grow-only is how loops converge.** Any size reached on stale or
   provisional information is permanent: the seed, a column grown at a
   thinner slab, a slab thickened against a wall before the wall was resized.
3. **Fixes are local and greedy.** The first failing check picks what grows.
   Coupled choices (slab vs. column vs. studs, which wall to thicken) are
   compared on carbon only in the flat-plate joint search.

Two smaller patterns compound these: envelopes of demands that do not occur
together, and stand-in values (two-way αfm, the column seed) that are never
replaced.

The goal is the architecture in `architecture.md`: fast, path-independent,
verified sizing, so that an outer loop can compare layouts and systems on
their merits.

## Objectives

Each objective has a metric from the Phase 1 runner. Numeric targets marked
**(set at baseline)** are fixed once the baseline exists and recorded under
Decisions.

| # | Objective | Metric | Target |
|---|---|---|---|
| O1 | Safe | Final verification (full analysis + all checks at final sizes) on B1–B7 | 100% pass, every phase |
| O2 | Path-independent | Same benchmark under three perturbations: slab order reversed, column seed ×1.5, column seed at minimum | Identical sizes for ≥ 95% of elements; total carbon within 1% |
| O3 | No artificial drivers | Final `size_driver` counts | Zero elements governed by `seed`, `stacking` or `slab_old` after Phase 3 |
| O4 | Lightweight | Oversize per element: final size versus the lightest size its own final demands allow | Median and 90th percentile per element type reduced **(set at baseline)** |
| O5 | Efficient | Building factorizations and runtime per benchmark | No phase raises either by more than 10% without sign-off; Phase 3 cuts building analyses **(set at baseline)** |
| O6 | Auditable | Driver coverage; verifier independence; checks pure | Every final variable has a governing check and a size driver; verifier imports no optimiser code; checks pass a no-mutation test |
| O7 | Carbon reported honestly | Carbon covers every material | Walls, wall rebar, drop panels, studs and cladding in the takeoff before the baseline is frozen |

O2 and O4 have no baseline value yet. The Phase 1 runner reports them on
today's code so the improvement is measured, not asserted.

## Phases

Each phase lists its work packages (WP) with acceptance criteria. A WP is
small enough to hand to one agent and audit in one pass. Phases 0–1 are
sequential; Phase 7 (speed) can run in parallel from Phase 1 on.

### Phase 0 — Safety and carbon accounting

These change reported numbers, so they land before the baseline is frozen.
All are signed off (see Decisions) except 0.8.

| WP | Work | Acceptance |
|---|---|---|
| 0.1 | Steel columns: forward signed FEA end moments to sizing (AISC 360-16 App. 8 Eq. A-8-4). Unknown end moments with compression and moment: Cm = 1.0 | Hand-calc test: single and double curvature column; regression shows which benchmark columns changed |
| 0.2 | Steel members with transverse load: Cm by analysis (App. 8 §8.2.1(b)). **Ground the method in the corpus first**; if it cannot be grounded, stop and ask | Corpus citation in code; hand-calc test |
| 0.3 | Cladding `wall_SDL`: perimeter length × story height, skipped at structural exterior walls, half to floor above and half below. Enters gravity, foundations, W and Px | Test: totals match hand sum; seismic W rises by the expected amount |
| 0.4 | Foundations: per-combination demands per the approved defaults (Decisions) | Test per combination type; uplift and sliding reported |
| 0.5 | Rigid mats: rigid-body strip statics (ACI 336.2R §6.1.2 Step 3), overhangs included | Hand-calc test on a two-line mat |
| 0.6 | Wall carbon: concrete × column concrete factor, designed ρt/ρl rebar × rebar factor | Wall row in `DesignSummary` and takeoff |
| 0.7 | Drop panels, shear caps and studs split out of building totals | Per-element takeoff on B3 sums to today's totals |
| 0.8 | Vertical-floor safety gaps (list below): confirm each by reading code, then bring to the user. **No code until signed off** | One-page note per confirmed gap with code and clause |

Vertical-floor gaps for 0.8 (from `raw/vertical-floor-interaction.md` §11;
the ones marked inferred need confirming before they go to the user):

- Floors other than flat plate deliver zero out-of-plane moment to walls
  (eccentric bearing of beams, one-way slabs and vaults ignored).
- Vault thrust on a wall edge is not an out-of-plane wall demand (inferred).
- Composite deck bearing and web crippling at supports never run.
- `:flat_slab` escapes the row-F refusal that `:flat_plate` triggers.
- Flat-plate wall axial load uses the tributary split, not the slab FEA
  reaction (which draws more load to walls under fixed rotation).
- Any wall touching a slab makes all its flat-plate columns nonsway by
  inspection.
- Diaphragm type is user-declared with no check against the designed floor.
- No wall-reaction punching, one-way shear or anchorage checks for two-way,
  one-way and waffle panels on walls (inferred).

### Phase 1 — Baseline and instrumentation

Detail and file:line hooks in `phase1-benchmarks.md` §4–5.

| WP | Work | Acceptance |
|---|---|---|
| 1.1 | Asap analysis log (`ScopedValue`, zero cost when off), including rigid-diaphragm solves | On B1 (no diaphragm links), building factorizations equal `_N_FACTORIZATIONS` |
| 1.2 | `SizingProbe`: stage spans, loop rounds, size drivers at every writer | B1 `DesignSummary` identical with and without the probe |
| 1.3 | Fixtures B1–B5, B7. B6 after the user approves the agent's proposed seismic row, lateral inputs and deck-on-wall fallback (`phase1-benchmarks.md` §2b) | Each runs twice with identical sizes, rounds and carbon |
| 1.4 | `sizing_baseline.jl` runner: JSON plus four CSVs, ledger registration | Files match the schema in `phase1-benchmarks.md` §5b |
| 1.5 | Perturbation runs for O2; lightest-own-demand sizes for O4 | O2 and O4 reported on today's code |
| 1.6 | Freeze the baseline after Phase 0 lands; set the **(set at baseline)** targets with the user | Ledger row per benchmark; Decisions updated |

### Phase 2 — Design state and round controller (no behaviour change)

The frame the remaining phases plug into. Lives beside `BuildingStructure`.

| WP | Work | Acceptance |
|---|---|---|
| 2.1 | Design-state registry: variables keyed by element id, with owner, domain, value, history, governing check, size driver. Single `apply!` writes values back to `BuildingStructure` | Test asserts sizing fields are written only through `apply!` |
| 2.2 | Owner interface: requirements in; value, utilisation and governing check out. Wrap today's stages as owners without changing their logic | B1–B7 sizes and carbon identical to baseline |
| 2.3 | Round controller: one building analysis per round, move limits, hybrid cycle rule (a cycling variable becomes grow-only), skip owners whose requirements did not change, per-round audit record | Unit tests on a toy problem: converges, detects a two-cycle, stops at budget |
| 2.4 | Final verifier as its own module: full analysis plus all checks, no imports from demand models, move limits or clusters | Fails a deliberately undersized design in a test |

### Phase 3 — Columns as the first owner (largest size win)

Columns appear in ranks 1, 3, 4, 5 and 9.

| WP | Work | Acceptance |
|---|---|---|
| 3.1 | Column owner: tagged requirements (axial, P-M case set, punching from slab s at h, row-F, envelope); picks the lightest catalog section meeting all of them; may shrink | Replaces the seven grow-only writers |
| 3.2 | Drop stacking as a sizing rule; harmonize becomes an optional policy comparing whole sections | O3: no `stacking` drivers |
| 3.3 | Flat-plate joint search as the first cluster: top-down by story, emits punching requirements instead of writing sizes | Building-level joint-search tests pass; replaces the stored per-column floor work |
| 3.4 | Seed from axial demand; flat-plate restarts reset columns to their requirements | O3: no `seed` drivers |

Exit: O1, O2, O3 met on B1–B5; O4 and O5 reported against baseline.

### Phase 4 — Concurrent demand sets

| WP | Work | Acceptance |
|---|---|---|
| 4.1 | `DemandSet` (cases with concurrent P, Mx, My, V) through member groups, foundation groups and wall out-of-plane checks (ranks 8, 13, 14) | Checks consume case sets; envelope helpers removed from those paths |
| 4.2 | Foundation grouping: sort descending, bound by the group minimum | Hand test on a three-footing group |

### Phase 5 — Walls and vertical-floor coupling

Absorbs the former Workstream V. Source: `raw/vertical-floor-interaction.md`
§10 and §12.

| WP | Work | Acceptance |
|---|---|---|
| 5.1 | Wall owner: thickness and ρ re-derived each round from requirements (rank 10, 14) | Walls can thin when demand falls |
| 5.2 | Drift cluster: wall thicknesses chosen together on carbon using `story_drift_sensitivity` (rank 6) | Only drift-effective walls grow in B6/B7 |
| 5.3 | Wall thickness change restales the slabs that read it (punching at wall, §12.12.1 anchorage, out-of-plane moment) | Slab h on B7 can fall after a wall jump |
| 5.4 | Out-of-plane moment recomputed after slab redesign; top and bottom split between piers by stiffness; paired per case, not with 0.9D | Hand test on a two-story pier |
| 5.5 | Studs at wall reactions (needs the code-basis sign-off already pending); §12.12.1 failure emits a wall-thickness requirement instead of failing the slab | Joint search can pick studs at walls |
| 5.6 | B.6 20% gravity-share gate reported as a failed requirement, not a throw | Run completes and reports the failure |

### Phase 6 — Stand-ins, slabs, beams, foundations

| WP | Work | Acceptance |
|---|---|---|
| 6.1 | Two-way: size beams, compute αfm, re-check h (Eq. 9-12/9-13), re-size beams once (rank 2); credit wall edges in mixed panels | B4 slab h at or below baseline, verified |
| 6.2 | Spread footings: rectangular; joint (B, h) minimum volume (rank 15) | Footing carbon at or below baseline, verified |
| 6.3 | Mat strips: the remaining open items (Decisions) after corpus check (rank 7) | Signed off before code |
| 6.4 | Policies separated: uniform sizing, grouping and harmonize declared as named, switchable policies; retire the remaining grow-only paths | Policy list in the run JSON |

### Phase 7 — Speed (parallel track from Phase 1)

| WP | Work |
|---|---|
| 7.1 | Hoist P-M capacity caches out of loops; key the MIP memo on catalog value |
| 7.2 | Wall thickness changes update shell thickness in place instead of rebuilding |
| 7.3 | Beam ⇄ column loop: warm start, per-group demand tolerance (cycle detection moves to 2.3) |
| 7.4 | FEA flat plate: fixed mesh with column patch stiffness |
| 7.5 | Bisection for Winkler mats |
| 7.6 | Per element type: compare demand-model predictions with the next analysis; use models where they save rounds |

Acceptance for every 7.x: identical sizes on B1–B7 (or differences explained
and verified) and a measured runtime or analysis-count drop.

### Later

Drop-panel depth and extent in the joint search; rebar in RC objectives;
waffle per-corner heads; one-way per-cell thickness; slab-column frame
sharing lateral load; `deck_floor_diaphragm` to set the diaphragm
automatically; wall layout NLP as the first outer-level stage.

### Carried over from earlier work

Correctness items started before this plan. They land before the Phase 1
freeze:

- Beam and one-way pattern loading per ACI 318-19 §6.4.2, and vault thrust
  (in progress).
- Flat-plate column sway classification (§10.10.5) and real k. Overlaps the
  nonsway-by-inspection gap in 0.8; resolve together.
- One-way slab continuity from geometry.
- Tests that encode wrong answers, plus equilibrium tests.

The building-level joint-search items (top-down order, per-column floor,
commit pass) are superseded by 3.3.

## Working rules

- **Code-derived work** (0.1–0.5, 0.8, 5.4, 5.5, 6.1, 6.3): corpus citation
  with source, clause and page before code; hand-calc test; anything
  ambiguous goes to the user.
- **Every WP** reruns the benchmarks it touches and reports O1–O5 deltas
  against the frozen baseline.
- **Efficiency:** count full analyses, not loop rounds; one building analysis
  per round, shared by every owner; skip owners whose requirements did not
  change.

## Decisions

### Architecture (user, 2026-11-11)

- Objective: embodied carbon, with a switchable objective. Studs: raw
  carbon, with options to disable studs and to add a weighted stud cost
  later.
- Convergence: hybrid. Sizes iterate freely; a cycling variable becomes
  grow-only from that round on; every design ends with a full verification.
- Stacking dropped as a sizing rule, including the "column above is a lower
  bound" rule. Bar offset at a smaller lower column (ACI 318-11 §7.8.1) is a
  later detailing check.
- Design-state registry lives beside `BuildingStructure`.
- Demand models versus re-analysis decided per element type by measurement
  (7.6).
- Efficiency is a first-class goal alongside carbon.
- Objectives (user, 2026-11-11): O2 thresholds (≥ 95% identical sizes,
  carbon within 1%) approved. O4 oversize measured against the lightest size
  each element's own final demands allow (one extra sizing run per
  benchmark), not 1 / utilisation.

### Phase 0 sign-offs (user, 2026-11-11)

- Steel members loaded between supports: Cm by analysis per AISC 360-16
  App. 8 §8.2.1(b). Method must be grounded in the corpus (candidate: the
  App. 8 commentary Ψ formulation from first-order deflection and moment).
  If not groundable, back to the user.
- Steel columns: signed FEA end moments (Eq. A-8-4). Unknown end moments:
  single curvature, M1 = −M2, Cm = 1.0 (ENGINEERING JUDGMENT; the spec has no
  rule).
- Rigid mats: rigid-body strip statics, overhangs included. Faces: column
  lines put the bottom in tension, spans the top. Still open: strip vertical
  summation mismatch (Bowles 1982 not in the corpus), full-width versus
  column-band steel, single-column-line mats.
- Seismic weight already includes frame and wall self-weight. Cladding as in
  0.3 (ENGINEERING JUDGMENT, same half-split rule as walls).
- Foundation combinations: ASD bearing with qa; all ASCE 7-22 §2.4 (bearing)
  and §2.3 (strength) combinations with nonzero loads; §12.13.4 overturning
  reduction, Ev = 0 at the soil and the 0.5L factor are options, off by
  default; no allowable bearing increase; no partial contact until a corpus
  source is found; uplift reported as a failed check; sliding checked when a
  friction coefficient is given, flagged otherwise; footing and soil weight
  in D; ±X and ±Y separately (orthogonal combination after §12.5 research);
  pattern live cases enveloped.

### Phase 1 sign-offs (user, 2026-11-11)

- Benchmarks B1–B7; B8 weekly only. Agent proposes the B6 seismic row and
  lateral inputs from the existing wall-stage tests.
- Wall carbon: wall concrete × column concrete factor, plus designed ρt/ρl
  rebar × rebar factor.
