---
id: chec-bda5cea3
type: checkpoint
project: menegroth
parent_id: plan-b231dcef
title: Row F sensitivity suite passed; commit held
node_label: Row F suite green
tags: row-f,sensitivity,nlp,tests,commit-held
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4a6907ff
created_at: '2026-11-11T04:12:32.916899+00:00'
updated_at: '2026-11-11T04:12:32.916899+00:00'
has_child_rationale: Closes the sensitivity wave of the Row F plan. The commit is
  held because the working tree is mixed with another session.
---
Sensitivity and correctness suites passed on 2026-11-10.

StructuralSynthesizer analyze/test_frame_section_floors.jl and analyze/test_row_f_resize.jl: 162/162 (log logs/test_StructuralSynthesizer_20261110_225850.log). StructuralSizer optimize/test_column_nlp_adapter.jl: 130/130, including the interaction-surface testset (log logs/test_StructuralSizer_20261110_230620.log).

Behavior that matches the interaction surface and the dual-system check:
- At fixed axial load, a larger moment never brings a failed section back, and the row F floor objective does not fall as moment rises (observed floors 153.5, 221.1, 301.0, 393.1, 614.2 kg).
- Below the balance point (ACI 318-19 §22.4) a lower axial load can fail a section that passes a higher one. The floor is written for the low-axial case and not for the high-axial case. The split is not always on the lightest catalog section; the test searches the catalog.
- Adding the orthogonal moment does not make a failed uniaxial case pass. The envelope (max P with max M) is a different demand from the two real cases. An NLP section constrained on both cases passes both. A section sized for the larger moment still carries the smaller one.
- One-story dual system, lightest square column and a 12x24 beam: SDS 0.5 and 1.0 both pass with an empty floor. A higher SDS in {2, 3, 4, 5} fails members, writes floors, snapshot/restore keeps them, and sizing plus a recheck leaves every frame member passing with worst ratio below 1. A catalog capped at the light section stays failing, with no floor and the member not resized.
- :per_story floors only the failing story's group. :building floors every group in the cohort with that same section.
- Station diagrams use only the loads on that element (ordinary_walls_v8).

Surprise, and it is not a dropped seismic force: SDS 0.5 and SDS 1.0 produced the same governing ratio, 0.3649789029535865. At that demand the gravity moment governs, so the reported ratio does not move until seismic moment exceeds it. The ratio does not fall as SDS rises, and the SDS that fails the frame sits above the low-SDS ratio. The test asserts that, not a strict increase between 0.5 and 1.0.

Commit of plan-b231dcef is not made. The working tree also holds another session's uncommitted problems.jl/api.jl split, rib-bay prepare edits, and provenance bumps (slab_sizing_v3, members v2–v4) that are not this plan. Whole-file commits would take those hunks. prepare.jl rib_bays still needs that session's confirmation. The temporary probe scripts/runners/probe_row_f_resize.jl was removed and must not be committed.

Still out of scope: beam NLP envelope, NLP honoring section floors, and a full redesign_incremental! of the office.
