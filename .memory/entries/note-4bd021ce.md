---
id: note-4bd021ce
type: note
project: menegroth
parent_id: note-7de9d402
title: 'Critic findings on committed Defect 4 punching: [P1] edge governing-max unconservative
  (ACI silent on biaxial), [P1] centroid eccentricity e off by d/2 vs cited spSlab
  example'
node_label: 'Critic findings on committed Defect 4 punching: [P'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/codes/aci/punching.jl@8484f17, StructuralSizer/src/slabs/codes/concrete/flat_plate/design/checks.jl@e1aa19a,
  StructuralSizer/test/slabs/test_corner_punching.jl@8b97d6d
session_id: sess-cc037eba
created_at: '2026-10-22T16:34:27.420865+00:00'
updated_at: '2026-10-22T16:34:27.420865+00:00'
---
Pre-ribbed run-9091881e critic pass (Opus) red-teamed the already-committed Defect 4 biaxial punching code and surfaced two P1 safety concerns (code is pre-existing, NOT this run's change; the dedup it was paired with is clean — reviewer+bugbot PASS, critic only P2 fragility on it).

[P1] EDGE unconservative: punching.jl `_governing_edge_moment` (422-428) + `punching_check` :edge (583-589) and checks.jl :edge (82-88) collapse the edge case to uniaxial Mub=max(|Mux|,|Muy|), dropping the perpendicular-axis eccentric-shear term, whereas :interior and :corner superpose both axes additively. Concrete unsafe scenario: square edge column c1=c2=16in, d=5.75in, comparable Mux≈Muy≈60 kipft → code returns v_direct+1×v_moment, rigorous two-way shear is v_direct+~2×v_moment → vu under-predicted by ~a full moment term.
GROUNDING: ACI 318-11 §11.11.7.1 (corpus aci-318-11, p.209) is written for a SINGLE unbalanced moment Mu transferred about the critical-section centroid (γf Mu flexure per §13.5.3, γv Mu eccentric shear, γv=1−γf, Eq.11-37); it is SILENT on the biaxial two-moment case. So governing-max is not a clause violation, but additive-biaxial (as used at interior/corner) is the more rigorous/conservative practice. => DESIGN DECISION for the user, not an auto-fix.

[P1] CENTROID ECCENTRICITY: punching.jl:586 e=c1/2−cAB (edge) and 611-612 e_x=c1/2−cAB_x, e_y=c2/2−cAB_y (corner); mirrored checks.jl:144,149. Critic says this disagrees with the cited spSlab/StructurePoint p.42 worked example (e=(b1−cAB)−c1/2) by exactly Vu·d/2 (since b1−c1=d/2): spSlab e=4.89in→vu=137.2psi vs code e=2.01in→vu≈147psi. CONSERVATIVE here (~7% high) but sign-fragile (cAB>c1/2 or reversed-sign transfer). NOT YET VERIFIED against the corpus — §11.11.7.2 (p.210) only states eccentric shear varies about the critical-section centroid; the e-geometry needs tracing to PCA EB712 Fig.16-13 before any change (don't 'fix' toward a less-conservative value without grounding).

[P2] interior docstring labels moments 'about x/y axis' but pairs Mux with the x-span section (b1=c1+d) — rectangular-column callers taking it literally would swap γv/Jc (square-only tests can't catch). [P2] dedup fail!/on_inadequate Boolean contract (true=continue,false=stop) is latent-fragile — add a pinning comment/regression test.

RECOMMENDATION: focused corpus-grounded follow-on fix-cycle — (1) adopt additive biaxial at edges (consistent with interior/corner + conservative), updating both the :edge code AND the edge oracle in test_corner_punching.jl, pending user approval of the design convention; (2) verify the centroid eccentricity against PCA EB712 Fig.16-13 and correct if the cited source disagrees; (3) fix the docstring axis convention + add a rectangular-column known-answer test; (4) pin the dedup callback contract.
