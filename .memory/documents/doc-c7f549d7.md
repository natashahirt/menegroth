---
id: doc-c7f549d7
path: docs/sizing-map/symmetry-policy.md@a25a173
title: 'Symmetry-aware sizing: a propose-verify policy'
description: 'Scoping/design doc: detect elements whose sizing problem is identical
  up to a symmetry, size one representative per equivalence class on the class demand
  envelope, broadcast, then verify every element independently at its own demand (split-on-fail).
  Symmetry grouping = a named Policy; per-element check = the Verifier (architecture.md
  trust anchor). Covers the plan automorphism detector (difficulty + non-axial C2/Cn/translational
  symmetry), the two proposers (automorphism + sizing-fingerprint), general scope
  across beams/columns/slabs, interactions, validation, and phasing. Fixes e0c0 chirality
  (path-independence) and is a speed win.'
project: menegroth
status: active
created_at: '2026-11-24T15:48:15.865484+00:00'
links_to: plan-ec7031af
---
Scoping/design doc: detect elements whose sizing problem is identical up to a symmetry, size one representative per equivalence class on the class demand envelope, broadcast, then verify every element independently at its own demand (split-on-fail). Symmetry grouping = a named Policy; per-element check = the Verifier (architecture.md trust anchor). Covers the plan automorphism detector (difficulty + non-axial C2/Cn/translational symmetry), the two proposers (automorphism + sizing-fingerprint), general scope across beams/columns/slabs, interactions, validation, and phasing. Fixes e0c0 chirality (path-independence) and is a speed win.
