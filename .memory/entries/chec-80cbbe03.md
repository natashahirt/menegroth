---
id: chec-80cbbe03
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: Spectral method no longer requires the period-cap inputs
node_label: Sa inputs narrowed
tags: asce-7-22,phase-6,seismic
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f39803c0
created_at: '2026-10-24T00:00:55.691435+00:00'
updated_at: '2026-10-24T00:00:55.691435+00:00'
---
seismic_response_coefficient with method :sa no longer requires SD1, T, or TL. Those three are inputs only of Eqs. 12.8-4 and 12.8-5, which cap Eq. 12.8-3. SDS and S1 stay required for both methods because Eqs. 12.8-6 and 12.8-7 apply to both. Hand checks in StructuralSizer/test/loads/test_seismic_elf.jl passed. Not committed.
