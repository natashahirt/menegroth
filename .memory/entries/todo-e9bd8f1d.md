---
id: todo-e9bd8f1d
type: todo
project: menegroth
parent_id: deci-94541642
title: Column optimizer ratio band stays; the failing comparison is the reminder
node_label: Column optimizer ratio band stays; the failing com
tags: column,nlp,tolerance
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e30ece17
created_at: '2026-11-06T11:13:14.123477+00:00'
updated_at: '2026-11-06T11:13:14.123477+00:00'
---
The min-carbon column reinforcement ratio landed at 0.0218 against a min-volume ratio of 0.0206, about 0.001 past the 0.01 band in the NLP-versus-catalog comparison (`result_ec.ρ_opt <= result_vol.ρ_opt + 0.01`). Both sections are valid ACI columns. Leave the comparison and the tolerance as they are. The failing test is the reminder; do not widen the band and do not chase the thousandth.
