---
id: chec-d64b3a09
type: checkpoint
project: menegroth
parent_id: plan-382ddd12
title: 'WS1 checker-side gate GREEN: full StructuralSizer suite 16435 pass (2 pre-existing
  vault errors unrelated); B2-routes-through-is_feasible integration test added'
node_label: 'WS1 checker-side gate GREEN: full StructuralSizer '
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/test/steel_member/test_b1_checker_integration.jl@b89d57f
session_id: sess-4fae1b60
created_at: '2026-11-23T17:59:33.055430+00:00'
updated_at: '2026-11-23T17:59:33.055430+00:00'
---
Gate for the shared RC/steel second-order amplifier (committed 80f0ed43: `_aisc_amplified_forces` core + `is_feasible(...; story=)` routing).

Full `StructuralSizer` suite (`--fresh`): 16435 passed, 0 failed, 2 errored, 2 broken. Steel Members 803/803, Concrete Columns 2112/2112, Optimization 1633/1633 — all green. The 2 errors are in `haile_vault/test_vault.jl` "Vault slab sizing API" (`result_opt === nothing`), pre-existing and unrelated to columns (vault sizing path, not touched by this change).

Byte-identical no-op confirmed: with `story=nothing` and `demand.lt=nothing`, B2=1 and only B1 applies — all 444 pre-existing steel/shared-column tests pass unchanged.

Added `test_b1_checker_integration.jl` testset "B2 (P-Δ sway) amplification routes through is_feasible": AISC Design Examples V15.1 sway story (B2≈1.13); sweeping the lateral-translation moment across the strong-axis flexural boundary, the sway case flips feasible→infeasible (n_flip>0) and never the reverse (n_reverse==0); braced (non-sway) story is byte-identical to no story. Uses raw SI Floats to avoid a Unitful promotion quirk when a LateralTranslation mixes a unitful field with Float64-zero defaults (worth a later fix in the LateralTranslation kw constructor).

Next: WS1 pipeline hand-off (feed story_stability_records + per-column lt split into the member stage) and WS2 DualSystem selection.
