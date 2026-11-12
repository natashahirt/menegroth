---
id: chec-2dea3888
type: checkpoint
project: menegroth
parent_id: chec-bf56c090
title: Foundation lateral combinations and mat strip statics are blocked
node_label: Foundation and mat blocked
tags: foundations,mats,asce,aci-336,blocked
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-d9205b69
created_at: '2026-11-12T02:40:14.507561+00:00'
updated_at: '2026-11-12T11:36:07.558636+00:00'
---
These two sizing-map sign-off items were not implemented. The clauses do not fix the formulas, and the research notes list the choices as user decisions.

Wind and seismic into foundation design (sizing-map item 4, research Issue B). Reactions today come from the last mutating gravity solve. Lateral cases do not reach FoundationDemand, which holds one (P, M) set. Sliding is not checked. The partial-contact pressure q = 2P/(3B(L/2−e)) is not grounded in the corpus. Twelve decisions in B.6 are still open: ASD versus strength geotechnical design, which §2.3/§2.4 combinations, the 25% ELF overturning reduction (a permission), Ev = 0 at the soil interface (a permission), the 0.5 live factor, uplift policy, partial contact outside the kern, no allowable-pressure increase, sliding friction, footing self-weight and overburden, ±X/±Y versus 100/30, and pattern live load. A guessed combination set would size footings to a rule the code does not state.

Rigid-mat strip moments (sizing-map item 5, research Issue D). ACI 336.2R §6.1.2 Step 3 (aci-336-combined-footings-mats, PDF page 11) and §5.2 (PDF page 8) require rigid-body strip statics and give no coefficients. The wL²/10, /11, /12 values are an ACI 318 §8.3.3 beam analogy. The hand statics magnitudes are not a quoted source, the strip vertical-summation method points at Bowles (1982), which is not in the corpus, and the inverted-beam face swap is marked for user review. Changing one coefficient while the faces may be swapped could move steel the wrong way.

Worktree /tmp/menegroth-rowf, branch row-f-nlp, HEAD 5072c11c. Not pinned to files because the memory server tracks the main checkout.
