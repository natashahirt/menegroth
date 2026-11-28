# Symmetry-aware sizing: a propose-verify policy

Status: draft for discussion (2026-11-24). Companion to
[`architecture.md`](architecture.md) (owners / verifier / policies) and
[`README.md`](README.md) (current state). This document scopes a **symmetry /
congruence policy**: detect elements whose *sizing problem* is identical up to a
symmetry, size one representative per class, broadcast its section to the class,
then verify every element independently against its own demand.

It is **scoping only** — no implementation has started.

## 1. Motivation

Two problems, one mechanism.

- **Correctness (path-independence).** `architecture.md` §1 requires the result
  to be *path-independent*: it must not depend on processing order or seed. The
  `star/e0c0` waffle violates this — four geometrically equivalent hub girders
  receive a chiral section split (`NE=SW=T18x36-bf42` vs `NW=SE=T20x30-bf20`) on
  a non-chiral plan. Root cause (fully diagnosed, memory `find-ae3ab0d2`): the
  plan geometry is mirror-exact and the FEA/demand path is reflection-covariant
  to the bit, but a **deterministic sub-permille (~0.01–0.05%) asymmetry** in the
  slab mesh / tributary discretization seeds a tiny demand difference, which a
  **catalog capacity threshold** at the first sizing amplifies (a permille of
  load flips `bf36` vs `bf12`), and the section→stiffness→demand feedback blows
  up to the converged ~35% split. It is neither a tie-break nor an analysis bug;
  it is a real-but-tiny asymmetry that is threshold-amplified.

- **Speed.** Symmetric plans size the same problem many times. A plan with `D2`
  symmetry has orbits of up to 4 equivalent members; a regular grid has one
  distinct interior bay repeated many times. Sizing each orbit once is a direct
  saving in the member MIPs and per-group demand reduction (the full analysis is
  unchanged), and it shrinks the design space, which can reduce feedback
  oscillation (and may help the `special/rhombus_8x12` pinned-check stall).

The same construct fixes both: **size by equivalence class, verify per element.**

## 2. The key idea: an untrusted accelerator behind the trusted verifier

`architecture.md` §7 states the trust model plainly:

> *"The verifier is the trust anchor, and it stays simple… The optimiser may be
> clever; the verifier may not."*

Symmetry grouping is therefore a **named, switchable Policy** (`architecture.md`
§3) — a non-code rule, not a code constraint — and the per-element check is the
**Verifier**. The loop:

```text
propose  classes: partition elements into equivalence classes (orbits)
envelope demand:  class demand = elementwise max over the class's members
size once:        size one representative per class on the class envelope
broadcast:        write the representative's section to every class member
verify each:      run the existing pure checks on EVERY element at ITS OWN
                  final demand (not the envelope)
split on fail:    any element that fails leaves its class and is sized alone;
                  repeat until all pass
```

Because the final gate is always the real per-element check at that element's own
demand, **a wrong equivalence guess can never produce an unsafe design.** The
worst case is a slightly conservative section (the envelope) or a little rework
(a split). This demotes the symmetry detector from a component that must be
*correct* to one that need only be a good *proposer* — so we can be aggressive.

This is exactly `architecture.md` §1 property (2), *path-independence*: members
that are equivalent by construction get identical sizes regardless of seed,
processing order, or sub-permille mesh noise.

## 3. Equivalence: define it on the sizing problem, not on geometry

The crucial subtlety: **geometric symmetry of the plan does not imply equal
demands.** Gravity on a symmetric plan is symmetric, but

- **pattern live load** (ACI 318-11 §6.4 / §13.7.6) is applied per span and is
  not symmetry-invariant;
- **lateral load** (wind / seismic) has a direction and breaks reflection
  symmetry;
- **span / rib direction** is a designed attribute: a one-way slab or a waffle
  rib field can have *lower* symmetry than its polygon;
- facade / perimeter loads, holes, supports, and column placement must all be
  invariant too.

So two elements are equivalent only when their *whole design problem* matches:
demand envelope, span, unbraced length `Lb`, `Cb`, boundary conditions, catalog,
and any per-group override — within tolerance. Geometry is one cheap way to
*propose* that two problems match; it is never the proof.

### Two complementary proposers

The proposer is pluggable; correctness lives in the verifier either way.

1. **Automorphism proposer** — the plan's finite isometry group (see §4). It is
   *elegant and explanatory*: "these four girders are one orbit of the plan's
   `D2` symmetry." Good for auditability (`architecture.md` §7) and for
   proposing classes *before* demands are computed.
2. **Sizing-fingerprint proposer** — group elements whose design problem
   (demand envelope + span + BC + catalog, within tolerance) is identical, with
   no geometry at all. This is *correctness-complete by construction* (identical
   problems ⇒ identical answer) and catches repeated grid bays that are not a
   global automorphism.

Recommended use: automorphism to *propose and explain* cheaply; fingerprint to
*confirm* a class before sizing it once.

## 4. The plan automorphism detector

Finding the symmetry group of a finite labeled planar point set is a standard,
tractable problem.

- Every isometry fixing the set fixes the centroid, so it is a rotation about the
  centroid or a reflection through it.
- **Candidates:** rotation angles from the centroid to each vertex (and pairwise
  angle differences); reflection axes through the centroid aligned to each vertex
  or bisector. `O(n²)` candidates.
- **Verify** each candidate by checking the permuted vertex set equals the
  original within a position tolerance (hashed / KD-tree point lookup). `O(n log
  n)` each. For `n ≈ 25–200` vertices this is milliseconds.
- **Result:** the exact finite group — `C1, C2, C4, D1, D2, D4, …`.

This naturally captures symmetry that is *not axial*:

- `e0c0`'s true invariant is the **`C2` rotation about the hub** (180°) — which
  is precisely why `{NE,SW}` and `{NW,SE}` pair as diagonals. (`e0c0` has the
  full `D2 = {e, rot180, mirror_x, mirror_y}`.)
- **`Cn` pinwheels** (rotation, no reflection axis).
- With a translational extension: **repeated grid bays** (local congruence),
  where the biggest speed win lives.

### From group to orbits

Union-find over elements under the group generators yields orbits in near-linear
time; the representative is the canonical (lowest-index) element per orbit — a
reflection-invariant choice.

### Design-semantic intersection (the real work)

The geometric group must be intersected with the stabilizer of every
sizing-relevant attribute (columns, walls, holes, perimeter, framing level, span
/ rib direction, releases, supports) and restricted to symmetry-invariant load
cases. Missing an attribute yields a false equivalence — which the per-element
verifier (§2) catches, so the risk is conservatism / rework, never an unsafe
design.

## 5. Scope

General across element types — the orbit / class machinery is element-agnostic
(vertices, edges, faces).

- **In (design the relation for all three):** beams/ribs, columns, slabs. The
  equivalence relation and the propose-verify loop are defined once and applied
  to each element family.
- **Correctness first, speed second:** the envelope + per-element verify makes
  the policy safe; the speed win is the measured by-product.
- **Out (initially):** using asymmetric lateral cases as a symmetry basis;
  approximate / near-symmetry as a trusted signal (allowed only as a proposer,
  always confirmed by fingerprint + verify); turning the policy on by default
  before the benchmarks prove no loss of verification.

## 6. Interactions to get right

- **Existing grouping.** Today `member_groups` are keyed by framing role
  (`group_id`). The symmetry policy either merges orbit members into one group or
  layers a class above groups; it must compose with `build_member_groups!` and
  `member_group_demands`.
- **Collinear rib sharing** (`collinear_ribs.jl`) already enforces the `C2`
  diagonal pairing via an order-independent `maximum`; the class envelope must be
  consistent with it (memory `find-7f0166a7`).
- **Solid heads, frame floors, releases** — class members must share these or the
  class is invalid.
- **Determinism.** Canonical representative and envelope reduction must be
  order-independent (reflection-invariant), matching the fixes already landed in
  `check_settle.jl` and `optimize_discrete` (the extraction tie-break).

## 7. Validation

### 7.0 Automorphism-proposer corpus scan (done)

`scripts/runners/plan_symmetry_scan.jl` prototypes the geometric proposer
read-only (no analysis, no sizing): for every SDF plan it computes the finite
isometry automorphism group of the labeled framing graph (vertices + beam lines
+ column nodes) and the resulting beam-line orbits. Full corpus (164 plans,
`grid`/`nova`/`special`/`star`/`topology`), runs in seconds including the
985-node / 2136-line `s6-6_drawn`:

| set       | plans | with symmetry | groups                | mean collapse |
|-----------|-------|---------------|-----------------------|---------------|
| grid      | 36    | 36            | D2:36                 | 3.45×         |
| nova      | 36    | 36            | D2:36                 | 3.90×         |
| special   | 19    | 12            | D2:12, C1:7           | 2.61×         |
| star      | 37    | 37            | D2:37                 | 3.65×         |
| topology  | 36    | 36            | D2:34, D1:2           | 3.47×         |
| **total** | 164   | **157 (96%)** | —                     | **~3.5×**     |

Findings:

- **96% of plans carry exploitable symmetry**, with a ~3.5× mean reduction in
  distinct beam-sizing problems (orbits vs lines) — this is the speed-win proxy.
- **Max group is D2** (order 4: two mirrors + rot180). No `C4`/`D4` appears
  because the footprints are rectangular (non-square), so 90° rotation is not a
  symmetry. The `C2`/`C4` non-axial cases in `architecture.md` §7 are latent, not
  present in this corpus.
- **`star/e0c0` resolves to D2** including its column set — confirming the
  observed converged chirality is a genuine symmetry *break* (path-dependence),
  not an inherent geometric asymmetry. This is the premise the whole policy rests
  on.
- **The 7 asymmetric (`C1`) plans are all the named real-world layouts**
  (`school`, `weber_1*`, `tan_121_seaport`, `topopt_test2`); the proposer
  correctly finds no symmetry and the policy must fall back to per-member sizing
  there (the no-op guarantee).
- **`topology/r8c1`, `r8c3` are only `D1`** (a single mirror, collapse ~1.9×) —
  useful weird cases that exercise partial symmetry.

Implementation notes for the production detector (ported from the prototype):
seed candidate isometries from the farthest-vertex orbit (O(n) rotations +
reflections), verify each by vertex bijection **and** label (line + column)
preservation, and **normalize signed zero in the match key** — Julia's `Dict`
treats `-0.0` and `0.0` as distinct (`isequal(-0.0, 0.0) === false`), so a mirror
that lands a centerline vertex on `-0.0` silently fails the lookup (this bug hid
every real symmetry until fixed).

### 7.1 Remaining validation

- **Path-independence / symmetry:** symmetric plans produce orbit-identical
  sections; `star/e0c0` chirality is gone; `grid` and `rhombus` unchanged or
  improved.
- **Conservatism (safety):** every element passes its own check at its own final
  demand after broadcast — no element under-sized by the envelope.
- **Speed:** sizing wall-clock and analysis count with / without the policy on
  `star/e0c0`, `grid/x1y1`, `special/rhombus_8x12`.
- **No-op guarantee:** plans with no symmetry (or policy off) are byte-identical
  to today.
- **Regression:** full `StructuralSynthesizer` suite.

## 8. Phasing (proposed)

1. **Relation + verifier loop (beams first).** Fingerprint proposer, class
   envelope, broadcast, per-element verify, split-on-fail. Prove path-
   independence on `e0c0` and the no-op guarantee on asymmetric plans.
2. **Automorphism detector.** Add the geometric group + orbits as the explanatory
   proposer; cross-check its orbits against the fingerprint classes.
3. **Generalize to columns and slabs.** Reuse the relation and loop.
4. **Translational / local congruence.** Repeated-bay detection for the grid
   speed win.
5. **Default-on decision.** Only after the benchmarks show no loss of
   verification and a measured speed / path-independence gain.

## 9. Open questions

- Merge orbit members into one `member_group`, or keep a separate class layer
  above groups?
- Class demand = strict elementwise `max` envelope, or concurrent-case-aware
  (`architecture.md` §4 "concurrent demand sets, not envelopes")? Envelope is
  safe and simple; concurrent is tighter but couples to the demand-set work.
- Automorphism tolerance (exact vs near-symmetry) and how aggressively to propose
  before the fingerprint confirmation.
- Interaction with the two-tier fast / full fidelity ladder (`architecture.md`
  §5): is symmetry a fast-tier accelerator, a full-tier policy, or both?
