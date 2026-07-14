---
id: chec-7f4fdecc
type: checkpoint
project: menegroth
parent_id: plan-9fee23b6
title: High-value corpus batch ingested (28 docs) + ACI beam/slab extraction run launched
node_label: batch ingest + ACI DE run
tags: corpus,ingest,zettelkasten,extraction,csa,aci,coordinator
status: active
open_threads: 0
success: 'null'
files: corpus/manifests/sources.yml@af23a91
session_id: sess-c6d7f850
created_at: '2026-07-14T01:43:52.998011+00:00'
updated_at: '2026-07-14T01:43:52.998011+00:00'
has_child_rationale: 'Overnight batch: manifest + ingest of 28 reference docs, then
  launched grounded extraction over the ACI beam/slab worked examples.'
---
## Batch ingest (deterministic, done)

Added **28 previously un-manifested reference docs** to `corpus/manifests/sources.yml` and ran `ingest.py --apply`. All 28 already had sibling `.txt` next to their source PDF, so text extraction was a copy (no OCR pass needed). Groups:

- **CSA A23.3-14 (NEW code family):** 5 StructurePoint spBeam DEs (cantilever, doubly-reinforced, moment-redistribution, simply-supported, continuous). `family: csa`.
- **ACI 318-14 beam DEs:** doubly-reinforced, moment-redistribution, cantilever, simply-supported, continuous (5) + `aci-torsion-reference` (code_guide, edition unverified — flagged).
- **ACI 318-19 column DEs:** 10 StructurePoint spColumn examples (biaxial interaction rect/spiral/square, interaction tied/circular/high-strength, manual biaxial procedure, slender sway/non-sway/sway).
- **ACI 318-14 slab DEs:** 6 spSlab/spBeam (one-way, wide-module skip-joist, two-way w/ beams, flat-plate, flat-slab w/ drop panels, waffle).
- **Pixelframe source thesis:** Wongsittikan MIT SMArchS 2024 (`family: pixelframe, role: research, tier: 2`).

Also previously staged (awaiting files): `asce-7-16`, `asce-7-22` under a new `asce` family.

Text quality verified on the DEs: clean PAGE markers, legible design data + numeric outputs. Same StructurePoint OCR pattern as the footings (multi-line equations garble), so the equation-fabrication safety rule applies.

## Extraction run launched

`create_extraction_graph` → **run-d3306fbe**, 11 ACI beam+slab worked examples, schema `building-code-extraction`, synthesis_label `aci-318` → **reused the existing `aci-318-canon` spine** (missing_dims [], partial false — no re-scaffold). 35 tasks, extractors fan out 4 at a time. First wave (ext_0–3: doubly-reinforced, moment-redistribution, cantilever, simply-supported beams) spawned as background opus planners with the equation-fabrication safety rule baked in. Scribe tasks are assigned `composer-2.5-fast` (the model that stalled on the AISC mega-slice); I will OVERRIDE scribe spawns with a stronger model.

## Deferred (documented, NOT fabricated)

- **ACI 318-19 column interaction-diagram DEs (10):** ingested to text/corpus-searchable, but ZK equation extraction deferred to a supervised PDF-vision pass — interaction diagrams are inherently graphical and dense with garbled equations (high fabrication risk).
- **CSA beam DEs (5):** extraction graph to be created (`csa-a23-3-canon`) AFTER the first ACI scribe commits cleanly, to avoid repeating the overnight scribe stall.
- **Pixelframe thesis + any theses:** text-only; novel (non-code) methods, extract as research under supervision.

All 28 docs are now queryable via the corpus MCP tools regardless of ZK-extraction status.
