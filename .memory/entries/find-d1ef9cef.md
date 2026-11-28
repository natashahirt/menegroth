---
id: find-d1ef9cef
type: finding
project: menegroth
parent_id: plan-e3178055
title: r2c1 grillage girder over-shear = 1.41x tributary over-application (over-wide
  joist strips) + composite story-shell amplification
node_label: r2c1 girder over-shear source
tags: tributary,grillage,joists,one-way-partition,topology-r2c1,composite,deflection,diagnostic
status: active
open_threads: 0
success: 'true'
files: scripts/runners/diag_grillage_girder_load.jl@705634a
session_id: sess-8184ed37
created_at: '2026-11-26T16:40:06.235344+00:00'
updated_at: '2026-11-26T16:40:06.235344+00:00'
---
topology/r2c1 as steel_rib_composite failed after 10.5h on shell_deflection_ll: group 8, L=5m, Mu=2100 kN·m, Vu=1772 kN. That shear is >half the whole building's gravity load on one 5m girder — non-physical.

Diagnostic (scripts/runners/diag_grillage_girder_load.jl: prepare! + compute_member_tributaries! + to_asap!(diaphragms=:none) + plain gravity solve):
- Cells are fine: 20 loaded cells, net 480 m², uniform service pressure 6.79 kPa (sdl+sw+ll). pressure x area = 3261 kN.
- Applied TributaryLoad total = 4612 kN. ratio applied/expected = 1.41. So ~41% MORE load is applied than the floor weighs.
- Widest joist tributaries are 3.12 m wide on 7.81 m spans, at a 1.25 m joist module — ~2.5x the 1.25 m strip they should get. Over-wide strips on the irregular/diagonal bay overlap. (Same one-way tributary partition family as the e0c0 chirality work; diagonal supports mis-partition.) Caveat: some excess could be legitimate perimeter slab-edge strips past the centerline; not yet separated from genuine overlap (polygon-vs-net check not run).
- Plain gravity frame solve (no composite): worst beam 356 kN / 1479 kN·m. The failed composite run reported 1772 kN on its girder, so the composite story-shell path amplifies shear a further ~5x beyond the clean frame.

Two compounding issues: (1) a real tributary over-count (1.41x) on irregular bays with grillage joists, which over-loads every member (conservative-unsafe); (2) the steel-joists-composite-with-a-two-way-RC-slab config is a non-standard stacked floor that routes through the expensive story-shell composite path and inflates girder shear. The 10.5h runtime and the deflection failure both come from this config, not from a sane floor.
