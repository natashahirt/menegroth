---
id: deci-1e606b0a
type: decision
project: menegroth
parent_id: plan-fdfcf263
title: 'Picture: no column on a wall, no beams between foundations, no fake deflection
  pass'
node_label: Picture omissions
tags: viewer,scene,deflection,studs,grade
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-bcaa7123
created_at: '2026-11-17T03:36:58.153627+00:00'
updated_at: '2026-11-17T03:36:58.153627+00:00'
---
The picture leaves out two members the solve should not be showing as structure.

A column whose plan point lies on a wall is not drawn. The wall is the support. This is the same case as the parked core corners and the D/A1 pier ends. Columns that do not lie on a wall stay.

A beam with both ends on the support elevation is a beam between foundations and is not drawn. The core office skeleton no longer adds that story-0 grid. It keeps the four edges the ground-story walls claim, and it keeps the grade faces. Those faces are not a designed slab on grade.

A slab deflection of 0 / 0 is the unset default, not a pass of ACI 318-19 §24.2. The card says the check was not run. A computed ratio, including a real zero with a stored limit, is unchanged.

A composite beam whose stored stud layout has no stations says the steel alone meets the shear. No stud positions are invented. The composite floor's deflection mesh stays the solved shells. A frame floor has no slab interior, so none is added. Waffle stress is not invented.

The 1.25 m module staying one-way joists is accepted.
