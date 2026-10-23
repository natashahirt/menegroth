---
id: chec-c0c7d18e
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: 'Phase 6a: page read of Eqs. 12.8-4, 12.8-5, 12.8-15, and 27.3-1'
node_label: 6a page read of the held equations
tags: asce-7-22,phase-6,corpus
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-8f6fb753
created_at: '2026-10-23T20:34:53.117514+00:00'
updated_at: '2026-10-23T20:34:53.117514+00:00'
---
Read the held equations from the ASCE 7-22 PDF glyphs, source_id asce-7-22. corpus page_window is still serving the pre-re-extract text, so the page glyphs were used.

Cleared from the page into corpus/manifests/promotions.yml: Eq. 12.8-4 is Cs = SD1 / (T (R/Ie)) for T ≤ TL, and Eq. 12.8-5 is Cs = SD1 TL / (T^2 (R/Ie)) for T > TL (PDF page 185). Eq. 12.8-15 is Ax = (δmax / (1.2 δavg))^2 (PDF page 187). Eq. 27.3-1 is p = q Kd G Cp − qi Kd (GCpi) (PDF page 342). Eq. 27.3-2 is p = qh Kd G CN (PDF page 347). The qi cases, the §27.1.5 minimum pressures, and Table 27.2-1 steps 1–8 are in the manifest.

Not cleared: Eq. 12.8-13. The numerator is wx hx^k and the denominator is a sum of wi hi^k, but the glyphs put i=1 above the summation sign and n below it. Do not invert that when encoding. Wind numbers are still blocked on Eq. 26.10-1, the Cp and CN figures, and Table 26.13-1. Nothing was encoded.
