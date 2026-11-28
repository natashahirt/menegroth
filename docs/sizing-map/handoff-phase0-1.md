# Handoff: delegated work packages, Phases 0–1

For the implementing agent. Written 2026-11-11. Each work package (WP) is
audited separately afterwards, so finish one, write its report, then start the
next.

Read first: [`plan.md`](plan.md) (objectives, decisions),
[`architecture.md`](architecture.md) (target design),
[`phase1-benchmarks.md`](phase1-benchmarks.md) (instrumentation detail), and
the research notes in [`phase0/`](phase0/).

## Rules for every WP

- **Safety-critical code.** Follow `.cursor/rules/code-accuracy.mdc` and
  `corpus.mdc`. Any code-derived equation, factor or limit: corpus citation
  (`source_id`, clause, PDF page) in a comment, and a hand-calculation test.
- **Stop and ask** if anything is ambiguous: a clause, a sign convention, a
  load path, a unit. Every item listed under "Ask before deciding" must go to
  the user; do not choose a default yourself.
- **Out of scope means out of scope.** If you find another problem, list it
  in the report; do not fix it.
- **Tests.** Use `julia scripts/runners/test_quiet.jl <Pkg> <file>`; run the
  targeted files, then `--fresh` once at the end of the WP.
- **Branch per WP:** `sizing/wp-<id>`. Record to memory before each commit
  (`memory.mdc`).
- **Report.** Write `docs/sizing-map/reports/wp-<id>.md`: files changed
  (with line ranges), tests added and their results, any deviation from this
  brief and why, out-of-scope findings, open questions. Keep it short; the
  auditor reads the diff alongside it.

## Order

| Wave | WPs | Notes |
|---|---|---|
| A (parallel) | 0.1, 0.3, 0.5, 0.6+0.7, 1.1+1.2, 1.3 | Independent files |
| B | 0.4a → 0.4b | Sequential; audit between |
| C | 1.4 → 1.5 | Needs 1.1–1.3 merged |

Not delegated (done by the lead agent): 0.2 (Cm by analysis), 0.8 (vertical
safety-gap triage), 1.6 (baseline freeze), Phase 2 interfaces. Phase 7
(speed) is briefed after the baseline exists.

---

## WP 0.1 — Steel Cm: column end moments and unknown curvature

Source: `phase0/steel-cm-and-mat-coefficient.md` Issue C.

Do:
1. Steel columns: forward the signed `M1x/M2x/M1y/M2y` already computed by
   `member_group_demands` (SY `analyze/members/members/demands.jl:792-801`)
   into steel column sizing. Today `SY size_columns.jl:146-162` drops them
   and the array `size_columns` rebuilds demands at SS
   `members/optimize/api/columns.jl:241-248` without them. Add a
   demand-vector `size_columns(demands, geometries, opts::SteelColumnOptions)`
   path mirroring the RC one.
2. `MemberDemand` default for unknown end moments: `M1 = −M2` (single
   curvature, Cm = 1.0) instead of `M1 = 0` (SS
   `members/types/demands.jl:86-100`). Fix the docstrings at `:43-44, :77-78`
   and the comment at SY `demands.jl:916-919`. Label it ENGINEERING JUDGMENT
   (user decision 2026-11-11; AISC has no unknown-curvature rule).
3. Steel beams, girders, joists and struts carrying span load: thread
   `transverse_load` through the array `size_columns`/`size_beams` path
   (dropped at SS `columns.jl:241`) and set it `true` for non-column groups
   (SY `demands.jl:931-938`). AISC 360-16 App. 8 §8.2.1(b) permits Cm = 1.0
   conservatively. This is the interim value until WP 0.2 replaces it with Cm
   by analysis.
4. Fix the citation in `moment_amplification.jl:34-44`: AISC 360-16 PDF
   page 306 (printed 16.1-250).

Acceptance: the four tests in Issue C §C.8 (W10X49 hand calc: Pe1x =
2758.3 kip; Pr = 400 kip gives B1 = 1.170 at Cm = 1.0); routing tests prove
the checked demand carries the FEA end moments (columns) and
`transverse_load = true` (beams).

Out of scope: the steel NLP column path having no B1; group Cm taken from
the max-|M2| member. List both in the report.

## WP 0.3 — Cladding dead load (`wall_SDL`)

Source: `phase0/seismic-weight-and-foundation-lateral.md` Issue A.

Signed-off rule (ENGINEERING JUDGMENT, user 2026-11-11): cladding load =
`wall_SDL` × story height × perimeter edge length, skipped on perimeter
edges with a structural exterior wall, half to the floor at the top of the
band and half to the floor at the bottom. It enters the gravity design,
foundations, seismic weight W and Px.

Do:
1. Apply it in the building frame model as line loads on perimeter edges with
   a dedicated id (e.g. `:cladding`), included in the dead case so columns,
   beams and foundation reactions see it.
2. Add it to `_elf_weight_items` (`SY analyze/lateral/elf_story_cases.jl:
   465-515`) with the half split, so W, Px, and the flexible and semirigid
   diaphragm totals (which throw on mismatch) stay consistent.
3. Update the dead-case identity test (`test_elf_story_cases.jl:223`) and add
   the Issue A §A.7 hand calc extended with a cladding band.

Ask before deciding:
- Slab-level designers (flat plate DDM/EFM/FEA; two-way edge beams): map how
  each would receive an edge line load and report. Do not change slab design
  until the user approves.
- The bottom half of the ground-story band sits at the base: excluded from W
  and Px (§12.7.2 counts weight above the base), but whether and how it enters
  foundation demands needs the user.
- Parapets above the roof (no height data exists).

## WP 0.4a — Per-case support reactions (no behaviour change)

Source: Issue B §B.1–B.4.

Do:
1. Compute support reactions per primitive load case (D, L, Lr/S if present,
   each wind direction, each ELF direction and torsion variant) from the
   existing non-mutating `Asap.solve` outputs: R = S[fixed,:]·u − F[fixed],
   as in `_service_reactions` (SY `analyze/foundations/demands.jl:57-68`).
   Include pattern live cases.
2. Extend the foundation demand to carry a vector of per-case reactions
   (P, Mx, My, Vx, Vy) per support, including grade-wall base nodes
   (`wall_groups.jl:418-424`). Keep the existing single-set fields filled
   exactly as today.

Acceptance: equilibrium test (Σ reactions = Σ applied load per case,
including lateral); B1-style building sizes and carbon unchanged.

## WP 0.4b — Foundation load combinations

Signed-off defaults (user 2026-11-11):
- Bearing: ASD with qa, all ASCE 7-22 §2.4.1 and §2.4.5 combinations with
  nonzero loads. Strength: all §2.3.1 and §2.3.6 combinations with nonzero
  loads. Eh = ρQE (Eq. 12.4-3), Ev = 0.2 SDS D (Eq. 12.4-4a).
- Options, off by default: §12.13.4 overturning reduction (soil interface
  only, never for concrete strength); Ev = 0 at the soil interface
  (§12.4.2.2 Exc. 2(b)); the 0.5L factor (§2.3.1/§2.3.6 Exc. 1).
- No allowable bearing increase. No partial contact: every combination must
  keep the resultant in the kern (current behaviour grows the footing).
- Uplift under any combination is reported as a failed check.
- Footing and soil weight are part of D.
- ±X and ±Y separately; no orthogonal combination yet.
- Pattern live cases enveloped.

Do: bearing per ASD combination using that combination's own P, Mx, My
(remove the `Mux/Pu` proxy at `spread_footing.jl:684-685`); strength design
per LRFD combination from its factored eccentric pressure; record the
governing combination label. Same for strip, mat and grade-wall footings.

Acceptance: the Issue B §B.7 hand calc (wall footing, qa = 80 kPa: today
passes at 76.19 kPa; corrected code fails or enlarges because ASD combo 9
gives 98.43 kPa; LRFD combo 6 gives 139.05 kPa; combo 7 sits exactly on the
kern edge; the §12.13.4 option leaves LRFD values unchanged); wind sign
reversal swaps q_max ends.

Ask before deciding:
- Sliding: approved only as "checked when a friction coefficient is given,
  flagged otherwise". The resistance basis and safety factor are not decided;
  implement the flag path and ask before writing the check.
- Source of the soil unit weight for overburden, if the soil type has none.

## WP 0.5 — Rigid mat strip statics

Source: Issue D.

Signed off: replace the coefficient table in `_rigid_mat_strip_moments`
(SS `foundations/codes/aci/mat_footing.jl:426-469`) with rigid-body strip
statics per ACI 336.2R §6.1.2 Step 3 (PDF p. 11) for the full-width strip
the code already uses: column-line loads as known downward forces, soil
pressure upward, overhangs included. Take the signed moment diagram: bottom
tension → `As_bot`, top tension → `As_top` (column lines put the bottom in
tension, spans the top). Use the pressure distribution the rigid path already
computes; if it is uniform while the resultant is eccentric, report it.

Also: the single-column-line no-wall case must fail loudly with a clear
message (today an accidental `BoundsError`). Fix the docstrings: drop
"Kramrisch", drop the §6.1.2 citation for the width convention.

Acceptance: Issue D §D.7 hand calcs: one span (bottom 300, top 4,500
kip·ft); two spans (top 108w at 18 ft); three spans (top 175.5w at centre).
The Shukla rigid envelope picks up the new moments.

Still open, do not implement: per-line strips and the vertical-summation
correction (Bowles 1982 not in the corpus); column-band steel concentration;
cantilever statics for single-column-line mats.

## WP 0.6 + 0.7 — Carbon accounting

Source: `phase1-benchmarks.md` §3a, §4e.

Do:
1. Walls in `compute_building_ec` and `takeoff_by_element`
   (SY `postprocess/ec.jl:148-170, 288-336`): concrete volume = length ×
   height × thickness at capture time, times the column concrete factor;
   rebar from the designed ρt/ρl, times the rebar factor (user 2026-11-11).
   Add `ec_walls` to `DesignSummary`. If walls have openings data, report how
   it should be handled; do not guess.
2. Drop panels, shear caps and punching studs split out of the building
   totals (`SY design/summary.jl:64-67`) into the per-element takeoff.

Acceptance: hand-checked wall volume and rebar mass on a one-wall fixture;
on a flat-slab fixture the split items sum to today's totals exactly.

## WP 1.1 + 1.2 — Instrumentation (no number changes)

Spec: `phase1-benchmarks.md` §4a–4d, including hook tables with file:line.

Do: the Asap `AnalysisLog` (`ScopedValue`, zero cost when off, counting
rigid-diaphragm solves), building-model registration, `SizingProbe` with
stage spans, loop rounds and size drivers at every writer, SS-side writers
emitting `TraceEvent`s that SY copies.

Acceptance: on B1 (no diaphragm links) building factorizations equal
`_N_FACTORIZATIONS`; `DesignSummary` identical with and without the probe;
no function signatures change.

## WP 1.3 — Benchmark fixtures

Spec: `phase1-benchmarks.md` §2. Build B1, B1f, B2, B3, B4, B5, B7 in
`scripts/runners/sizing_baseline_fixtures.jl` (do not edit the source
tests). `solver = :highs`, `max_iterations = 20`, settings per §2. B6 waits
for the user to approve the lead agent's proposal.

Acceptance: each fixture runs twice in one process with identical sizes and
carbon; runtimes recorded in the report.

## WP 1.4 — Baseline runner

Spec: `phase1-benchmarks.md` §5. `scripts/runners/sizing_baseline.jl`
writing `<bench>.json` plus `runs.csv`, `stages.csv`, `loops.csv`,
`elements.csv`; `--register` calls `angelo ledger record`.

Acceptance: output matches the §5b schema; repeat mismatch fails the run.

## WP 1.5 — Objective metrics O2 and O4

**O2 path independence.** Each benchmark under three perturbations: slab
processing order reversed; column seed × 1.5; column seed at the catalog
minimum. If no option exposes slab order or the seed, add a test-only
keyword and report it. Report the share of elements with identical sizes and
the total-carbon difference against the unperturbed run.

**O4 oversize.** For each element, the lightest size its own final demands
allow, from the final analysis, with no seed, stacking, grouping, harmonize
or envelope floors:
- column: lightest catalog section passing all column checks at its final
  demand cases;
- slab: thinnest h passing all slab checks with columns held at final sizes;
- beam: lightest catalog section at its final demands, ungrouped;
- footing: smallest passing size at its own demand, ungrouped;
- wall: thinnest passing pier checks at final demands; mark drift-governed
  walls `global` (drift is not an element property).

Oversize = final quantity ÷ lightest quantity (volume, or mass for steel).
Add it to `elements.csv`. Do not change design behaviour.

Acceptance: O2 and O4 reported for every benchmark on the pre-Phase-2 code;
the method for each element type written in the report.
