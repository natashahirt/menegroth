---
id: deci-a2d5874e
type: decision
project: menegroth
parent_id: plan-a79eb74f
title: 'Design trace map: multi-resolution flowchart of how a design moves through
  the code, generated from one graph and checked against runtime traces'
node_label: Design trace map
tags: sizing,trace,flowchart,documentation,llm-navigation,explainability,decision
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/plan.md@4fdc2db
session_id: sess-ee879530
created_at: '2026-11-13T15:56:29.972330+00:00'
updated_at: '2026-11-13T15:56:29.972330+00:00'
---
User 2026-11-13: wants a flowchart representation of how designs pass through the code, multi-resolution (building -> stages -> elements -> checks), showing element split, dependencies, checks, loops; valuable for humans and LLMs. Decision (plan.md Workstream T): one machine-readable graph (typed nodes and edges, stable ids across levels L0-L3), Mermaid generated per level; anchors are function names, not line numbers, with an anchor-resolution test; runtime coverage test against SizingProbe/TraceCollector labels on B1-B7; per-run overlay giving each element's size-provenance chain, feeding the scene component dossier; as-is map first (built in the re-audit together with F.1), target structure after Phase 2. Builds on deci-h0000010 (trace infrastructure), plan-66282b2f (Design Harness / DesignState) and plan-03b90f0a (component dossier).
