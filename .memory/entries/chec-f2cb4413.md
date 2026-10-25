---
id: chec-f2cb4413
type: checkpoint
project: menegroth
parent_id: plan-02c6d260
title: 'Commit: ASCE 7-22 equivalent lateral force as pure functions'
node_label: ELF committed
tags: asce-7-22,phase-6,seismic,commit
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/loads/seismic.jl@f00b559, StructuralSizer/src/loads/_loads.jl@f00b559,
  StructuralSizer/test/loads/test_seismic_elf.jl@f00b559, corpus/manifests/promotions.yml@f00b559
session_id: sess-5e98e520
created_at: '2026-10-25T13:32:01.286820+00:00'
updated_at: '2026-10-25T13:32:01.286820+00:00'
---
Commits the ASCE 7-22 §12.8 equivalent-lateral-force functions recorded in chec-4c7e5b00 and chec-80cbbe03, with their hand checks (56/56), and the promotion record corpus/manifests/promotions.yml.

- Cs Method 1 (Eq. 12.8-2) takes no period cap and does not require SD1, T, or TL. Method 2 (Eq. 12.8-3) is capped by Eqs. 12.8-4/5. Floors 12.8-6 and 12.8-7 apply to both.
- Eq. 12.8-13 is summed over every level i=1..n as engineering judgment (deci-0fd1b15d).
- Not applied to a building. Plain Float64 inputs, like combinations.jl.
- promotions.yml: seismic clauses accepted; Chapter 27 wind still held for the undigitized dome curves in Figure 27.3-2.

The StructuralSizer exports and the runtests include for these files were already swept into commit 21adc635; this commit supplies the files they name.
