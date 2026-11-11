---
id: plan-e4416ee2
type: plan
project: menegroth
parent_id: todo-7dfc3edf
title: Pre-cure demand uses the bare-steel tributary solve the unshored stage already
  has
node_label: Pre-cure demand uses the bare-steel tributary solv
tags: ''
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-03a06543
created_at: '2026-11-05T01:42:41.216740+00:00'
updated_at: '2026-11-05T02:46:52.924235+00:00'
---
The §I3.1b check already exists (SEI/ASCE 37-02 Eqs. 2-2 and 2-3). It does not follow the rest of the composite path: after the first sizing pass the frame elements are composite children, and beam_pre_cure_shape still reads the parent edge, so the analysis shape is dropped and the check falls back to wL^2/8. The solve also uses whatever stiffness is on the model, while unshored deflection swaps back to the stored steel section.

Plan: one bare-steel section swap, shared with the unshored stage. Pre-cure extrema come from the child elements that carry the tributary loads. A uniform width keeps the existing w/w_ref scale. A varying width at one pressure scales the area-load moment by pressure and adds the candidate steel weight from a unit line-load solve on that same steel model. A load that is not a single tributary pressure keeps the simple span.
