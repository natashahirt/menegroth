---
id: deci-24ce4d70
type: decision
project: menegroth
parent_id: deci-610bd5f9
title: 'Composite Phase 6a: default stud, §I3.2c deck limits, e_mid-ht Rp, twist-restraint
  spacing'
node_label: 'Phase 6a: stud default, deck limits, Rp, L_twist'
tags: composite,phase-6,stud,deck,aisc,cb
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-08c0b2ae
created_at: '2026-10-27T13:42:06.320300+00:00'
updated_at: '2026-10-27T15:14:55.489132+00:00'
has_child_rationale: User chose 1a (named default stud) and 2a (Phase 6 plus optional
  twist spacing).
---
Phase 6, first half.

- Default stud when all three stud fields are unset: 3/4 in ASTM A108 Type B, Fu = 65 ksi (aisc-scm-14th, PDF p. 165), l_sa = max(4 d_sa, hr + 1.5 in). HeadedStudAnchor.source carries the name and the edition gap (Manual predates 360-22); explain_feasibility prints it on the shear_anchors line. A partly named stud still throws. tf < 0.30 in rejects it via §I8.1.
- §I3.2c(1)(a)-(d) and §I3.2c(3) parallel-deck wr rule (aisc-360-22, PDF p. 170) in deck_limit_failures. Anchorage spacing unset is reported unchecked, not passing. A failed deck limit allows only the zero-stud layout (steel alone) with reason :deck_limits; it does not reject every section.
- DeckSlabOnBeam.e_mid_ht: Rp = 0.75 when >= 2 in, else 0.6; unknown stays 0.6 (§I8.2a, PDF p. 182).
- CompositeContext.L_twist / SteelBeamOptions.composite_twist_spacing: replaces the span as hogging Lb (capped at member length). C-F1-5 evaluated per segment with restraints at both supports and every L_twist from the start; minimum Cb used; a segment hogging mid-length but not at its ends returns nothing (Cb = 1).
- New options are Julia-only; REST API exposes only the stud default text.

Open: Vulcraft catalog geometry, SDI DDM diaphragm strength vs Appendix 6 brace shear. Spec gap left as-is: parallel deck wr/hr < 1.5 with >1 stud per row has no Rg in §I8.2a; code keeps 0.85.

Tests: StructuralSizer composite 398/398; Synthesizer test_composite_context 173/173.
