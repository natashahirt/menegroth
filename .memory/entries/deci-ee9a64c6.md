---
id: deci-ee9a64c6
type: decision
project: menegroth
parent_id: plan-152a025b
title: 'Phase 8 openings: overlap goes to piers, detailing uses stated code-traced
  defaults, spandrels get closed stirrups'
node_label: P8 D1-D3 resolved
tags: walls,openings,decision,detailing,spandrel,segmentation
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-24af6777
created_at: '2026-11-04T20:58:45.697457+00:00'
updated_at: '2026-11-04T20:58:45.697457+00:00'
has_child_rationale: Resolves open decisions D1-D3 of plan-152a025b
---
User answers 2026-11-04.

D1 Overlap cells (staggered openings): rows of openings take priority. A horizontal segment stops at the first row containing an opening; the overlap cell is checked as part of the pier. Modeling idealization, not ACI text; say so in the docstring and report.

D2 Detailing: stated defaults (user preference), not a required input. Every default is overridable via a `WallDetailing` field on OrdinaryWallInputs, and every result that uses one prints it. Defaults are derived from clauses where possible:
- Cover 1.5 in: ACI 318-19 Table 20.5.1.3.1, exposed-to-weather walls with No.5 and smaller, and beam/column stirrups and ties. VERIFY table values on the PDF (text extraction dropped cells). If a chosen bar is No.6 or larger in an exposed wall, cover becomes 2 in per the same table.
- Distributed bar spacing: s = min(12 in, 3h, 18 in, lw/3 vertical or lw/5 horizontal when shear reinforcement is required) per §11.7.2.1 / §11.7.3.1. 12 in also satisfies §23.5.2(a), so beta_s = 0.75 by Table 23.4.3(a) line (c) is available when rho >= 0.0025 each way.
- Layers: two when t > 10 in (§11.7.2.3), otherwise one. Sets the §11.7.5.1 bar count (two No.5 vs one No.5).
- Bar sizes: wall distributed No.5; spandrel chords No.5 (count chosen by design); closed stirrups No.4; column ties No.3 for longitudinal No.10 and smaller, No.4 otherwise (§25.7.2.2, derived not defaulted); column longitudinal bars chosen by the column design.
- STM tie centroid d_t = cover + stirrup diameter + chord diameter/2 (derived).

D3 Spandrel shear reinforcement: explicit closed stirrups plus chord bars, sized by the check. Wall vertical bars are not counted toward spandrel shear.

D4 (strut end width / node geometry at the pier face) stays open until step 8.6d; ground it in the R23.2.6 figures and sp-deep-beam-transfer-girder-aci318-14 first.
