---
id: deci-ad71f506
type: decision
project: menegroth
parent_id: plan-396a2056
title: Greenfield APIs use one canonical contract without compatibility aliases
node_label: Greenfield APIs use one canonical contract without
tags: architecture,greenfield,api-contracts,normalization,no-compatibility-aliases
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-16793e2a
created_at: '2026-10-29T16:12:59.190896+00:00'
updated_at: '2026-10-29T16:12:59.190896+00:00'
has_child_rationale: User confirmed the canonical-contract standard and explicitly
  rejected compatibility aliases for this greenfield codebase.
---
For current architecture cleanup, overwrite callers and tests to use the canonical API rather than retaining old-name compatibility aliases. Public package boundaries should normalize input once, use explicit validation errors, and keep private helpers private. Broad god-file decomposition remains deferred until contract cleanup and active wall/floor work are complete.
