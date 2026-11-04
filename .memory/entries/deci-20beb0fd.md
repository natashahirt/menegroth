---
id: deci-20beb0fd
type: decision
project: menegroth
parent_id: plan-b0000001
title: Align root/StructuralSizer/StructuralStudies manifests to StructuralSynthesizer's
  (shipped) versions; full Sizer suite identical before/after
node_label: Manifest alignment
tags: testing,precompile,manifest,dependencies
status: active
open_threads: 0
success: 'null'
files: scripts/runners/align_manifests.jl@e5a0c12, scripts/runners/compare_manifests.jl@e5a0c12,
  Manifest.toml@e5a0c12, StructuralSizer/Manifest.toml@e5a0c12, StructuralStudies/Manifest.toml@e5a0c12,
  AGENTS.md@e5a0c12
session_id: sess-370f492d
created_at: '2026-11-04T17:09:35.111677+00:00'
updated_at: '2026-11-04T17:09:35.111677+00:00'
---
## Problem
21 registered packages resolved to different versions across the four manifests, so each env built its own cache of every dependent package (StructuralSynthesizer cache dir had grown to 3.4 GB). Notably standalone StructuralSizer tested against ForwardDiff 0.10 / Zygote 0.6 / MathOptInterface 1.48 / JSON 0.21 / IntervalArithmetic 0.20 while the shipped StructuralSynthesizer env uses ForwardDiff 1.3.2 / Zygote 0.7.10 / MOI 1.49 / JSON 1.4 / IntervalArithmetic 1.0.2. Root/Studies had HiGHS 1.21.0 vs 1.20.1.

## Decision
StructuralSynthesizer/Manifest.toml is the reference (it is what the API image ships, so nothing shipped changes); packages it lacks follow the root manifest. `scripts/runners/align_manifests.jl` moves mismatches (temporarily adding indirect deps at exact versions, then removing them; restores the original Project.toml bytes so CRLF/compat are untouched). `scripts/runners/compare_manifests.jl` reports mismatches (exit 1). Stdlibs are ignored (they follow the running Julia). User chose this over a Julia 1.12 [workspace] because a shared manifest would pull GLMakie etc. into the API Docker image.

## Verified
A/B full StructuralSizer suite (fresh process) with old vs new Sizer manifest: identical 8584 pass / 1 fail / 1 error / 2 broken; the failing value is bit-identical. Both are pre-existing in the working tree: walls S3 oracle torsion 1.0018609 vs 1.0 atol 1e-3 (test_walls.jl:655), and slabs/test_fea_mesh_key.jl does `using StructuralSynthesizer` (not in Sizer env) -> LoadError aborts the remaining Slabs includes. Deleted stale Structural* caches (~3.7 GB).
