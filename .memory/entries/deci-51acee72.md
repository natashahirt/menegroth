---
id: deci-51acee72
type: decision
project: menegroth
parent_id: plan-73c8dcc7
title: DesignState serializable projection + explanation-layer corpus grounding (Phase
  1 vertical slice on medium_office)
node_label: DesignState + grounding
tags: design-state,corpus-grounding,harness,phase1,serialization,citations,export-seam,safety-critical
status: active
open_threads: 4
success: 'null'
files: StructuralSynthesizer/src/api/design_state.jl@1ffd960, StructuralSynthesizer/src/api/corpus_grounding.jl@1ffd960,
  StructuralSynthesizer/src/api/diagnose.jl@1ffd960, StructuralSynthesizer/src/api/agent_tools.jl@1ffd960,
  StructuralSynthesizer/src/api/_api.jl@1ffd960, StructuralSynthesizer/src/StructuralSynthesizer.jl@1ffd960,
  StructuralSynthesizer/test/core/test_design_state.jl@1ffd960, StructuralSynthesizer/test/runtests.jl@1ffd960
session_id: sess-44762bde
created_at: '2026-07-23T16:47:20.668099+00:00'
updated_at: '2026-07-23T16:49:31.069899+00:00'
has_child_rationale: Phase 1 vertical slice implementation (P0 DesignState + P1 grounding)
---
## What was built

Phase 1 vertical slice of the harness on `medium_office`: a unified, serializable **DesignState** projection (P0) plus **explanation-layer corpus grounding** (P1), behind a domain-agnostic export seam.

### P0 — DesignState (`design_state.jl`)
- DesignState is a **serializable projection/adapter** over `BuildingDesign` + `DesignParameters` + `TraceCollector` + a corpus citation set. It is **NOT a rewrite** of any of those — it reads from them and projects a stable view.
- **Stable ids**: elements keyed by (element type, index); citations keyed by `source:section:clause:check`.
- **Domain-agnostic export seam**: self-describing output with no internal handles (nothing that leaks Julia object identity / internal references). Serialization uses **canonical sorted-key ordering** so the export is content-hashable.

### P1 — Explanation-layer corpus grounding (`corpus_grounding.jl`)
- `ground_check` maps `(CheckResult.name, material-normalized code_clause) -> {source_id, clause, page}`.
- **Material / code-family-safe**: steel -> `aisc-360-16`, RC -> `aci-318-19`, unknown -> `unresolved`. **NEVER cross-family** (a steel check must never resolve to an ACI citation, and vice versa).
- Surfaced through **`/diagnose`** per-check dicts and the **`agent_explain_trace_lookup`** agent tool.

### Corpus-confirmed pages
- AISC 360-16: E1 p33, F2 p47, G2 p70, H1 p77.
- ACI 318-19: §9.5 p133, §22.4 p400, §22.5 p401, §22.6 p411, §24.2 p455.

### Verification
- **172/172 tests pass** (`test/core/test_design_state.jl` added; wired into `runtests.jl`).

## Run metadata
Coordinated run, rigor=medium, extensions_used=2/3. Final: eng + eng_fix + eng_fix2 done; rev3 PASS; crit3 CONCERN (P2-only). All safety P0s resolved.

Agent traces: explore e590b303, eng 44ca76c8, rev e94c6e8d, crit 2d68663c, eng_fix 4ec81af9, rev2 34ca8b3c, crit2 4f50a07c, eng_fix2 c7ddb753, rev3 163f9a3f, crit3 f8108a4a.
