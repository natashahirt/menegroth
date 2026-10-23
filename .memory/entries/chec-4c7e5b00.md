---
id: chec-4c7e5b00
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: 'Phase 6c seismic: ELF functions encoded, period cap corrected'
node_label: ELF functions encoded
tags: asce-7-22,phase-6,seismic
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f39803c0
created_at: '2026-10-23T23:53:31.590895+00:00'
updated_at: '2026-10-23T23:53:31.590895+00:00'
---
Pure ASCE 7-22 ELF functions are in StructuralSizer/src/loads/seismic.jl, with hand checks in StructuralSizer/test/loads/test_seismic_elf.jl (52 passed). Not applied to a building. Wind was not encoded.

Eqs. 12.8-4 and 12.8-5 cap only method :sds (Eq. 12.8-3). Method :sa is Sa/(R/Ie). Eqs. 12.8-6 and 12.8-7 are lower bounds for both methods. The Eq. 12.8-13 sum is over every level, i = 1 to n, marked as engineering judgment because the 7-22 page prints the limits the other way.

Critic P0 on the :sa cap was fixed. Remaining, not fixed: method :sa still requires SD1 and TL, which are only inputs to the :sds cap. SDS and S1 stay required for both methods. The functions take plain Float64, matching the existing load combinations; Unitful inputs throw. Run run-70f7ee87, one extension used.
