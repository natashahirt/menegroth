---
id: plan-a79eb74f
type: plan
project: menegroth
parent_id: plan-a0000001
title: 'Whole-building sizing architecture: requirements, owners, round controller,
  verified and path-independent'
node_label: Sizing architecture
tags: sizing,architecture,optimization,carbon,path-independence,verification,walls,columns,slabs,foundations,plan
status: active
open_threads: 4
success: 'null'
files: docs/sizing-map/architecture.md@b4ef79f, docs/sizing-map/plan.md@b4ef79f, docs/sizing-map/README.md@b4ef79f,
  docs/sizing-map/phase1-benchmarks.md@b4ef79f, docs/sizing-map/raw/vertical-floor-interaction.md@b4ef79f
session_id: sess-4672ff25
created_at: '2026-11-11T21:55:19.569839+00:00'
updated_at: '2026-11-13T15:56:46.337478+00:00'
has_child_rationale: Global sizing redesign spanning slabs, members, walls and foundations
related_to: plan-2d4158d0,plan-66282b2f,deci-h0000010
---
Goal: the lightest code-compliant structure from fast, path-independent, verified sizing, so an outer loop can compare layouts and systems.

Approach (docs/sizing-map/architecture.md): sequential approximate optimisation. Each round: one building analysis, per-element demand models, owners and coupled clusters pick the lightest feasible values under move limits, hybrid cycle rule; final verification by an independent verifier (full analysis + all checks).

Components: design-state registry (beside BuildingStructure, single apply! writer), analysis service, demand models, pure checks, owners, clusters (slab+columns+studs; walls for drift; beams+two-way; footing BxH), one carbon objective, named policies, round controller, verifier, per-round audit record.

Roadmap (docs/sizing-map/plan.md): Phase 0 safety and carbon accounting; Phase 1 baseline and instrumentation; Phase 2 registry + round controller (no behaviour change); Phase 3 columns as first owner; Phase 4 concurrent demand sets; Phase 5 walls and vertical-floor coupling; Phase 6 stand-ins, slabs, beams, foundations, policies; Phase 7 speed (parallel).

Objectives O1-O7: safe (100% verification); path-independent (>=95% identical sizes, carbon within 1% under three perturbations); no seed/stacking/slab_old drivers after Phase 3; oversize vs lightest own-demand size reduced; no phase adds >10% analyses/runtime without sign-off; auditable; carbon covers all materials.

User decisions 2026-11-11: embodied carbon objective (switchable); hybrid convergence; stacking dropped as a sizing rule; registry beside BuildingStructure; demand models vs re-analysis measured per element type; O2 thresholds and O4 metric approved; inner/outer level split is the motivation; modularity for audit is a goal.
