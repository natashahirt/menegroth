---
id: note-fd485a38
type: note
project: menegroth
parent_id: plan-a4de4826
title: 'Defect 3: DDM exterior unbalanced moment uses M_neg_ext instead of 0.3 Mo
  (ACI 318-11 13.6.3.6)'
node_label: D3 DDM Mub 0.3Mo
tags: safety,ddm,punching,aci-318-11
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl@d70bce4
session_id: sess-611942f9
created_at: '2026-09-23T01:51:52.834219+00:00'
updated_at: '2026-09-23T01:51:52.834219+00:00'
---
ddm.jl:562-564 and 617-623 set Mub = M_neg_ext for exterior columns. ACI 318-11 13.6.3.6 (aci-318-11 p.255) requires 0.3 Mo transferred to edge columns. Flat plate without edge beam: M_neg_ext = 0.26 Mo (13.6.3.3 p.254), so transfer is understated ~13%.
