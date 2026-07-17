---
id: todo-2f10ae03
type: todo
project: menegroth
parent_id: deci-080a7905
title: 'FOLLOW-UP p11-followup-orthogonal-l2-axis: default level-N joist axis rotation'
node_label: 'FOLLOW-UP p11-followup-orthogonal-l2-axis: default'
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/run_phase11_integration_fixtures.jl@c9e39c2, StructuralSynthesizer/src/analyze/framing/populate.jl@c9e39c2
session_id: sess-4924e010
created_at: '2026-07-17T17:39:20.197759+00:00'
updated_at: '2026-07-17T17:39:20.197759+00:00'
---
Phase 11 Fixture B and Fixture C leave `_derive_schema_level` at its default `joist_axis = ⟂ slab.spans.axis` for BOTH L1 and L2, so ribs at both levels run parallel across each slab and cannot exercise the Phase 10 L1↔L2 crossing contract on the medium-office fixture. Not a correctness bug (populate_levels! + cascade behave correctly for parallel ribs), but the fixture assertions had to be relaxed accordingly.

After the sparse-joists fix (2026-07-16), joist COUNTS on 3×3 are now dense (36 L1 + 36 L2 for Fixture B), but each joist still has `length(segment_indices(b)) == 1` because L2 is parallel to L1.

Options:
  1. Set `opts.level_2.axis = slab.spans.axis` explicitly per fixture (brittle — caller has to know spans direction).
  2. Change `_derive_schema_level` so level N ≥ 2 defaults to axis rotated 90° from level (N-1) — e.g. L1 = ⟂ spans, L2 = spans, L3 = ⟂ spans, ... This gives an orthogonal Nervi rib grid by default.
  3. Add a keyword `axis_rotation` on `level_N` opts that indexes into `{parallel, perp}` relative to level 1.

Recommendation: option 2 for the schema convention. Then Phase 11 Fixture B/C can re-tighten the `length(segment_indices(b)) > 1` assertion, and the L1↔L2 crossing topology is validated on the design-pipeline (multi-bay) path in addition to the single-bay Phase 10 smoke.
