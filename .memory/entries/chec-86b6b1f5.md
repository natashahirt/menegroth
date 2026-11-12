---
id: chec-86b6b1f5
type: checkpoint
project: menegroth
parent_id: plan-c431a82d
title: SDC D–F started at §18.14.5, column ℓo
node_label: §18.14.5 slab shear
tags: aci-318,18.14,sdc,deformation-compatibility
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0bc6ec9a
created_at: '2026-11-12T02:35:08.852327+00:00'
updated_at: '2026-11-12T02:35:08.852327+00:00'
---
Overnight slice of deformation compatibility. The SDC D–F throw stays: §18.14.3.3 still requires §18.2.5–18.2.8, §18.6.5 on gravity beams, §18.7.4–18.7.6 on columns, and §18.4.4.1 on joints, and those member designs are not applied.

Coded from the rendered pages:
- gravity_slab_column_shear. §18.14.5.2 is checked first: drift at or below 0.005 (nonprestressed) or 0.01 (post-tensioned with fpc meeting §8.6.2.1) does not require slab shear reinforcement. Above that, reinforcement is required when Δ/h is at least 0.035 − vuv/(φvc)/20, or 0.040 − that ratio for a qualifying post-tensioned slab. Equality of the line requires it. vs is at least 3.5√f′c and the steel extends 4h. A post-tensioned slab that misses §8.6.2.1 uses the nonprestressed line, which R18.14.5.1 permits. Corpus aci-318-19, PDF pages 354–355.
- special_column_hoop_length. ℓo is the greatest of the column depth, the clear span over 6, and 18 in. §18.7.5.1, PDF page 309. This is the length only. It does not satisfy §18.7.4, §18.7.5.2–4, or §18.7.6.

Special-boundary tests 388/388. Not committed.
