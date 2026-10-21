---
id: deci-0bd60d85
type: decision
project: menegroth
parent_id: plan-b2670c25
title: 'Final fix round scope: judgment-call resolutions, full suites, trace audit,
  later citation sweep'
node_label: 'Final fix round scope: judgment-call resolutions, '
tags: eq-13-7,engineering-judgment,scope
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-28fbc0d3
created_at: '2026-10-21T02:02:39.219077+00:00'
updated_at: '2026-10-21T02:02:39.219077+00:00'
---
User decisions (2026-10-20) for fix cycle 5 of run-9099fb8f:
1. One-sided interior-tagged column: when the panel geometry and the column's position tag disagree, take the envelope (larger) flexural moment and emit a trace event. Trust geometry alone only after a conforming-mesh check around the column passes. Rationale: ACI 318-11 §13.6.3.3 (p.254) assigns moments per span, so geometry is right on good meshes, but the critic showed non-conforming meshes can miss panels and drop the moment to 0.26 M0.
2. Re-entrant corners: keep max(M_neg_ext, M_neg_int) and max(Eq. 13-7, 0.3 M0), and emit a trace event marked ENGINEERING JUDGMENT.
3. Two slabs listing the same cell: throw an error naming both slabs and the cell (no first-wins).
4. Add to the end of this run: the full StructuralSizer and StructuralSynthesizer test suites and scripts/runners/audit_trace_coverage.jl.
5. After the queued pre-ribbed-floor cleanup round, scope a systematic citation sweep (every code path checked against the corpus) as its own run before ribbed floors.
The audit is complete only for the gravity-backend leftover scope; walls, the lateral system, and unreviewed code paths are not covered.
