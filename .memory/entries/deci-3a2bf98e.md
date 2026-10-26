---
id: deci-3a2bf98e
type: decision
project: menegroth
parent_id: deci-77a5062f
title: Composite beam checks finish before the ribbed-floor steel arm
node_label: Beam checks before PR 9
tags: composite,ribbed-floor,phase-4b,aisc
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c69b064a
created_at: '2026-10-26T15:07:51.661157+00:00'
updated_at: '2026-10-26T15:07:51.661157+00:00'
---
The ribbed-floor plan's steel arm (PR 9, AISCCompositeRibProvisions) wraps the composite beam checker. It does not re-derive studs, pour-stage bracing, the pre-cure moment, or hogging. Concrete pan joists in that plan do not wait on it.

Sequence after Phase 4, in the composite production-gaps plan:
1. Phase 4b: deck-attached beams default the sagging-face construction Lb to 0 (Commentary I3.1b, PDF p. 501, the reverse of the unattached-forms sentence). Solid slabs on unattached forms keep the span. Explicit length overrides. Report Appendix 6.3.1a Eq. A-6-5 brace shear (PDF p. 342, Cd=1 on the simple-span model). Do not evaluate Eq. A-6-6a: Appendix 6 does not define Lbr for deck that braces continuously. Then scale the steel-only dead-load analysis field to the SEI/ASCE 37-02 line load; pinned ends still give wL^2/8.
2. Phase 5: composite hogging from developed reinforcement, plus steel-only hogging Cb from Commentary Eq. C-F1-5 (PDF p. 442), flagged as commentary. Appendix 6.3.1(b) still requires both flanges braced near an inflection point.
3. Phase 6: deck limits, Vulcraft geometry, e_mid-ht, and the SDI diaphragm comparison against the brace demand. Skewed ribs have no sourced rule. Default stud when the caller omits one: 3/4 in, length at least four diameters, Fu=65 ksi from the 14th Manual p. 165 ASTM A108 Type B, named and reported with the edition gap.
4. Phase 9: catalog snap of a continuous result, then the discrete checker. Plate girders stay out (built-up flange, slender web, welds, no plate stock in the corpus; noncompact webs cannot use I3.2a plastic strength).

The pour-stage Lb default and the reported brace shear are the code started with this decision. Stiffness is not computed. Fu=65 ksi is not yet a silent default.
