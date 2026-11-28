---
id: plan-b671b6ab
type: plan
project: menegroth
parent_id: plan-0501eab9
title: Slab-on-rib floors on every 2024 plan
node_label: Slab-on-rib floors on every 2024 plan
tags: slab,waffle,deck,t-beam,2024
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ba604827
created_at: '2026-11-12T14:59:06.685199+00:00'
updated_at: '2026-11-12T14:59:06.685199+00:00'
---
Slab-on-rib floors (one-way, two-way, waffle, composite deck) have to finish on every 2024 Slab Design Factors plan, including Tan's full buildings and plans with openings. Flat plate, flat slab, and vault stay refused on these plans.

Fixes:
- A one-way span whose axis does not meet an edge squarely still sees the beams and walls on the cell boundary (ACI 318-11 Table 9.5(a)). Both sides supported is simple; one side is a cantilever. A cell with no beam or wall still throws.
- A waffle rib end that lands within 1 mm of another rib or the boundary is noded there before the bay walk.
- Composite deck spans the bay between the beams that are there. When that bay is longer than the profile's longest published single-span unshored length, fill beams are added at the existing 4 ft steel-joist spacing and the deck spans between those beams.
- An RC T-beam the standard catalog cannot carry is sized from the heavy catalog (up to 48 in).
