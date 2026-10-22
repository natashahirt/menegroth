---
id: plan-a2a6128f
type: plan
project: menegroth
parent_id: plan-w0000001
title: 'Plan: complete concrete wall system (unified frame-shell, ASCE 7-22, performance-aware)'
node_label: Complete wall system plan
tags: walls,lateral,aci-318-19,asce-7-22,unified-model,performance,incremental,warm-state,plan
status: active
open_threads: 15
success: 'null'
files: ''
session_id: sess-8c9dc5f7
created_at: '2026-10-21T02:02:50.951529+00:00'
updated_at: '2026-10-22T13:28:09.638898+00:00'
has_child_rationale: Forward-looking implementation plan for finishing the wall/LFRS
  workstream begun in plan-w0000001.
---
# Complete Concrete Wall System — implementation plan

Plan file: `.cursor/plans/complete-wall-system_76ac3f3b.plan.md`.

## Goal
Take one building description and produce a traceable, code-grounded design for gravity framing + wind/seismic lateral + walls (force distribution, drift, torsion, shear, P–M, bearing, out-of-plane), later extended to openings, special seismic walls (§18.10), and optimized layouts. Endpoint standard: **ACI 318-19 + ASCE 7-22**. Scope chosen by user: full phased roadmap **plus** an up-front audit/hardening pass.

Guiding principle: **one physical building model, modular demand generation, independently testable checks.** "Unified" describes the structural model, not a monolithic codebase.

## Current baseline (verified)
- S1–S4 wall library in `StructuralSizer/src/walls/` is implemented and oracle-validated: shear §11.5.4, P–M §22.2, bearing §11.5.3, out-of-plane §11.8, reduced diaphragm evaluator, Asap FEM evaluator, SIMP layout NLP. Last recorded wall suite 161/161.
- Grounding: ACI 318-19 (normative) + StructurePoint spWall examples + McCormac Ex. 18.1 (bearing oracle) as numerical oracles. ASCE 7-22 and ACI 318-19 are both in the corpus.
- NOT done: walls are not on `BuildingStructure`/`design_building`/unified Asap model; no ASCE 7-22 demand generation; openings and §18.10 unimplemented; several VERIFY/engineering-judgment markers; shear checker hardcodes Grade-60 transverse steel; reduced-model drift != FEM interstory drift (multistory risk); sensitivity inconsistent with accidental eccentricity; singular K uses pinv fallback.

## Phases
1. Audit + fail-safe the existing wall library (fy wiring, multistory drift, accidental-ecc sensitivity, fail-closed singular K, FEM/reduced semantics, stale-comment + VERIFY inventory).
2. Corpus promotion gates: extract/promote ACI Ch.11, §18.10, Ch.21–22 and required ASCE 7-22 provisions with source_id + clause + page; no phase advances on VERIFY mechanics.
3. Wall data model: add walls + wall results to `structure.jl`/`design_types.jl`; `:walls` edges → stacked `Wall` via `analyze/members/utils.jl`; demand/result sidecars keyed by wall/story/direction/combination.
4. Performance architecture (designed BEFORE the unified model) — see below.
5. Unified Asap frame-shell model: refactor wall-panel/diaphragm assembly from `fem_evaluator.jl` into `analyze/asap/utils.jl` `to_asap!`; one model for gravity+lateral; separate topology construction from numeric updates and load solves; validate against the isolated FEM evaluator before retiring duplication.
6. ASCE 7-22 lateral demand: wind + ELF seismic under `StructuralSizer/src/loads/` and a new `StructuralSynthesizer/src/analyze/lateral/`; directional story loads + strength/service combos + accidental torsion + drift; fail explicit on missing site/seismic inputs; published known-answer tests before wiring to checks.
7. Integrate ordinary-wall sizing end-to-end into `design_workflow.jl` + design graph/provenance; capture clause-specific CheckResults, governing combos, demands, capacities, drift, model provenance; API + trace; full `:walls`-to-serialized-results fixture.
8. Walls with openings: pier/spandrel segmentation (`segmentation.jl` + coupling beams), opening-aware meshing, oracles sp-de-multi-story-openings-aci19 / sp-de-tilt-up-wall-with-opening-aci19.
9. Special structural walls §18.10 (`special.jl`): special shear caps, displacement + stress boundary-element triggers, extent/confinement/detailing; ordinary behavior unchanged; reject when seismic inputs absent.
10. Layout optimization + mandatory unified-FEM survivor verification; candidate generation from real geometry; reduced evaluator in the loop, unified model as final authority.
11. Production verification + reporting + docs; cold-vs-warm equivalence + performance benchmarks.

## Performance architecture (user-requested, designed up front)
Reuse the existing exact-first incremental engine (Design Graph, snapshot/restore, loads-only Asap factorization reuse, MIP warm-start, warm-vs-cold bit-identity gate from `plan-1004cfac` / `scripts/runners/verify_warm_state_incremental.jl`). Four invalidation classes:
- **Checks only** — demand + stiffness unchanged → rerun ACI checks, no FEM solve.
- **Loads only** — topology + stiffness unchanged → reuse assembled K + factorization, batch new RHS solves.
- **Stiffness only** — topology + DOF map unchanged → reuse mesh/sparsity/symbolic/load-routing/recovery maps; update numeric values + refactorize.
- **Topology** — wall/opening/mesh/diaphragm/connectivity change → rebuild.
Separately fingerprint topology, DOF map, scatter maps, load vectors, solved states, recovery maps; invalidate each only from the inputs it reads. Batch independent linear cases as multiple RHS against one factorization; combos from solved basis cases where superposition holds; P-Δ/nonlinear stay explicit. Two-level loop: reduced evaluator proposes grouped size/layout changes; unified model called at controlled correction/verification points; final design must pass the unified model + full ACI. Thrash guards: bounded simultaneous updates, convergence on sections AND redistributed demands, oscillation detection, cold-rebuild fallback, provenance for every solve. Parallelize only independent work (ASCE case gen, per-member checks, recovery); keep model mutation + factorization ownership deterministic. Default optimizations must be **bit-identical to cold**; approximate/low-rank/relaxed paths are opt-in and separately validated.

## Validation ladder
L1 pure mechanics (non-default steel, code limits, singular systems, units/signs, clause boundaries); L2 published examples (ACI 318-19 normative, ASCE 7-22 loading, spWall + McCormac + opening/tilt-up oracles); L3 component analysis benchmarks (cantilever, symmetric core, wall+frame, rigid vs semi-rigid diaphragm, skew, multistory recovery, equilibrium); L4 isolated-FEM vs unified equivalence before retiring duplication; L5 end-to-end synthetic buildings, with the gravity-only path still working when no lateral design is requested.

## Key open decisions already made
- Analysis architecture: **unified** single Asap frame-shell model for gravity + lateral (user choice).
- Performance is a first-class design constraint, not a later pass (user request).
