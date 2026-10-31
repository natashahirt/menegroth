---
id: deci-351c8ff9
type: decision
project: menegroth
parent_id: plan-c7b78612
title: A non-rectangular panel uses the existing area shell
node_label: Irregular panels use the existing area shell
tags: slabs,one-way,fea,coefficients
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9a6bddb8
created_at: '2026-10-31T19:57:24.321542+00:00'
updated_at: '2026-10-31T19:57:24.321542+00:00'
has_child_rationale: The panel analysis should accept a non-rectangular plan by reusing
  the two-way shell.
---
Locked 2026-10-31. A solid panel reuses the flat-plate shell. `select_panel_analysis` returns `OneWayMomentCoefficients` only when ACI 318-11 §8.3.3(a)–(e) hold and every face is a rectangle (corpus: aci-318-11, pages 112–113). Anything else, including a skewed or trapezoidal face and every two-way panel, returns `panel_shell()`: `FEA(design_approach=:area, moment_transform=:wood_armer, pattern_mode=:fea_resolve)`. That is the existing per-element shell, not a new mesh.

The rectangle gate is narrower than the sentence of §8.3.3. The clause writes every moment as wu·ln² for one clear span. A non-rectangular face has no single ln, so it is sent to the elastic analysis of §8.3.1.

`_size_slab!` for OneWay and TwoWay records the choice on `design_details` after the minimum thickness. It does not solve the shell or size bars yet. A slab object is one panel, so §8.3.3(a) fails until a continuous line of spans is passed in. The shell is supported on columns, as the two-way model already is. A courtyard is still one boundary loop.
