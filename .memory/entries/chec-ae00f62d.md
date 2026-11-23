---
id: chec-ae00f62d
type: checkpoint
project: menegroth
parent_id: note-1b5b72d8
title: 'Steel LFRS program status: WS1 sway checker-side landed (shared RC/steel amplifier),
  pipeline hand-off + WS2 selection in progress'
node_label: 'Steel LFRS program status: WS1 sway checker-side l'
tags: steel,lfrs,sway,B2,design_column_moments,dual-system,phase-h,aisc-360,drift
status: active
open_threads: 0
success: 'true'
files: StructuralSizer/src/members/codes/aisc/checker/steel_feasibility.jl@80f0ed4,
  StructuralSizer/src/members/codes/shared/column_moments.jl@80f0ed4
session_id: sess-3c437bea
created_at: '2026-11-23T17:29:03.870194+00:00'
updated_at: '2026-11-23T17:29:03.870194+00:00'
has_child_rationale: User is building the LFRS designer with another agent; records
  the current workstream split and what the checker now does (code-confirmed in tree)
---
Active LFRS / steel-high-rise program (user + parallel agent). Status as of 2026-11-23:

**WS1 — wire the sway/second-order machinery (built in Stages A–C, previously unconsumed).**
- **Checker-side: DONE (gating now), code-confirmed in this tree.** `is_feasible(::AISCChecker, ...)` now takes an optional `story` (StoryStability) and consumes `demand.lt` (Mnt/Mlt split), amplifying through a shared core `_aisc_amplified_forces`: Mr = B1·Mnt + B2·Mlt (AISC 360-16 Eq. A-8-1), Pr = Pnt + B2·Plt (Eq. A-8-2). This is the SAME path `design_column_moments(::MemberDemand, ...)` uses, so RC and steel columns now amplify through ONE unified solver. The old literal 'B2 amplification not implemented' warning is gone; it now warns only when `braced=false && story===nothing` (sway frame sized with no story = unconservative). `steel_feasibility.jl:9-14,60-67,88-125`.
- **Pipeline-side: REMAINING.** `story_stability_records` (ELF→StoryStability, built prior session, `SY/analyze/lateral/story_demands.jl`) must feed `story=` into the member stage, and per-column `lt` must be extracted from the lateral cases (the 'colsplit' todo). The checker is ready; the Synthesizer plumbing that calls it with real story/lt is the open piece.

**WS2 — drift as a sizing driver + lateral-system selection (Phase H4).** Partial.
- In progress: `DualSystem` — ASCE 7-22 Table 12.2-1 Section D/E classification with SDC-driven selection + validated override (the moment-frame-vs-dual classification for a steel frame + RC core). This is the lateral-system-selection half.
- Still ahead: drift driving beam/column STIFFNESS (today drift only drives wall thickness) and bracing-bay placement — downstream of classifying the dual system and sizing columns as sway members.

**Summary:** WS1 checker-side = done; WS1 pipeline hand-off + WS2 selection = in progress; WS2 drift-as-driver + bracing placement = still ahead. The actual steel moment/braced-frame member designers (Phase H1/H2: brace tension/compression-only, EBF links, panel zones) remain greenfield beyond this sway/selection groundwork.
