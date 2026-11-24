---
id: plan-ec7031af
type: plan
project: menegroth
parent_id: plan-a79eb74f
title: 'Symmetry-aware sizing: propose-verify policy (size one representative per
  equivalence class, verify every element at its own demand). Fixes path-independence
  (e0c0 chirality) + speed win; general across beams/columns/slabs'
node_label: 'Symmetry-aware sizing: propose-verify policy (size'
tags: ''
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/symmetry-policy.md@a25a173
session_id: sess-61ea56aa
created_at: '2026-11-24T15:47:58.853435+00:00'
updated_at: '2026-11-24T15:47:58.853435+00:00'
---
Scoping doc: docs/sizing-map/symmetry-policy.md (registered). Scoping only — NO implementation started.

CORE IDEA (maps onto architecture.md): symmetry grouping is a named, switchable POLICY (arch §3/§7); the per-element check is the VERIFIER (arch §7 trust anchor). Loop: propose equivalence classes (orbits) -> class demand = elementwise MAX envelope over the class -> size ONE representative per class on the envelope -> broadcast its section to all class members -> VERIFY every element independently at its OWN final demand -> split-on-fail (a failing element leaves its class, sized alone). Because the final gate is always the real per-element check, a wrong equivalence guess can never produce an UNSAFE design (worst case: slightly conservative or a little rework). This delivers architecture.md §1 property (2) path-independence and kills chirality for ALL symmetric plans, not just e0c0.

EQUIVALENCE is on the SIZING PROBLEM, not geometry: plan symmetry does NOT imply equal demands (pattern LL per ACI 318-11 §6.4/§13.7.6, lateral direction, one-way span/rib direction all break it). Two pluggable PROPOSERS: (1) automorphism = plan's finite isometry group (elegant/explanatory, pre-demand); (2) sizing-fingerprint = elements whose demand-envelope+span+BC+catalog match within tol (correctness-complete by construction, catches grid bays). Use automorphism to propose+explain, fingerprint to confirm before sizing.

PLAN AUTOMORPHISM DETECTOR difficulty: geometric core EASY (~1-2d; centroid-fixed rotations+reflections, O(n^2) candidates, O(n log n) verify, n~25-200 -> ms; yields C1/C2/C4/D1/D2/D4...). Catches NON-axial symmetry: e0c0's true invariant is the C2 rotation about the hub (why NE=SW, NW=SE pair), plus Cn pinwheels and (with a translational extension) repeated grid bays = biggest speed win. Semantic-intersection with stabilizer of columns/walls/holes/perimeter/framing-level/span-direction/releases/supports + load-invariance = MODERATE (~1wk). Overall risk LOW thanks to the verifier backstop.

SCOPE: general across beams/ribs + columns + slabs (design the relation once, apply per family). Correctness first, speed second. v1 OUT: asymmetric lateral as a symmetry basis; near-symmetry as a TRUSTED signal (only ever a proposer); default-on before benchmarks prove no loss of verification.

INTERACTIONS: compose with build_member_groups!/member_group_demands (merge orbit into one group vs class layer above groups - open); collinear rib sharing already enforces C2 pairing via order-independent maximum (find-7f0166a7); solid heads/frame floors/releases must be class-shared; canonical lowest-index representative + order-independent envelope (matches the check_settle.jl + optimize_discrete tie-break fixes already landed).

PHASING: (1) relation+verifier loop, beams first (fingerprint proposer; prove path-independence on e0c0 + no-op on asymmetric plans); (2) automorphism detector as explanatory proposer, cross-checked vs fingerprint; (3) generalize to columns+slabs; (4) translational/local congruence for grid speed; (5) default-on only after benchmarks.

MOTIVATION/ROOT CAUSE pinned in find-ae3ab0d2 (e0c0 seed = deterministic sub-permille mesh/tributary asymmetry, threshold-amplified) and find-667f5187 (bistable, FEA bit-exact covariant). Two principled covariance fixes already landed (check_settle.jl _pick_group_section + mix-first settle; optimize_discrete canonical tie-break) but neither is the e0c0 carrier.

OPEN QUESTIONS: merge-into-group vs class-layer; strict max envelope vs concurrent-case-aware demand sets (arch §4); automorphism tolerance (exact vs near); symmetry as fast-tier accelerator vs full-tier policy vs both (arch §5).
