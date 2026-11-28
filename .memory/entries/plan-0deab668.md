---
id: plan-0deab668
type: plan
project: menegroth
parent_id: plan-396a2056
title: Normalize package-boundary contracts and lifecycle ownership
node_label: Boundary contracts
tags: architecture,contracts,lifecycle,asap,floors,walls,greenfield
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-8ea26ef9
created_at: '2026-10-29T20:02:44.781902+00:00'
updated_at: '2026-11-19T21:27:10.878661+00:00'
has_child_rationale: Confirmed migration plan following the multi-round architecture
  audit.
---
Migrate package boundaries in seven waves: (1) add typed statuses, outcomes, diagnostics, and installability; (2) prove the pattern on floor sizing with immutable FloorDesignRequest/Result contracts and loud unsupported dispatch; (3) make StructuralSynthesizer install slab/support changes transactionally; (4) give Asap explicit source-realization maps, owned invalidation operations, and typed static results; (5) apply Unitful request/result contracts to wall checks while retaining the reduced analytical kernel; (6) atomically remove compatibility aliases, broad reexports, private cross-package calls, silent defaults, and reflection-based fallbacks; (7) split wall/floor orchestration, analysis, and design god files only after boundaries stabilize. Preserve engineering equations during contract extraction and verify each wave with parity, failure-atomicity, invalidation, and full package tests.
