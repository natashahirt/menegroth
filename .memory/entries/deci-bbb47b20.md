---
id: deci-bbb47b20
type: decision
project: menegroth
parent_id: plan-6fa91d7d
title: ASCE 7-22 strength combinations use 0.3S, 0.15S, and separate Ev
node_label: ASCE 7-22 combo factors
tags: asce-7-22,combinations,ev,snow,phase-7
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a28c7ea7
created_at: '2026-10-26T20:14:22.553011+00:00'
updated_at: '2026-10-26T20:14:22.553011+00:00'
has_child_rationale: The existing constants still used the older single-E form and
  the wrong snow companions.
---
Updated the strength presets to ASCE 7-22.

§2.3.1 (PDF page 68): combination 2a and 4a use 0.3S, not 0.5S. Combination 3a uses 1.0S, not 1.6S. Lr, S, and R remain alternatives. factored_pressure still sums every load that is passed, so the caller passes one companion. The permission to use 0.5L for some occupancies is not the default; L stays 1.0. Tornado WT is not a field.

§2.3.6 (PDF page 69): combination 6 is 1.2D + Ev + Eh + L + 0.15S. Combination 7 is 0.9D − Ev + Eh. LoadCombination.E is the factor on Eh and stays 1.0, so story shears are unchanged. LoadCombination.Ev is +1 on combination 6 and −1 on combination 7.

Eq. 12.4-4a (PDF page 183): vertical_seismic_load_effect(SDS, D) = 0.2*SDS*D. The caller passes that effect. Eq. 12.4-4b (0.3 Sav D) and the permission to take Ev as zero in Seismic Design Category B are not applied inside the function. Overstrength Emh is not these constants.

Tests: StructuralSizer loads/test_seismic_elf.jl, 99 passed. Not committed.
