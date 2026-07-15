---
id: deci-4cb9a28d
type: decision
project: menegroth
parent_id: plan-f6511c0b
title: Launch Phase B build (beam overrides live via batched size_beams!); defer guard-placement
  P1 to Phase B
node_label: Launch Phase B build (beam overrides live via batc
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-86aa5f77
created_at: '2026-07-15T10:16:31.932972+00:00'
updated_at: '2026-07-15T10:16:31.932972+00:00'
---
User left recommendations standing (skipped the decision prompt). Decisions:
1. Guard placement (critic P1): DEFER to Phase B. Phase B removes the fail-loud guard for the now-honored beam path, so re-decide placement there; leave the constructor guard as-is in the interim (no live in-repo break).
2. Launch the Phase B build coordinator run now, high rigor, exact-first-gated.

Phase B build scope (per recon deci-a0f4d98f): keep :members as ONE atomic fixpoint node; thread resolve_member_group_override(params, gid) into the BATCHED size_beams! per-group catalog/deflection/max_depth (NOT via size_member_group!, which uses optimize_binary_search and is not byte-identical to size_beams!/optimize_discrete); make the guard CONDITIONAL — still fail-loud for un-honorable override targets (column groups; any group on flat-plate/flat-slab floors) while allowing beam-group overrides on beam/column floors; re-gate exact-first (override-free byte-identical; effective-override design_building-from-scratch == incremental-engine, plus a direct assertion that a catalog-restricted group is sized to the restricted section). Defer column-MIP split + flat-plate overrides. Known implementation risk to verify first: whether StructuralSizer.size_beams/optimize_discrete accepts PER-GROUP catalogs or only a global catalog (may require a minimal exact-first-safe API extension).
