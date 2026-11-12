---
id: deci-5685ffd8
type: decision
project: menegroth
parent_id: plan-f578a118
title: 'Special-wall shear: Ωv at the line base, φ = 0.60 by shear span, Mpr at 1.25fy
  both ways'
node_label: Shear readings
tags: aci-318, special-walls, shear
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7958f9c0
created_at: '2026-11-12T00:25:29.045864+00:00'
updated_at: '2026-11-12T00:25:29.045864+00:00'
---
User decisions 2026-11-11. Shear is now ahead of the end bars (step 2 reordered: §18.10.3–4 with Mpr from the placed web steel first, then end bars and a recheck).

Finding: rows A1/B4 were checked with Chapter 11 shear at Vu and φ = 0.75. Missing: Ve = Ωv·ωv·Vu ≤ 3Vu (§18.10.3.1, rendered PDF 323); §21.2.4.1 φ = 0.60 (rendered PDF 398; applies per §21.2.4(b), PDF 397; exempt for §18.10.6.2 walls per §18.10.4.6, PDF 325); §18.10.2.1–2 minimums, 18 in. spacing, and two curtains (PDF 320); §18.10.4.2 αc ratio and §18.10.4.3 ρl ≥ ρt for hw/ℓw ≤ 2 (PDF 324). The Chapter 11 cap 8λ√f′c·Acv per pier stays; it is never less conservative than §18.10.4.4.

Readings:
- Ωv section: a continuous line computes Ωv once at its base and applies it to every pier of the line (Fig. R18.10.3.1). Any other pier uses its own bottom section with hwcs the stack height above it.
- §21.2.4.1 shear at Mn: Mn,max × |Vu|/|Mu| at the pier's bottom section, largest over the earthquake combinations; Mn,max is the largest Mn over those combinations' axials.
- Mpr: 1.25fy in tension and compression bars, φ = 1.0, at the axial of each earthquake combination; Ωv from the combination giving the largest value (Table 18.10.3.1.2 footnote 1).
