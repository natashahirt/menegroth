---
id: chec-7fdd8bca
type: checkpoint
project: menegroth
parent_id: todo-8e6b87f4
title: Magnified weak-axis check and Row F demand rows, before column and beam NLP
node_label: Weak-axis check and stored rows
tags: row-f,walls,nlp,aci-318
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a7275d9d
created_at: '2026-11-11T19:09:00.998274+00:00'
updated_at: '2026-11-11T19:09:00.998274+00:00'
has_child_rationale: Prelude finished; NLP constraint wiring is the next step.
---
On branch row-f-nlp in the /tmp/menegroth-rowf worktree (off 2a7acb7d, not committed). The main checkout was left on main.

Ordinary walls outside the middle third no longer throw. Strength is nonsway magnification ACI 318-19 §6.6.4.5 (PDF p. 82): Mc = δ M2, δ = Cm / (1 − Pu/(0.75 Pc)) ≥ 1, Cm = 0.6 at M1/M2 = 0, k = 1 (§6.6.4.4.3, p. 81), (EI)eff = 0.4 Ec Ig / (1+βdns) with βdns = 0.6 (§6.6.4.4.4a, p. 81). Pu ≥ 0.75 Pc fails. The section is then checked bent through its thickness with the smeared P–M model. Inside t/6 the empirical bearing check is unchanged. §11.8 is not this check.

Each Row F floor also stores that group's demand rows in struc.frame_floor_demands (union of the group's members). Snapshots, prepare!, and the design-graph fingerprint carry them. Column and beam NLP do not read them yet.

Tests: frame floors 155/155, Row F resize 38/38, column NLP adapter 130/130. The new §6.6.4.5 wall testset is 19/19. walls/test_walls.jl still has two older β1 comparisons (0.85 and 0.75 at atol 1e-9) that miss by about 1e-8; those lines were not part of this change.

Next, not started: column NLP appends the stored rows with slenderness magnification off, then beam NLP gets one shear and torsion row per case.
