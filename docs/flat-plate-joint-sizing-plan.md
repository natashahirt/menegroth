# Flat-plate sizing: choose slab thickness, columns, and studs together

Status: agreed design, implementation starting (2026-11-11).
Supersedes the lexicographic objective of memory plan `plan-159c1800`
(thinnest slab, then smallest columns) and the Nov 9 deferral of that plan
in `deci-44674e99`.

## Why

The v7 core office sized its floors 11.5 / 11.5 / 13.0 / 10.5 in with
corner columns 30 / 30 / 18 / 14 in. Sizes in the current loop only grow,
and the order of fixes is fixed:

1. Phase A thickens the slab for deflection, one-way shear, flexure, and
   transfer, holding columns fixed.
2. Phase B grows each failing column toward `max_column_size`, one analysis
   per growth confirmation. Only a column at the cap thickens the slab.
3. Nothing shrinks. A column grown before the slab thickened stays large.
4. Slabs are sized in slab-index order. The rule that a lower column is at
   least the column above is applied afterward by the member stage, so a
   large column chosen by a lower floor's punching is carried down, and a
   floor's slab never sees the column that will sit above it.
5. A wall reaction that fails punching thickens the slab directly
   (`iteration.jl`, wall check in Phase B). There is no other option at a
   wall.

The result depends on the path, not on which design is better.

## Decisions (user, 2026-11-11)

| Topic | Decision |
|---|---|
| Objective | Embodied carbon by default; the objective is switchable (`opts.objective`: `MinCarbon`, `MinVolume`, `MinWeight`, `MinCost`). |
| Studs | A third option alongside slab thickness and column size. Pure carbon first, to see whether studs win everywhere. |
| Stud controls | A switch to turn studs off, and a weight on the stud term of the objective for future use. |
| Selection | Lowest objective value. No complexity term yet. |
| Floor order | Top-down. Each floor is sized on its own, with the columns above as a minimum. Floors below are not part of a floor's objective. |
| Re-scan | One re-scan per floor after the building-level column check grows columns. |
| Near-ties | Within 1% of the active objective, prefer the candidate that matches the floor above. |

## Algorithm (one slab)

Notation: `h` slab thickness on the half-inch grid; `c_i` size of support
column `i`; `s_i` stud layout at column `i` (or none).

```text
Phase A (unchanged): thinnest h passing deflection, one-way shear,
    flexure and transfer, at the current columns           → h_A
c_min[i] = max(P-M size at h_A, column above, external floor)
reset columns to c_min; analyze at (h_A, c_min)            → demands D

scan: for h in h_A, h_A + 0.5", …, up to ln/10
    D_h = D scaled to h                    (scale_moment_result)
    depth checks pass at h?                (phase_a_depth_passes)   else next h
    walls pass punching at h?              (wall_reaction_punching) else next h
    for each column i:
        options = { smallest size ≥ c_min[i] passing bare punching at h,
                    smallest size ≥ c_min[i] passing with studs at h (if allowed) }
        pick the option with the lowest objective term
        none within max_column_size → h infeasible, next h
    J(h) = slab(h) + Σ_i column_i + w_stud · Σ_i studs_i
    stop once slab(h) alone exceeds the best J so far
choose (h*, c*, s*) with the lowest J  (1% tie rule)
verify: Phase A and Phase B at (h*, c*) with a real analysis
    pass  → Phase C (unchanged)
    fail  → rescan from the new analysis; columns may not drop below the
            sizes that just failed (keeps the loop finite)
```

Why the scan is cheap: deflection, one-way shear, and flexure only get
easier with `h`, so they set a floor. At a fixed `h`, punching gets easier
with column size, so the smallest passing column at each support never
increases with `h`. Each candidate costs closed-form checks on demands
scaled from one analysis (`thickness_jump.jl`), not a new analysis.

Accuracy risk: scaling holds the moment distribution fixed, but a larger
column draws more unbalanced moment. The verification analysis catches
that. If corners fail verification often, add a scan margin (for example
0.95) on punching only; the final checks stay at full code limits.

## Objective terms (carbon)

All terms use the material's `ecc` and density, matching
`slabs/optimize/flat_plate/objective.jl`.

- Slab concrete: `h × slab area`.
- Slab rebar: `design_strip_reinforcement` on the scaled moments at `h`.
  Thicker slabs need less flexural steel but more minimum steel, so this
  term is required. It is a ranking estimate; the built design's rebar
  comes from Phase C.
- Column: this story's segment only, concrete plus longitudinal steel at
  the candidate size.
- Studs: rail and stud steel from the `design_shear_studs` layout, times
  `stud_weight`.

## Options (`FlatPlateOptions`)

- `punching_strategy = :joint_search` selects this algorithm. The existing
  strategies stay unchanged. The default flips only after the core office
  comparison.
- `objective`: reused as the switch. Its default becomes `MinCarbon()`;
  this also changes the default of `size_flat_plate_optimized`, so its
  tests are rerun with the change.
- `joint_studs::Bool = true`: whether the search may place studs.
- `stud_weight::Float64 = 1.0`: multiplier on the stud term.

## Building level

- Slab nodes run top-down by story elevation when the strategy is
  `:joint_search`. Floors on different stories share no columns, so the
  only coupling is the column-above minimum.
- The column-above minimum and any size forced by the member stage are a
  per-column floor the slab may not go below. That floor must be stored
  separately from the installed size, because the search is allowed to
  shrink a column below its previous installed size.
- The member stage already redesigns slabs whose checks used smaller
  columns (`_design_flat_plate_members!`). With the floor above, that
  redesign is the agreed re-scan.
- Floors whose slabs share a column (two-level propose/commit,
  `deci-d259f689`): propose runs the search; commit holds the adopted
  columns fixed and searches only thickness and studs.

## Not covered yet

- **Studs at walls.** `design_shear_studs` lays out rails from column faces
  with a column-shaped outer section (ACI 318-11 §11.11.5). Wall reactions
  use wall-end, wall-interior, corner, and closed-loop sections, and no stud
  layout exists for them. Using §11.11.5 at a wall reaction is a code
  interpretation that needs sign-off. Until then, a wall that fails
  punching is handled by thickness only.
- Drop panels and pattern loading: the scale does not apply
  (`thickness_scale_applies`), so these keep the current loop.
- A construction-complexity objective (count of supports with studs).

## Verification

1. Unit tests: monotone staircase on a fixed-demand fixture; the stud
   switch and weight change the choice as expected; the objective switch
   is honored; verification failure rescans and terminates.
2. Regression: existing flat-plate pipeline tests with the default strategy
   are unchanged.
3. Core office: rerun with `:joint_search`, compare per-floor thickness,
   column sizes, studs, carbon, analysis count, and wall time against v7.
