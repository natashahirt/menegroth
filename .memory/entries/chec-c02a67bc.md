---
id: chec-c02a67bc
type: checkpoint
project: menegroth
parent_id: plan-58b37e3e
title: Spread footings use ASCE 7-22 §2.3 and §2.4
node_label: footing combinations
tags: footing,asce7,foundations,combinations
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-744d7c85
created_at: '2026-11-12T11:52:31.189424+00:00'
updated_at: '2026-11-12T11:52:31.189424+00:00'
---
Spread footings now take one action per ASCE 7-22 combination instead of a single gravity (P, M).

Soil pressure uses §2.4.1 combinations 1a–7a and §2.4.5 combinations 8–10 (asce-7-22, PDF pages 69–70), checked against qa with no allowable-stress increase (§2.4.1, §12.13.6, PDF page 196). Concrete uses the existing §2.3.1 and §2.3.6 strength set (PDF pages 68–69). Eh = ρ QE and Ev = 0.2 SDS D (Eq. 12.4-3 and 12.4-4a, PDF page 183). Ev is applied to the vertical force only, matching the wall combiner (engineering judgment). Contact pressure stays on ACI 336.2R §3.2.1 Eq. (3-1) while q_min ≥ 0 (aci-336-combined-footings-mats, page 6).

Permissions not taken: 0.5 on L, 25% overturning reduction (§12.13.4), Ev = 0 at the soil interface (§12.4.2.2 exception 2(b)). Sliding friction and the partial-contact block are not implemented. Overstrength is not applied to ordinary spread footings. Strip and mat soil pressure is still one demand; that demand's axial and moment are the compressive strength combination with the largest moment. Mat strip coefficients remain blocked.

The ordinary-wall stage stores unfactored support reactions. Foundations are sized again after that stage. A gravity-only call still uses the single demand; the StructurePoint spread reference stayed in range (61 tests passed, including that file).

Worktree row-f-nlp. No file pin: the memory server tracks the main checkout.
