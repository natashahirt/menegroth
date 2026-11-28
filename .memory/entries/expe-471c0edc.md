---
id: expe-471c0edc
type: experiment
project: menegroth
parent_id: plan-ec7031af
title: 'Automorphism-proposer corpus scan: 157/164 plans (96%) carry exploitable symmetry,
  ~3.5x mean beam-orbit collapse; e0c0 confirmed D2 (chirality is a break, not inherent
  asymmetry)'
node_label: Automorphism corpus scan
tags: symmetry,automorphism,proposer,validation,e0c0,chirality,orbits
status: active
open_threads: 0
success: 'true'
files: scripts/runners/plan_symmetry_scan.jl@31b3035, docs/sizing-map/symmetry-policy.md@31b3035
session_id: sess-61ea56aa
created_at: '2026-11-24T16:01:36.051642+00:00'
updated_at: '2026-11-24T16:01:36.051642+00:00'
has_child_rationale: Read-only validation of the geometric proposer across the full
  SDF corpus
---
`scripts/runners/plan_symmetry_scan.jl` (read-only, no analysis/sizing) computes each SDF plan's finite isometry automorphism group of the labeled framing graph (vertices + beam lines + column nodes) and the beam-line orbits.

**Corpus (164 plans, runs in seconds incl. 985-node/2136-line s6-6_drawn):**

| set | plans | with symmetry | groups | mean collapse |
|---|---|---|---|---|
| grid | 36 | 36 | D2:36 | 3.45x |
| nova | 36 | 36 | D2:36 | 3.90x |
| special | 19 | 12 | D2:12, C1:7 | 2.61x |
| star | 37 | 37 | D2:37 | 3.65x |
| topology | 36 | 36 | D2:34, D1:2 | 3.47x |
| total | 164 | 157 (96%) | - | ~3.5x |

**Findings:**
- 96% of plans carry exploitable symmetry; ~3.5x mean reduction in distinct beam-sizing problems (orbits vs lines) = the speed-win proxy.
- Max group is D2 (two mirrors + rot180). No C4/D4 because footprints are rectangular (non-square), so 90deg rotation isn't a symmetry. The C2/C4 non-axial cases (architecture.md 7) are latent, not present in this corpus.
- **star/e0c0 resolves to D2 including its column set** -> the converged chirality is a genuine symmetry BREAK (path-dependence), not inherent asymmetry. Confirms the premise of the whole policy (consistent with find-667f5187 bistability).
- The 7 asymmetric (C1) plans are all named real-world layouts (school, weber_1*, tan_121_seaport, topopt_test2); proposer correctly finds no symmetry -> policy falls back to per-member sizing (no-op guarantee).
- topology/r8c1, r8c3 are only D1 (single mirror, collapse ~1.9x) - partial-symmetry weird cases.

**Production-detector port notes:** seed candidates from the farthest-vertex orbit (O(n) rotations+reflections); verify each by vertex bijection AND label (line+column) preservation; **normalize signed zero in the match key** - Julia Dict treats -0.0 and 0.0 as distinct (isequal(-0.0,0.0)===false), so a mirror landing a centerline vertex on -0.0 silently fails lookup (this bug hid every real symmetry until fixed).

**Next:** fingerprint (demand-based) proposer needs one analysis pass per plan; cross-check its demand-classes against these geometric orbits on a handful of plans, then wire orbit broadcast + per-element verify into the beam sizing path, starting with e0c0.
