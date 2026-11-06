---
id: deci-4289ab5c
type: decision
project: menegroth
parent_id: plan-c8115994
title: Diaphragm inertial force, bay shear and chord, core doors
node_label: Diaphragm force and core doors
tags: diaphragm, ASCE 12.10, core, elevator
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/diaphragm_design.jl@c2e183b, StructuralSynthesizer/test/analyze/test_diaphragm_design.jl@c2e183b,
  scripts/runners/core_office_geometry.jl@c2e183b, StructuralSynthesizer/test/core/test_core_shaft.jl@c2e183b
session_id: sess-3225d7e6
created_at: '2026-11-06T23:53:26.558483+00:00'
updated_at: '2026-11-06T23:53:26.558483+00:00'
has_child_rationale: The user asked for the diaphragm design model and, if ready,
  elevator openings on the core-office demo, after the slab-thickness jump.
---
ASCE 7-22 §12.10.1.1 is implemented as `diaphragm_inertial_force`. Eq. (12.10-1) uses the story forces and weights from the level under consideration through the roof. That result is raised to Eq. (12.10-2), 0.2 SDS Ie wpx, and is not taken above Eq. (12.10-3), 0.4 SDS Ie wpx (corpus: asce-7-22, PDF pp. 190–191). The design force is the larger of that bounded force and the structural-analysis force. Eq. (12.10-3) does not cap the analysis force. Transfer forces and the Type 4 overstrength increase are left for the caller.

`diaphragm_bay_actions` turns that force into line shears and chord forces. The inertial load is uniform. Each bay between adjacent lines of vertical elements is a simple span, because §12.10.1 requires design for shear and bending and does not state a continuity factor (PDF p. 190). The chord force is the simple-span moment divided by the depth between chords. This is not the collector overstrength of §12.10.2.1.

ACI 318-19 §12.5.3 shear strength and §12.5.4 collector strength are not implemented. The equation glyphs in the corpus text layer for those sections did not survive extraction, and no LangExtract output exists for them. Concrete diaphragm capacity waits on a readable clause.

The four-story core office, which is `gen_medium_office` with the center bay opened, now has two 1.1 m by 2.1 m elevator doors centered on the south core wall and a 1.0 m by 2.1 m stair door on the east core wall, on every story that has the core wall. Those sizes are demo geometry. The plain `gen_medium_office` grid is unchanged.
