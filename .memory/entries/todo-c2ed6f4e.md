---
id: todo-c2ed6f4e
type: todo
project: menegroth
parent_id: plan-93430266
title: 'D4: harmonize_uniform_column_sizes! early-return under grouping'
node_label: 'D4: harmonize_uniform_column_sizes! early-return u'
tags: wave-3, d4, harmonize, todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4eeb9160
created_at: '2026-07-19T18:14:52.803784+00:00'
updated_at: '2026-07-19T18:14:52.803784+00:00'
---
When grouping is active AND grouping already delivered max(c1)×max(c2) propagation, harmonize's post-processing is redundant. Add early-return returning 0. Guard MUST not fire when grouping is :off.
