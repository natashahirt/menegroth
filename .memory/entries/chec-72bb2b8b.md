---
id: chec-72bb2b8b
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: 'Phase 6a: fraction re-extract cleared Eqs. 12.8-2, 12.8-3, 12.8-18, and 12.8-19'
node_label: 6a fractions re-extracted
tags: asce-7-22,phase-6,corpus
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-26e2f075
created_at: '2026-10-23T20:04:06.185287+00:00'
updated_at: '2026-10-23T20:04:06.185287+00:00'
has_child_rationale: The previous 6a checkpoint still listed the Cs and P-delta equations
  as unread. The re-extract makes those lines readable, so that hold list is stale.
invalidates: chec-08074939
---
The ASCE 7-22 text extract was regenerated. scripts/util/convert_pdfs_to_text.py now decodes the private equation glyphs, splices a hairline fraction bar into one glyph on the equals-sign line, snaps subscripts onto that baseline, and drops rotated watermark glyphs. corpus/text/codes/asce/ASCE-7-22.txt was rewritten (gitignored). Placeholders fell from 965 to 68. The leftovers are Helvetica map marks, wind-figure notation, and the Calibri t in Directional. They are not remapped.

Cleared from the new lines, and quoted in corpus/manifests/promotions.yml: V = CsW (12.8-1), Cs = (Sa/(R/Ie)) (12.8-2), Cs = (SDS/(R/Ie)) (12.8-3), Fx = CvxV (12.8-12), TIR = Δmax/Δavg (12.3-2), θ = (Px∕hsx)/(Vx∕Δxe) (12.8-18), θmax = 0.5/βCd ≤ 0.25 (12.8-19). Eq. 12.8-16 reads δDE = Cdδe/Ie þ δdi and Eq. 12.8-17 reads δMCE = 1.5 Rδe/Ie þ δdi. The þ is this font's plus sign.

Still held, and not to be encoded: Eq. 12.8-4 and Eq. 12.8-5 (empty fence, factors jammed), Eq. 12.8-13 (the summation sign is a P and the limits are smashed), the square on Eq. 12.8-15 (the 2 sits on the line above Ax = δmax/1.2δavg), and all of Chapter 27. char_start values in the manifest were remeasured against this file. Nothing was encoded. 6b has not been started.
