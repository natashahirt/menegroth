---
id: deci-209e1f2f
type: decision
project: menegroth
parent_id: plan-dc397b09
title: 'General corner critical section via half-plane clipping: handles any free-edge
  angle, fixes re-entrant b0 over-count, conservative transfer sign'
node_label: General corner critical section via half-plane cli
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/codes/aci/punching.jl@7c67346, StructuralSizer/src/slabs/codes/concrete/flat_plate/design/checks.jl@7c67346,
  StructuralSizer/test/slabs/test_general_critical_section.jl@7c67346, scripts/runners/check_corner_clip.jl@7c67346
session_id: sess-817fac76
created_at: '2026-10-23T01:41:58.218156+00:00'
updated_at: '2026-10-23T01:41:58.218156+00:00'
---
Delivered the angled-notch/wedge feature (route non-orthogonal corners through the App. B engine) with `corner_critical_section(c1,c2,d,kind,inward_normals; θ)` in punching.jl.

GEOMETRY: offset the column rectangle by d/2, then clip the perimeter to the slab region defined by the two free-edge half-planes. keep(p) = ALL inward constraints (convex wedge) or ANY (re-entrant = complement of notch). Free-edge lines pass through the column's void-side corner along the edge directions. Returns an OPEN polyline (closed=false) of the resisting perimeter; collinear/duplicate points stripped. Validated exact reductions: convex orthogonal → b0=(c1+d/2)+(c2+d/2) matching rectangular(:corner); re-entrant orthogonal → b0=2(c1+c2)+3d; 60° wedge → rotated principal axis.

BUG FIX (unconservative): the old closed 6-vertex `reentrant_critical_section` counted the two d/2 notch edges as resisting perimeter (b0 = full 2(c1+d)+2(c2+d)). Those edges lie along the free edges and carry no shear — the section is OPEN there. Correct b0 = 2(c1+c2)+3d, i.e. d less (~7% smaller → ~7% higher stress). `reentrant_critical_section` is now a thin wrapper over the clipper (single source of truth).

ROUTING (checks.jl check_punching_for_column): ALL re-entrant corners (any angle) and NON-orthogonal convex corners route through the clipper when `col.boundary_inward_normals` (len 2) is present; else conservative closed-form fallback. Orthogonal convex keeps the spSlab-validated closed-form path. Dropped the old `isapprox(angle,3π/2)` orthogonality guard — skewed re-entrant now routes with real geometry instead of the 2-sided fallback.

TRANSFER SIGN (safety): net centroid moment is |M ± Vu·e| with ambiguous sign for general sections. Switched to the strictly conservative UPPER BOUND |M|+Vu·|e| for BOTH kinds (was |M|−Vu·e reduction for re-entrant). Open re-entrant section pushed the ± swing to 10.3% (just over the old 10% 'minor' claim); conservative bound removes the guess. Penalty over unsigned value <6%.

TESTS: test_general_critical_section.jl now 72/72 (added clipper-reduction lock, skewed re-entrant + 60° wedge routing, conservative-transfer bracket). Corner-punching + flat-plate suites 172 pass / 1 pre-existing broken — no regressions.
