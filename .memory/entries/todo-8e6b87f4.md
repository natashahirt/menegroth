---
id: todo-8e6b87f4
type: todo
project: menegroth
parent_id: plan-3c17cdf6
title: Per-case beam NLP and column NLP section floors
node_label: Beam and column NLP later
tags: nlp,beams,columns,section-floors,later
status: active
open_threads: 4
success: 'null'
files: ''
session_id: sess-d09eb230
created_at: '2026-11-11T11:25:31.476302+00:00'
updated_at: '2026-11-13T14:46:16.858499+00:00'
has_child_rationale: User asked to keep beam and column NLP in mind for later while
  landing the Row F commit.
---
Do this after the Row F commit lands. Two leftovers from plan-b231dcef:

1. Beam NLP still sizes the moment envelope. Column NLP now constrains every load case; beams should get the same treatment when that work starts.
2. Column NLP still refuses a Row F section floor. Discrete concrete sizing honors the floor. The NLP path should keep the floor or a heavier section once that is designed.

No new code equations. Reuse the existing ACI checks.
