---
id: deci-c1c2249a
type: decision
project: menegroth
parent_id: plan-02c6d260
title: Drift gravity load read literally; drift Cs drops the Eq. 12.8-6 floor; NEHRP
  2020 examples as oracles
node_label: drift loads + Cs floor
tags: asce-7-22,phase-6,seismic,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6cc8372b
created_at: '2026-10-25T13:38:54.718408+00:00'
updated_at: '2026-10-25T13:38:54.718408+00:00'
---
User decisions 2026-10-25.

1. ASCE 7-22 §12.8.6.1 (PDF 187) read literally: expected gravity loads no less than 1.0D + 0.5L, where L = 0.8L0 for live loads exceeding 100 lb/ft² and 0.4L0 otherwise. So 1.0D + 0.4L0 or 1.0D + 0.2L0. Px for Eq. 12.8-18 uses these loads.

2. For computing drift, Eq. 12.8-6 is not applied (§12.8.6.1 Exception; C12.8.6.1 says 12.8-6 is a minimum strength and 12.8-7 still applies). Strength keeps both floors. User asked for the most code-correct option; this is the code's stated permission, not a conservatism choice.

3. Published oracles: nehrp-2020-design-examples-v1 (written to ASCE 7-22). Example 4 PDF 146–148 (Cs, V) and Example 5 PDF 191–194 (k, Cvx, Fx, Vx), with T unrounded (CuTa). Example 5's printed V = 1,238 kips uses the Eq. 12.8-4 value 0.0479; the Eq. 12.8-6 floor 0.0484 governs under 7-22, giving 1,252 kips, so that V is not an oracle for Cs. Example 4 prints Eq. 12.8-6 with 0.65 instead of SDS = 1.10. No numeric torsional amplification example exists in this volume; Ax stays on hand checks.
