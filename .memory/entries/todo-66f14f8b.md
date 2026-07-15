---
id: todo-66f14f8b
type: todo
project: menegroth
parent_id: todo-1c39d247
title: D1.1 — NDS 2018 member engine (reference values + adjustment factors + checks)
node_label: 'D1.1: NDS member engine'
tags: todo,timber,nds,member,checker,phase-d
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e98d5a3f
created_at: '2026-07-15T01:16:35.915346+00:00'
updated_at: '2026-07-15T01:16:35.915346+00:00'
has_child_rationale: The core timber capability everything else in D1/B6/C3 depends
  on
---
# D1.1 — NDS member engine

Fill the stub `NDSChecker` (`members/codes/nds/checker.jl`, currently `is_feasible` errors) and the `TimberMemberGeometry` capacity path. Implement NDS 2018: reference design values × adjustment factors (CD, CM, Ct, CL, CF, Cfu, Ci, Cr, CP...) for bending, shear, compression/tension parallel & perpendicular, and combined stress. **Depends on:** E1 (NDS canon). This is the foundation for D1.2–D1.4, A1.4, B6, C3. Validate against an NDS worked example (e.g. a glulam beam).
