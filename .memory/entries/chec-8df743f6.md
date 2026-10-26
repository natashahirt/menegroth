---
id: chec-8df743f6
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: Chapter 27 wind story forces, with sloped roofs refused
node_label: Chapter 27 wind story forces, with sloped roofs re
tags: wind,chapter-27,asce-7-22,cfd-stub
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-158720dd
created_at: '2026-10-26T15:26:48.145278+00:00'
updated_at: '2026-10-26T15:26:48.145278+00:00'
---
Chapter 27 directional MWFRS wind story forces are in place for a caller-supplied plan direction. Each story uses its own floor outline. Wall Cp, Eq. 27.3-1, Figure 27.3-8 Cases 1-4, and the §27.1.5 minimum are encoded. qz, qh, Kd, G, and (GCpi) stay caller inputs. A flat roof is accepted. A gable, hip, monoslope, or mansard roof throws before any case is built, because Figure 27.3-1 roof Cp is not implemented and §27.3.1 requires wall and roof pressures together.

Tests: StructuralSizer loads/test_wind_chapter27.jl (97, then the pressure-per-edge slot) and StructuralSynthesizer analyze/test_wind_story_cases.jl (54 after the roof refusal).

Critic P0 was the sloped-roof acceptance. Recheck was CONCERN only: the new wind files are untracked, so a commit must name them. Reported and not fixed: one roof projection reused for both directions; duplicate principal directions; centroid-only same-floor check.

wind_facade_edges and wind_forces_from_pressures are the stub for a later CFD pressure. Chapter 27 still fills the edge pressures. The cosine of the wind on each outward normal is stored and is not a code coefficient.

Next: drift limit and the §2.3.1 strength combinations on the seismic and wind story results, then Phase 7. The story-outline commit is still uncommitted and should stay separate from this wind commit.
