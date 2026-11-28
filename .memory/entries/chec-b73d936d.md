---
id: chec-b73d936d
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: ELF drift load, story shear, and corrected NEHRP oracles checked
node_label: ELF follow-ups checked
tags: asce-7-22,phase-6,seismic,checkpoint
status: active
open_threads: 1
success: 'null'
files: StructuralSizer/src/loads/seismic.jl@a2148b5, StructuralSizer/src/StructuralSizer.jl@a2148b5,
  StructuralSizer/test/loads/test_seismic_elf.jl@a2148b5, StructuralSizer/test/loads/test_seismic_nehrp_examples.jl@a2148b5,
  StructuralSizer/test/runtests.jl@a2148b5
session_id: sess-87dd284b
created_at: '2026-10-25T13:52:38.097318+00:00'
updated_at: '2026-10-25T19:32:06.322681+00:00'
---
Run run-41ea1551 closed. Engineer (grok-4.7-high) added drift_expected_gravity_load as 1.0D + 0.5L with L = 0.8L0 above 100 psf and 0.4L0 otherwise, for_drift on seismic_response_coefficient (skips Eq. 12.8-6, keeps Eq. 12.8-7), seismic_story_shear (Eq. 12.8-14), and the Method 1 / §11.4.5 Exception 2 caller note. NEHRP 2020 Examples 4 and 5 tests assert the ASCE 7-22 arithmetic, not the published mistakes (Example 4 floor uses SDS = 1.10; Example 5 floor 0.044*1.101 governs, V = 1,251.99 kips on W = 25,844). Engineer run of the two test files: 109/109. Critic (gpt-5.6-sol-medium) RESULT CONCERN, P2 citation-format only; no fix cycle. TL = T for Example 5 accepted. Printed Example 5 w*h^k column left unasserted (about 1.4e-4 relative, outside integer rounding). Not committed. Next is Phase 6d: apply story forces and accidental torsion on the Phase 5 building.
