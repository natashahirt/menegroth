---
id: chec-f27dd5e2
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: 'Phase 6a: velocity pressure, internal pressure, and wall Cp read from the
  page'
node_label: 6a wind coefficients read
tags: asce-7-22,phase-6,corpus
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-8f6fb753
created_at: '2026-10-23T20:43:00.894083+00:00'
updated_at: '2026-10-23T20:43:00.894083+00:00'
---
Read the remaining Phase 6 demand items from the ASCE 7-22 PDF, source_id asce-7-22.

Glyph-checked and written into corpus/manifests/promotions.yml: Eq. 26.10-1 is qz = 0.00256 Kz Kzt Ke V^2 (V in mi/h) and the SI form with 0.613 (PDF page 338). Kd is not inside q. Table 26.13-1 (GCpi) is +0.18/−0.18 enclosed, +0.55/−0.55 partially enclosed, +0.18/−0.18 partially open, 0.00 open (PDF page 341). Figure 27.3-1 wall Cp is 0.8 windward, and leeward −0.5/−0.3/−0.2 for L/B 0–1, 2, and ≥4, sidewall −0.7 (PDF page 345).

Eq. 12.8-13 summation crop shows i=1 above the sign and n below it. C12.8.3 does not restate the limits. Still not cleared.

Roof Cp and the CN grids in Figures 27.3-5, 27.3-6, and 27.3-7 were read from the drawings. Those digits are not in the text layer, so they are not cleared cell by cell. Figure 27.3-2 is a graph. Nothing was encoded.
