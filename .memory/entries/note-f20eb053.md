---
id: note-f20eb053
type: note
project: menegroth
parent_id: plan-051e653d
title: Prep step 2 (baseline re-seed) is gated on external/Asap SHA stabilizing —
  joist plan's k_joist work will drift FEA(frame) numerics
node_label: Prep step 2 (baseline re-seed) is gated on externa
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1d08c27d
created_at: '2026-07-23T19:29:52.425480+00:00'
updated_at: '2026-07-23T19:29:52.425480+00:00'
---
Reading the joist plan (plan-ad399e86) revealed that `external/Asap` currently has extensive dirty edits to `src/Elements/K.jl`, `src/Elements/R.jl`, `src/Analysis/force_displacement.jl`, `src/Elements/elements.jl`, `src/Elements/spring.jl`, `src/Loads/utilities.jl`, `src/Dynamics/{mass,modal}.jl`, `src/Elements/shell/{composite,meshing}.jl`. This is the k_joist element stiffness kernel + supporting infrastructure that todo-f82c296c ('Resolve Asap k_joist element stiffness kernel') calls for.

Historical precedent: Wave 1B (chec-fb39015c) already saw peer-Cursor Asap drift block bit-identical verify on FEA(frame); baseline.csv had to be regenerated afterward (deci-4f329ae6). The current dirty Asap edits will trigger the same numerical drift on the FEA(frame) row of the flat-plate validation matrix.

Implication for our sequenced plan:
- Prep step 2 (re-seed baseline.csv) MUST wait until the joist thread commits its `external/Asap` changes and the SHA is fixed. Re-seeding against a still-drifting Asap gives us a baseline that will be invalidated the next time the joist thread edits.
- Pillar 2 (A-series) coordinator wave should NOT launch on the current tree either — A2/A3/A4/A5 rely on invariant gates against baseline, and any drift will show up as false positives.
- Pillar 1 (Run 6 warm-state) is already landed (f9070e1a) and verified against gen_medium_office (a flat plate with no joist framing) — so the Run 6 commit itself is safe regardless of Asap drift because the joist code path isn't entered on flat plates.

Action on resume:
1. Check `git submodule status external/Asap` — if clean and pointing at a new committed SHA in the peer's Asap branch, proceed.
2. Re-run `scripts/runners/verify_warm_state_incremental.jl` against the new Asap SHA to confirm Run 6 still 12/12 (it should — we're not on a framed building).
3. Re-seed baseline via the flat-plate speedup validation harness on the new base.
4. Only THEN design the Pillar 2 (A-series) coordinator wave.
