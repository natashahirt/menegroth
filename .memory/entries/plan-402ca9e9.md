---
id: plan-402ca9e9
type: plan
project: menegroth
parent_id: plan-0deab668
title: 'Big review prep packet: boundary contracts + sizing-loop efficiency, with
  starting sequence'
node_label: review prep packet
tags: architecture,performance,review,boundaries,speed,sizing,packet
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-22b68ccd
created_at: '2026-11-19T21:27:10.878661+00:00'
updated_at: '2026-11-19T21:27:10.878661+00:00'
---
Wrote docs/architecture-review/prep.md as the starting point for the big review. Ties the two coupled workstreams together:

1. Package-boundary contracts & lifecycle ownership (plan-0deab668, 7 waves; doctrine note-61fb1dd6; rule .cursor/rules/architecture-contracts.mdc + docs/src/reference/architecture_contracts.md).
2. Sizing-loop efficiency (docs/sizing-map/audit-2026-11-18/speed.md: measured costs + 17 ranked opportunities; approved directions deci-623746f4 = plan.md Phase 7.7-7.13).

Coupling: most speed wins must land in the right seam (analysis in Asap, sizing in StructuralSizer, orchestration in StructuralSynthesizer), so the two gate each other.

Packet contents: dependency invariant; the 7 waves; god-file table (size_beams.jl 2192, geometry_context.jl 1846, load_routing.jl 1842, special_boundary.jl 1430, eq137_support_sides.jl 1408, punching.jl 1395, ordinary_wall_stage.jl 1389, demands.jl 1341, ...); headline costs (FEA run ~780-950s ~90% Asap; remesh 27-36s vs update 4-6s; remesh doubled a run; Ipopt 1249->8s); top opportunities #1 fixed mesh, #2 Woodbury, #3 predict-confirm punching, #4 content-addressed cache, #11 land Ipopt cache; cross-cutting state (row-f-nlp parked at b7e2af13 blocking speed 7.7; pre-existing flat-plate failures from 764c0ae1; cladding slab-edge path deci-3d324e9c unimplemented; live rib session in main checkout); and a 4-step review sequence.

Open first action for the review: confirm which of the 7 boundary waves have actually landed (plan-0deab668 has open_threads:0 and no child progress entries). Also run speed.md measurement #1 (stage-split the 699s core-office pipeline).

File not git-pinned: the main checkout holds the live rib session's uncommitted work, so the doc was left untracked to avoid an auto-commit onto that branch. Pin it when the tree is clean.
