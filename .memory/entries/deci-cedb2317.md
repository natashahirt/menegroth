---
id: deci-cedb2317
type: decision
project: menegroth
parent_id: deci-ee890c91
title: Frame-only 25% check reuses the unified solve
node_label: Frame-only 25% check reuses the unified solve
tags: walls,phase-7,12.2.5.8,asap,frame-only,decision
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-8c698d00
created_at: '2026-11-02T16:13:28.589126+00:00'
updated_at: '2026-11-02T16:14:46.626237+00:00'
---
User choices (2026-11-02):
- Add an option to Asap's multi-case solve(model, cases, links) that leaves the shells out of the stiffness and holds fixed the degrees of freedom only shells touch. Reason: process! renumbers each node's globalID in place, so a second model sharing nodes would break every stored displacement vector. The existing geometric_stiffness hook cannot subtract the shells because it refuses terms on rigid-link slave degrees of freedom, and wall nodes at floor levels are slaves.
- Reused without recomputing: gravity beam and column forces from the unified basic.u; the ELF _elf_loads vectors, solved at full strength and multiplied by 0.25; combinations 6 and 7 as weighted sums of stored forces; Px and Vx from elf.levels and elf.cases; _frame_cut_contributions to confirm each story sums to 0.25 Vx.
- P-delta in the frame-only check: theta from the frame's own drifts, forces multiplied by 1/(1-theta) (ASCE 7-22 12.8.7, PDF p. 188), refused where theta > theta_max. This replaces the earlier plan to solve on the story geometric stiffness. One factorization and six right-hand sides (X and Y, each without accidental torsion and with + and - torsion).
- Rejected: scaling the unified frame forces up to 25%. The frame's share in an interactive system changes with height and can reverse in the upper stories.
