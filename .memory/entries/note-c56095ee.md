---
id: note-c56095ee
type: note
project: menegroth
parent_id: plan-382ddd12
title: Table 12.2-1 Section D (dual w/ special moment frames) transcription — read
  from rendered page, PENDING USER VERIFICATION before driving sizing
node_label: Table 12.2-1 Section D (dual w/ special moment fra
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-de817bbf
created_at: '2026-11-23T17:00:45.873129+00:00'
updated_at: '2026-11-23T17:00:45.873129+00:00'
---
Read from the rendered image of ASCE 7-22 Table 12.2-1, Section D 'DUAL SYSTEMS WITH SPECIAL MOMENT FRAMES CAPABLE OF RESISTING AT LEAST 25% OF PRESCRIBED SEISMIC FORCES' (detailing §12.2.5.1), corpus asce-7-22 PDF page 174 (printed page 113), via pdftoppm 450 DPI rotated crop on 2026-11-23. Columns: System | §detailing | R | Ω0 | Cd | B | C | D | E | F (height limits; NL=no limit, NP=not permitted). NOT yet committed to code; awaiting user verification.

D.1 Steel eccentrically braced frames | 14.1 | 8 | 2½ | 4 | NL NL NL NL NL
D.2 Steel special concentrically braced frames | 14.1 | 7 | 2½ | 5½ | NL NL NL NL NL
D.3 Special reinforced concrete shear walls (d,h) | 14.2 | 7 | 2½ | 5½ | NL NL NL NL NL
D.4 Reinforced concrete ductile coupled walls (g) | 14.2 | 8 | 2½ | 8 | NL NL NL NL NL
D.5 Ordinary reinforced concrete shear walls (g) | 14.2 | 6 | 2½ | 5 | NL NL NP NP NP
D.6 Steel and concrete composite eccentrically braced frames | 14.3 | 8 | 2½ | 4 | NL NL NL NL NL
D.7 Steel and concrete composite special concentrically braced frames | 14.3 | 6 | 2½ | 5 | NL NL NL NL NL
D.8 Steel and concrete composite plate shear walls | 14.3 | 7½ | 2½ | 6 | NL NL NL NL NL
D.9 Steel and concrete composite special shear walls | 14.3 | 7 | 2½ | 6 | NL NL NL NL NL
D.10 Steel and concrete composite ordinary shear walls | 14.3 | 6 | 2½ | 5 | NL NL NP NP NP
D.11 Special reinforced masonry shear walls | 14.4 | 5½ | 3 | 5 | NL NL NL NP NP
D.12 Intermediate reinforced masonry shear walls | 14.4 | 4 | 3 | 3½ | NL NL NP NP NP
D.13 Steel buckling-restrained braced frames | 14.1 | 8 | 2½ | 5 | NL NL NL NL NL
D.14 Steel special plate shear walls | 14.1 | 8 | 2½ | 6½ | NL NL NL NL NL
D.15 Steel and concrete coupled composite plate shear walls | 14.3 | 8 | 2½ | 5½ | NL NL NL NL NL

§detailing codes: 14.1=steel (AISC 341), 14.2=concrete (ACI 318), 14.3=composite steel+concrete (AISC 341 Part II), 14.4=masonry.

CLASSIFICATION QUESTION for 'steel frame + RC core': if the moment frame AND walls are concrete → D.3 (R=7, Cd=5½). If it is a bare-steel special MF + RC/composite special shear walls sharing lateral load → composite system D.9 'composite special shear walls' (R=7, Cd=6) or D.8 composite plate shear walls (R=7½, Cd=6). User must confirm which row matches the intended system before it drives sizing. All three target rows are NL (no height limit) in every SDC B–F.

For reference, existing carried Section E row (committed earlier) is E ordinary-RC-walls dual w/ IMF. Section E rows on same page: E.1 Steel special concentrically braced frames (f) 14.1 | 6 | 2½ | 5 | NL NL 35 NP NP; E.2 Special reinforced concrete shear walls (d,h) 14.2 | 6½ | 2½ | 5 | NL NL 160 100 100; E.3 Ordinary reinforced masonry shear walls 14.4 | 3 | 3 | 2½ | NL 160 NP NP NP (section E continues on PDF page 175).
