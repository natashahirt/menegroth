---
id: chec-627ecf2d
type: checkpoint
project: menegroth
parent_id: plan-d0c5bff3
title: Upper-floor pin closed; a higher pier base is still free
node_label: Upper-floor pin closed; a higher pier base is stil
tags: walls,phase5,fixity,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a5627bc1
created_at: '2026-10-22T23:11:33.450809+00:00'
updated_at: '2026-10-22T23:11:33.450809+00:00'
---
run-c9e7d58e. wall_node! no longer overwrites dof on a reused frame node. The upper-floor pin is closed: a frame joint at (0, 0, 4) m keeps [true, true, true, false, false, false]. A new node at that base with nothing nearby is fixed. A building with no walls is unchanged. Critic CONCERN, not fixed: only the single lowest wall base is supported, so a separate pier based higher (another wall at 4 m while one exists at 0 m) is a free body with 6 rigid-body modes. Also left: a pier shorter than 1 mm collapses onto its base, and a :walls edge with an empty walls vector still gets a zero frame section and a singular solve. 5c, 5d, and the whole-phase test have not started. Later critics use grok-4.7-high-fast. Code uncommitted.
