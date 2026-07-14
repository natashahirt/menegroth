---
id: todo-d60c65c0
type: todo
project: menegroth
parent_id: plan-68155c81
title: A2 — Composite & non-composite steel-deck floor analysis/sizing
node_label: 'A2: Steel-deck floors'
tags: todo,composite-deck,metal-deck,aisc-i,sdi,floors,phase-a
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2595ad50
created_at: '2026-07-14T01:34:57.301061+00:00'
updated_at: '2026-07-14T01:34:57.301061+00:00'
has_child_rationale: The DOE steel-office workhorse floor; deck types currently error
---
# A2 — Composite & non-composite steel-deck floors

The steel-office standard floor is composite metal deck on steel beams/joists. `CompositeDeck` and `NonCompositeDeck` floor types exist but their sizing paths `error(...)` (`slabs/codes/steel/composite_deck.jl`, `non_composite_deck.jl`). We already have **AISC 360-16 Ch. I composite beams** (`members/codes/aisc/composite/`) — this todo builds the **deck/slab** half and wires it to the composite-beam path.

**Build:** SDI-based deck profile capacity (form deck vs composite deck), concrete-on-deck slab bending/one-way shear, stud-driven composite action shared with the Ch. I beam checker, deck-as-diaphragm hook (feeds Phase A4).

**Depends on:** Phase E5 (SDI deck manuals + profile catalog). **Couples to:** A1 (joists as the supporting member) and Phase C2 (roof deck).
