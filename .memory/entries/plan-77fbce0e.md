---
id: plan-77fbce0e
type: plan
project: menegroth
parent_id: plan-11f26f2d
title: Phase D — Members, walls, light framing & new material systems
node_label: 'Phase D: Light framing & materials'
tags: roadmap,timber,nds,cfs,aisi,masonry,tms,tilt-up,precast,pci,connections,phase-d
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2595ad50
created_at: '2026-07-14T01:33:15.051035+00:00'
updated_at: '2026-07-14T01:33:15.051035+00:00'
has_child_rationale: New structural material systems and element types beyond steel/RC
  — timber, CFS, masonry, precast, connections
---
# Phase D — Members, walls, light framing & new material systems

Today menegroth designs **steel (AISC 360-16)** and **RC (ACI 318)** members, plus PixelFrame. To reach DOE typologies it needs whole new **material systems** and the light-framing assemblies built from them. This is the largest phase by breadth.

- **Timber (NDS 2018 + SDPWS 2021):** the `NDSChecker` is a stub that errors. Need sawn-lumber/glulam/LVL catalogs, bending/shear/compression/combined checks, and light wood-frame assemblies — stud walls, joist floors, and **wood shear walls + diaphragms** (SDPWS). This is the small-hotel / apartment / restaurant / single-family workhorse.
- **Cold-formed steel (AISI S100):** studs, joists, track; CFS shear walls. Light-gauge residential & partitions.
- **Masonry (TMS 402/602):** CMU / brick bearing & shear walls, lintels. Schools, retail, warehouse.
- **Tilt-up & precast concrete (ACI 318 + PCI):** wall panels, double-tees, precast columns/beams. Warehouse, big-box retail, parking.
- **Connections (AISC Ch. J; NDS/AISI fasteners):** bolted/welded steel, base plates, wood/CFS connectors — currently only analysis idealizations (releases) exist, no design module.

**Coupling:** the *concrete* shear-wall side of light/lateral framing is the existing program `plan-w0000001` (S1–S4 + wall-type backlog). This phase adds the **non-concrete** wall/framing materials and the connection layer. Every item is gated on Phase E canon ingestion.
