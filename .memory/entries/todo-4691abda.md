---
id: todo-4691abda
type: todo
project: menegroth
parent_id: plan-1b964170
title: B7 — One-way joist / pan-joist (ribbed) slab (ACI 318 §8.13 / 318-19 §9.8)
node_label: 'B7: One-way pan-joist'
tags: todo,one-way-joist,pan-joist,ribbed,aci,slab,phase-b
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-312c228d
created_at: '2026-07-15T01:41:32.432077+00:00'
updated_at: '2026-07-15T01:43:06.935907+00:00'
has_child_rationale: One-way ribbed pan-joist construction is a distinct system with
  no type or todo today (only solid OneWay and two-way Waffle exist)
related_to: todo-8f5ba09e
---
# B7 — One-way joist / pan-joist (ribbed) slab

**Gap identified 2026-07-14.** `slabs/types.jl` has solid `OneWay` and two-way `Waffle`, but **no one-way ribbed / pan-joist type** — the standard-pan (20–30″ forms) one-way rib-and-slab floor common in parking, schools, and long-span office. It currently has nowhere clean to live (falls between B1 and B3).

**Corpus-grounded scope** (verified against `aci-318-11` §8.13, PDF p.120): joist construction = monolithic regularly-spaced ribs + top slab spanning **one** direction; ribs ≥ 4 in. wide, depth ≤ 3.5× min rib width (§8.13.2), clear rib spacing ≤ 30 in. (§8.13.3), and V_c may be taken 10% higher than Ch. 11 (§8.13.8). In ACI 318-19 this is **§9.8** (one-way joist systems). Reconcile edition per Phase E8 before implementing.

**Build:** add a `OneWayJoist` (or `PanJoist`) `AbstractConcreteSlab` with `OneWaySpanning`; rib as a one-way T-beam (top slab flange) + distribution ribs; flexure/shear/deflection per ACI beam provisions with the §8.13 rib geometry limits and the §8.13.8 V_c bonus. Reuse the existing ACI T-beam checker (`members/codes/aci/beams/`). **Couples to:** B1 (top-slab one-way action), B3 (shares rib mechanics). No new canon needed (ACI 318 in corpus).
