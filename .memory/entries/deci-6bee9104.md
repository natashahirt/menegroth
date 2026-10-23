---
id: deci-6bee9104
type: decision
project: menegroth
parent_id: plan-dc397b09
title: 'Re-entrant corner punching: accurate axis-mapping + centroid-transfer convention
  wired into check_punching_for_column'
node_label: Accurate re-entrant wiring convention
tags: punching, reentrant, aci-421.1r-99, convention, moment-transfer, safety-critical
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/design/checks.jl@dc50857,
  StructuralSizer/test/slabs/test_general_critical_section.jl@dc50857
session_id: sess-e035b394
created_at: '2026-10-23T00:24:10.148244+00:00'
updated_at: '2026-10-23T00:24:10.148244+00:00'
---
User chose **accurate mapping** (over conservative envelope) for routing re-entrant corner columns through the general App. B engine.

## Resolved conventions (both pinned by code inspection, not guessed)

**Axis mapping (Sizer corner branch ↔ 421.1R general engine):**
- `punching_stress_general` `Mux` = moment about x → stress varies in **y** (at θp=0: γv1·Mux·y/J1). `Muy` → stress in **x**.
- Sizer `check_punching_for_column` corner branch: `Mub` pairs with `cAB_x` → stress in **x**; `Muy_val` pairs with `cAB_y` → stress in **y**.
- ⇒ Determined mapping: **Mux_general = Muy_val**, **Muy_general = Mub**.

**Centroid transfer:** mirror the validated §11.11.7.2 reduction (deci-8ec247a3): `M_about_centroid = |M| − Vu·e`, floored at 0, with `e` = the TRUE general section-centroid offset (`props.xc`/`props.yc`) which already embeds the d/2 geometry. Mux_g pairs with |yc|, Muy_g with |xc|.

**Orientation invariance:** because both moments are magnitude-based (abs) and `punching_stress_general` maxes |term| over all vertices, the result is invariant to which quadrant the notch occupies — so the polygon is built in the canonical notch=(1,1) quadrant and no boundary-dir derivation is needed.

**Capacity:** β from column aspect ratio; **αs = 40 (interior)** because the re-entrant section is 4-sided (full perimeter) per ACI 421.3R-15 §4.8 side-count. (αs rarely governs — eq 11-33 = 4√f'c usually controls at large b0.)

## Gating / safety
Only columns explicitly classified `corner_kind == :reentrant` take this path; convex corners and any col lacking the field keep the conservative 2-sided check (verified: corner_punching 61/62, the 1 is a pre-existing @test_broken). The result asymmetric flag still surfaces for review.

## Residual caveat
The `|M| − Vu·e` subtract direction is inherited from the orthogonal-corner validation; for re-entrant sections the centroid offset is small (near-4-sided → centroid near column center), so this term is minor. A one-off shell-FEA cross-check on a canonical L-plan corner is still the right next validation before leaning on the reduced conservatism in production design.

Tests: general-critical-section 46/46 (incl. new routing test showing re-entrant b0=2(c1+d)+2(c2+d) and vu < 2-sided), classifier 8/8.
