---
id: note-c2e0a9ce
type: note
project: menegroth
parent_id: note-7de9d402
title: 'CONFIRMED (tester, git-stash isolated): Defect 4 NOT fixed in production —
  size_flat_plate! drops secondary Muy → corner pr.vu 155.7 vs biaxial 253.4 psi (~40%
  understatement)'
node_label: 'CONFIRMED (tester, git-stash isolated): Defect 4 N'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline.jl@40e79cc, StructuralSizer/src/slabs/codes/concrete/flat_plate/design/rule_of_thumb.jl@40e79cc,
  StructuralSizer/test/slabs/test_corner_punching.jl@8b97d6d
session_id: sess-cc037eba
created_at: '2026-10-22T17:07:13.091607+00:00'
updated_at: '2026-10-22T17:07:13.091607+00:00'
---
Pre-ribbed run-9091881e tester empirically overturns the explore pass's 'already fully implemented' read. Full StructuralSizer Pkg.test(): 7477 pass / 20 fail / 1 broken.

DEDUP (this run's change): REGRESSION-FREE, proven by git-stash isolation — test_eq_13_7_adjoining.jl 64/64, all Eq.(13-7) cycles + Pipeline Provisions 53/53 green; the 16 corner fails are byte-identical with AND without the refactor (155.7 vs 253.4), so pre-existing.

DEFECT 4 PRODUCTION GAP (the real remaining safety defect): the committed biaxial fix reaches the DIRECT check_punching_for_column(...; Muy=...) API and the NLP evaluate() path (those 9 testsets PASS), but the production ITERATIVE size_flat_plate! / rule-of-thumb pipeline does NOT forward the secondary-axis Muy into the stored corner punching_check.details. Production pr.vu = UNIAXIAL ~155.7 psi (≈ r_old) instead of the biaxial r_new ~253.4 psi → ~40% punching-shear understatement in production flat-plate design (this is exactly the original Defect-4 safety concern). Oracles red: 'Corner punching — pipeline / RuleOfThumb pass Muy' 13 pass / 16 fail (test_corner_punching.jl:500/501/537/538). NOTE: these 16 are SKIPPED in a Sizer-only run (gated on HAS_STRUCTURAL_SYNTHESIZER) — only visible under full Pkg.test() with the synthesizer available, which is why they slipped.

SEPARATE from the critic's two P1s (note-4bd021ce): edge governing-max design decision + centroid eccentricity vs EB712. The production-wiring gap is the CORNER path (additive biaxial already in the check) and is independent of the edge convention — forwarding the real Muy should flip all 16 corner oracles green without touching the edge decision.

FIX DIRECTION: investigate why production stores uniaxial corner punching details despite explore noting pipeline.jl:1507-1525 / rule_of_thumb.jl:273-289 'pass Muy=Muy_i' (likely Muy_i unpopulated for corners during iteration, OR the stored details come from a different punching call that omits Muy); wire the actual secondary unbalanced moment through so production pr.vu == biaxial r_new. Do NOT change the edge governing-max or eccentricity (pending user/corpus decisions).
