---
id: todo-4f1bd251
type: todo
project: menegroth
parent_id: plan-a4de4826
title: 'Deferred: γf transfer steel still omits governing Muy at edges'
node_label: 'Deferred: γf transfer steel still omits governing '
tags: punching,transfer-steel,deferred
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-fd4c0ecb
created_at: '2026-09-23T03:48:26.572192+00:00'
updated_at: '2026-09-23T05:08:07.461966+00:00'
---
Critic P1: γf transfer steel at the 20×30 20-ft free-edge column is still sized from primary Mux≈23 kip-ft while γv punching now uses Muy≈130 kip-ft (ACI 318-11 §13.5.3.1). Production oracles never instantiate an :edge column. Kernel punching Muy for :edge/:interior is reviewed PASS and tested PASS. Deferred past coordinator soft cap; pick up in eng_reported or a follow-up.
