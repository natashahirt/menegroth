---
id: deci-d1850cbb
type: decision
project: menegroth
parent_id: deci-24ce4d70
title: 'Phase 6b: Vulcraft deck geometry, and the brace force reported beside the
  deck attachment'
node_label: 'Phase 6b: Vulcraft geometry, reported deck'
tags: composite,phase-6,vulcraft,sdi,diaphragm,deck
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-17184d82
created_at: '2026-10-27T15:14:55.489132+00:00'
updated_at: '2026-10-27T15:16:43.267273+00:00'
has_child_rationale: User asked to search the corpus and to keep fastener input optional,
  with a default where a source names one.
---
Phase 6, second half. Closes the Phase 6 list in deci-3a2bf98e except skewed ribs, which still have no sourced rule.

Vulcraft Deck Solutions (Sept 2020) supplies geometry only, from the Nominal Dimensions figures (text layer had dropped them): 1.5VL hr=1.5 in, wr=2.125 in, pitch 6 in (PDF p. 80); 2VLI hr=2 in, wr=6 in, pitch 12 in (p. 88); 3VLI hr=3 in, wr=6 in, pitch 12 in (p. 92). Side-lap names (1.5VLI, 2VLJ, 2PLVLI, 3VLJ, 3PLVLI) share that geometry. 1.5VLR is not in the catalog; its rib width was not readable. Gage thickness and deck weight are stored and not used for strength. composite_deck_profile on SteelBeamOptions fills hr and wr; an explicit value that disagrees by more than 1/32 in throws. The 3VLI average width matches AISC Example I-1 (6 in).

Deck diaphragm vs Appendix 6 brace shear is reported and not checked. Searched aisc-dg28-stability (E.2.8 continuous bracing is the column Sigma-P case; examples assume diaphragm bracing), aisc-360-22 Appendix 6 and Commentary F1 (PDF p. 443: deck restrains the top flange, unbraced length is the twist-restraint spacing, no strength comparison), sdi-c-2017 PDF p. 10 (attachment provides stability of the supporting member per AISI S100; diaphragm strength is bare deck per AISI S310), and sdi-ddm-3e-2004. AISI S310 and DDM04 are not in the corpus. Vulcraft diaphragm strength is a web tool, not in the PDF. No source converts Vbr (force per brace) into a shear per length.

Default that is sourced: support fastener pattern 36/4, the DDM03 standard composite deck pattern (PDF pp. 11-12). Those tables are filled deck at Fy=33 ksi, so no strength is taken from them. Optional caller inputs: side-lap connectors per span, and a nominal diaphragm strength Sn per unit length. Both default to unset. The construction-check note lists the pattern, Vbr, and Sn when given, and says it is not a check.

Tests: StructuralSizer test_composite_beam.jl 258/258. StructuralSynthesizer composite-context tests were not re-run for this half.

Still blocked, unchanged: Lbr for Eq. A-6-6a, ASCE/SEI 37-14, skewed ribs, parallel-deck Rg when wr/hr < 1.5 and more than one stud per row (I8.2a states 0.85 for a single stud only). Next planned phase is Phase 9: catalog snap of a continuous result, then the discrete checker. Plate girders stay out.
