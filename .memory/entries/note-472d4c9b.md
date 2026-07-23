---
id: note-472d4c9b
type: note
project: menegroth
parent_id: deci-51acee72
title: Outstanding P2 follow-ups from Phase 1 slice (deferred by design, non-blocking)
node_label: P2 follow-ups
tags: p2,follow-up,deferred,engineering-review,determinism,citation-registry
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/api/diagnose.jl@1ffd960, StructuralSynthesizer/src/api/design_state.jl@1ffd960,
  StructuralSynthesizer/src/design/design_workflow.jl@0c6c391
session_id: sess-44762bde
created_at: '2026-07-23T16:48:48.212450+00:00'
updated_at: '2026-07-23T16:48:48.212450+00:00'
has_child_rationale: Deferred non-blocking items surfaced during the slice
---
Three P2 items surfaced during the slice. None block Phase 1; deferred by design.

**(a) Steel-column axial citation potentially UNCONSERVATIVE (worth separate engineering review).** In `diagnose.jl`, the steel-column axial check comment calls `phi*Pn = 0.9*Fy*Ag` "conservative", but ignoring flexural buckling makes it **unconservative** vs AISC 360-16 §E3. `E1` is cited where `E3` (flexural buckling) is the true governing limit state. This is a **pre-existing modeling simplification** in `design_workflow.jl:1839-1842` that the citation work merely *surfaced* — potentially a real engineering issue beyond the harness slice. At minimum, correct the misleading "conservative" wording; ideally review the limit state.

**(b) Non-deterministic content hash from baked-in timestamp.** `design_state.jl` bakes `generated_at = string(design.created)` into the export whose entire purpose is a deterministic content hash → two identical designs produced at different times hash differently. Move the timestamp out of the hashed portion (or exclude it from the canonical serialization).

**(c) Latent last-writer-wins in the shared citation registry.** Verbatim clause/edition text in the shared citation registry can be overwritten last-writer-wins. **Unreachable today** — emitters use one fixed spelling per family — but latent if a family ever emits two spellings.
