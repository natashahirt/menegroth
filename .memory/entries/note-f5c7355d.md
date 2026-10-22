---
id: note-f5c7355d
type: note
project: menegroth
parent_id: plan-b2670c25
title: 'Citation-sweep target list: DDM 318-11 §13.6 vs 318-19 §8.10 numbering mix'
node_label: 'Citation sweep targets: 8.10 vs 13.6'
tags: citation,aci,ddm,corpus,sweep
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/api/schema.jl@4b50e18, StructuralSynthesizer/src/api/chat.jl@4b50e18,
  StructuralSynthesizer/src/analyze/foundations/utils.jl@4b50e18, StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/helpers.jl@4b50e18,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm.jl@32ccab8, docs/src/sizer/slabs/codes/concrete/flat_plate.md@4b50e18
session_id: sess-17eaba00
created_at: '2026-10-22T01:26:51.494702+00:00'
updated_at: '2026-10-22T01:26:51.494702+00:00'
---
Scoped 2026-10-21 while the cycle-13 fix ran. The citation sweep (deci-f9210465 step c, its own run before ribbed floors) must resolve one systematic issue, not scattered typos: the DDM is cited under TWO editions across the suite for the same provisions. Repo primary edition is ACI 318-11 (note-cb000005), where DDM = Chapter 13: applicability §13.6.1.1-.6 (p.252), longitudinal §13.6.3/.4, transverse CS/MS §13.6.4/.6. The §8.10.x numbering is ACI 318-19. These must NOT be mixed in one derivation (corpus.mdc). Resolve against the corpus which edition governs, then make every citation consistent OR annotate 318-19 ids explicitly as (= 318-11 §13.6.x). Do not mass-edit before grounding.

PUBLIC-SURFACE applicability citations (highest priority — a caller reads these; §8.10.2.x should be §13.6.1.x in 318-11):
- StructuralSynthesizer/src/api/schema.jl:196,206,207,208,212,213,214,216,244 — DDM/EFM applicability guidance and per-check clause ids (§8.10.2.2 aspect, §8.10.2.6 L/D, §8.10.2.1 spans, §8.10.2.3 successive-span, §8.10.2.4 offset, §8.10.2.5 loads, §8.10.5 CS/MS). In 318-11: aspect/rectangular §13.6.1.2, successive span §13.6.1.3, offset §13.6.1.4, spans §13.6.1.1, L/D §13.6.1.5.
- StructuralSynthesizer/src/api/chat.jl:1870 — '§8.10.2.3 limits DDM to long/short <=2' (aspect is §13.6.1.2 in 318-11; .2.3 is successive-span).
- StructuralSynthesizer/src/analyze/foundations/utils.jl:1203,1228 — §8.10.2.4 column-line 10% offset (→ §13.6.1.4).
- StructuralStudies/src/flat_plate_methods/flat_plate_method_comparison.jl:809 — user-facing '§8.10.2.2: Aspect ratio' string.
- docs/src/sizer/slabs/codes/concrete/flat_plate.md:168,456 and docs/src/reference/design_codes.md:58.

Longitudinal/transverse DISTRIBUTION citations (large, systematic — §8.10.4/§8.10.5 and Tables 8.10.4.2/8.10.5.x): calculations.jl:340,348,533,547,550,554; checks.jl:483,886; reinforcement.jl:88,158; efm.jl:1443,1447,1458,1462; pipeline.jl:1045,1050,1189,1449; helpers.jl:141,188,538,566; types.jl(flat_plate):38; slabs/types.jl:268,374; flat_plate_problem.jl:907; plus many test oracles referencing Table 8.10.4.2 (318-19 table numbers). The distribution-table mix is the bulk of the work; ground the edition decision first.

NOT a defect (resolved): efm.jl:1712 `hasproperty(slab,:is_rectangular) && !slab.is_rectangular` is guarded and consistent with the ddm.jl manual-override design (ddm.jl:3894-3945, is_rectangular=false forces the §13.6.1.2 violation, true skips only the geometric test). Earlier concern that 'real slabs never set is_rectangular' is fine — the field is an optional override, honored only when present. No change needed.

Walls/§18.10.x items are out of scope (walls).
