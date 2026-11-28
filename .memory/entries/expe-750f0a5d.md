---
id: expe-750f0a5d
type: experiment
project: menegroth
parent_id: deci-8c540598
title: Core office v5 designs the walls at the parked core corners
node_label: Core office v5 designs the walls at the parked cor
tags: core-office,absent,v5,tributary
status: active
open_threads: 1
success: 'true'
files: ''
session_id: sess-07777c90
created_at: '2026-11-08T16:11:14.549659+00:00'
updated_at: '2026-11-08T20:33:44.648581+00:00'
---
v5 is logs/core_office_v5.mgdesign and logs/core_office_v5.mgscene. v2, v3, and v4 were left in place. The viewer copies are the v5 files.

The first design attempt stopped in to_asap!. initialize_members! treated every edge outside :walls, :columns, and :braces as a beam, so the sixteen parked stacks became beams. Their frame section is the zero wall section, and a released beam with zero I cannot be condensed (SingularException in k_freefree). An :absent edge now keeps its segment and becomes no member. An edge in :absent and also in another member group throws.

The rerun exited after writing both files. 48 column segments, 48 frame elements, 4 slabs, 52 walls, 13 footings. The wall-thickness jump reports a 0.4826 m target. A corner column sat at the 30 inch maximum with a punching ratio near 1.69, and the slab thickness was raised to 11.5 inch. The mat bearing warning is util=1.0. Max displacement 26.92 mm.
