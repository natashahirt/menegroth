---
id: todo-9482afeb
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 11 — Production verification, reporting, docs
node_label: 'P11: production verify'
tags: walls,phase,verification,report,docs,todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f764d548
created_at: '2026-10-21T02:13:35.510362+00:00'
updated_at: '2026-10-21T02:13:35.510362+00:00'
---
Expand test_walls.jl (multistory, skew, accidental-torsion sensitivity, singular-layout, non-default steel, unified-model, openings, §18.10, optimizer-survivor). Upgrade test_walls_report.jl into an auditable system report (source clauses, oracles, load cases, model assumptions, deferred scope). Add cold-vs-warm equivalence + performance benchmarks for each invalidation class with budgets from measured baselines. Run both package suites at integration milestones; docs updated only after correctness + exact-first + performance + citation checks pass.
