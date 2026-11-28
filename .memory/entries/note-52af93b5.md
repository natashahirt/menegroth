---
id: note-52af93b5
type: note
project: menegroth
parent_id: deci-91a22dd3
title: 'Table 12.2-1 Section D dual rows transcribed+verified from rendered asce-7-22
  p.174 (printed 113): D.3/D.8/D.9 R/Ω₀/Cd, all NL in B–F'
node_label: Table 12.2-1 Section D dual rows transcribed+verif
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/loads/seismic_systems.jl@938451b
session_id: sess-f794529d
created_at: '2026-11-23T18:15:37.980018+00:00'
updated_at: '2026-11-23T18:15:37.980018+00:00'
---
Read from the rendered scanned table (asce-7-22 PDF page 174 = printed page 113, 400 DPI render, rotated). Columns: system | ASCE 7 § | R | Ω₀ | Cd | B | C | D | E | F.

Section D header: "DUAL SYSTEMS WITH SPECIAL MOMENT FRAMES CAPABLE OF RESISTING AT LEAST 25% OF PRESCRIBED SEISMIC FORCES" (§12.2.5.1).

Rows relevant to steel-frame + RC-core (user-verified in-session 2026-11-23):
- D.3 Special reinforced concrete shear walls — §14.2 — R=7, Ω₀=2½, Cd=5½ — NL NL NL NL NL (B–F). For a CONCRETE special moment frame + special RC walls.
- D.8 Steel and concrete composite plate shear walls — §14.3 — R=7½, Ω₀=2½, Cd=6 — NL NL NL NL NL (B–F).
- D.9 Steel and concrete composite special shear walls — §14.3 — R=7, Ω₀=2½, Cd=6 — NL NL NL NL NL (B–F). This is the row for STEEL special moment frame + RC special shear-wall core (composite dual, §14.3 / AISC 341 Part II).

All Section D rows are NL (no height limit) in every SDC B–F.

AMBIGUITY FLAGGED (not needed for D.3/8/9 but noted for completeness): the rendered Section D lists two rows both titled 'Steel and concrete composite plate shear walls' — row 8 (R=7½, Cd=6, §14.3) and row 15 (R=8, Cd=5½, §14.3). Only row 8 (=D.8) is carried; row 15 left out pending clarification.

For comparison, carried E.8 (Section E, IMF dual, ordinary RC walls) = R=5.5, Ω₀=2.5, Cd=4.5, permitted B,C only (already in _ORDINARY_CONCRETE_SYSTEMS).

Citation: ASCE 7-22 Table 12.2-1 Section D (corpus: asce-7-22, PDF page 174, printed page 113); §12.2.5.1 (PDF page 177).
