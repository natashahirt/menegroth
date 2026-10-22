---
id: deci-9d025c3f
type: decision
project: menegroth
parent_id: plan-d0c5bff3
title: Wall shells move with the building; the mesher adds no supports
node_label: Wall shells move with the building; the mesher add
tags: walls,phase5,fixity,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a5627bc1
created_at: '2026-10-22T23:18:02.836427+00:00'
updated_at: '2026-10-22T23:18:02.836427+00:00'
---
User correction during run-7675fca5, before the per-pier base fixity landed as the intended behavior. Wall shells do not receive supports from the mesher. A wall moves with the building: it reuses frame and diaphragm nodes within 1 mm and keeps those nodes' existing dof. A foundation support stays fixed because the frame node is a support. A floor joint stays free. A node the wall mesh creates is free. Do not fix a created node because it lies on a pier base, including an isolated pier that starts above another wall. A wall that meets no structural node is not given an invented support.
