---
id: plan-a4de4826
type: plan
project: menegroth
parent_id: plan-a0000001
title: 'Foundation safety corrections: fix demand-information-loss defects before
  ribbed-floor work'
node_label: Foundation safety corrections
tags: safety,audit,signed-moments,pattern-loading,punching,ddm,fea,aisc,aci,foundations
status: active
open_threads: 14
success: 'null'
files: ''
session_id: sess-bff66da0
created_at: '2026-09-23T01:51:38.762000+00:00'
updated_at: '2026-09-28T17:26:20.578548+00:00'
---
Audit (2026-09-22) of existing demand extraction and checkers for the bug class found with T-beams: information (sign, concurrency, load pattern, boundary condition) is lost before a check whose answer depends on it.

Scope: 8 verified unconservative defects (fix), 7 reported items (verify, then fix or reclassify). Each fix gets a hand-calc oracle test. Lands before Phase 0 of the ribbed-floor plan; items 1 (signed moments), 2 (patterns), 5 (FEA envelope), 7 (signed Nu) gate rib sizing.

Plan file: ~/.cursor/plans/foundation_safety_corrections_8f36d4fe.plan.md
