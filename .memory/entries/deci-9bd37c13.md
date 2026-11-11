---
id: deci-9bd37c13
type: decision
project: menegroth
parent_id: plan-a7ebaacc
title: 'Irregular-geometry fixes: shared stages, clear span, framed openings, vaults
  warn-only'
node_label: Geometry fix decisions
tags: irregular-geometry,openings,clear-span,vault,testing
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6c035a0d
created_at: '2026-11-11T03:21:17.950909+00:00'
updated_at: '2026-11-11T03:21:17.950909+00:00'
has_child_rationale: User decisions that govern the overnight audit-fix pass
---
User (2026-11-10), after the seven-audit irregular-geometry review:

- Clear span for flat-plate minimum thickness is the maximum span across the cell along the reinforcement axis, or the longer of the two axes when the slab is reinforced both ways. Use the existing span measures; do not invent a diagonal.
- Unframed openings are modelled, system by system, with trimmers/headers and cantilever checks. Every system warns. Do not silently ignore an opening and do not refuse the whole floor.
- Vaults are the exception for now: warn that the opening is not framed and is not in the vault check. Proper vault opening treatment comes later.
- Fixes go in as shared pipeline stages (hole accounting, span axis, support condition, opening framing), not one-off patches inside each floor system.
- Each wave ships tests that check correctness and sensitivity: changing span, opening size, rotation, or support condition must move the result in the expected direction, and a second pass over the same geometry must not change it.

Work proceeds autonomously through the audit waves.
