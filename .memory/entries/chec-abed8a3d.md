---
id: chec-abed8a3d
type: checkpoint
project: menegroth
parent_id: plan-16bebf1b
title: 'Full-building scenes: six cases written, two-way slabs unsettled, drift not
  ported'
node_label: 'Full-building scenes: six cases written, two-way s'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2c0913bd
created_at: '2026-11-14T15:04:01.336376+00:00'
updated_at: '2026-11-14T15:04:01.336376+00:00'
---
Worktree /tmp/menegroth-rowf, branch row-f-nlp. Uncommitted. Scene files stay untracked until asked. logs/ not committed.

compare_sizes label scenes writes a .mgscene after each successful design (logs/compare_sizes/scenes/ and viewer/public/, plus scenes.json). A scene error does not discard the CSV.

Results:
- flat_plate: 122 elements, 0 failing, 249 s, scene 1148 KiB. Carbon joint search is the FlatPlateOptions default.
- rc_beams: 138, 0 failing, 216 s, 1812 KiB.
- steel_beams: 138, 0 failing, 212 s, 1597 KiB.
- two_way: 138 elements, 18 failing, 297 s, scene 1808 KiB. The 18 are the slabs, all h=10 in, ratio 0. Story-shell sizing did not settle after 3 rounds (member_iteration.jl). Beams and columns in the CSV are ok. Development-length warnings remain (ld about 47 in).
- core_office: 237, 0 failing, 508 s, 2481 KiB. Spread footings plus grade-wall groups.
- core_mat: 226, 0 failing, 593 s, 2445 KiB. Building mat fell off the rigid method (Kr=0.0016) and redesigned as Winkler. The plate does not take wall line loads; an empty walls list is accepted and a non-empty list errors rather than dropping the load.

Also in the source, exercised where those buildings reach it: column shrink-and-verify after the beam/column loop, whole-section stacking (catalog vector is AbstractSection, not Vector{Any}), grade-wall mats and strips with WallLineDemand.solid (concrete at the base; doors omitted), concurrent footing actions when lateral cases exist (these buildings have none, so the envelope remains, with the group's minimum column for punching).

Not done: directional per-group wall drift. Comparison buildings have no lateral, and the worktree has no update_analysis! remesh, so a thickness jump would record an unchecked wall. Sliding, partial contact, the 25% overturning reduction, Ev=0, the 0.5 L factor, and qa increases stay out. API punching default is still grow_columns. No commit.
