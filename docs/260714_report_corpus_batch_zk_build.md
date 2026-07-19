# High-Value Corpus Batch + ACI Beam/Slab Extraction — Overnight Status Report

**Date:** 2026-07-14 (overnight run)
**Manifest:** `corpus/manifests/sources.yml` (+28 entries, pinned `af23a91`)
**Schema:** `building-code-extraction` (union schema, grounded + strict)
**Extraction run:** `run-d3306fbe` (coordinator), spine `aci-318-canon`
**Memory:** phase `plan-9fee23b6`, checkpoint `chec-7f4fdecc`

---

## TL;DR

Answered "anything else not ingested?" by scanning the `reference/` trees and adding
the **28 highest-value previously-un-manifested documents** to the corpus manifest,
then ingesting all of them to text (now queryable via the corpus MCP tools). On top of
that I chained an overnight grounded-extraction run over the **11 ACI 318-14 beam & slab
worked examples** — the clean computational test-oracles — onto the existing
`aci-318-canon` spine. Column interaction-diagram DEs, the CSA family, and the pixelframe
thesis are handled per their risk profile (see Deferred).

---

## 1. Batch ingest (complete, deterministic)

28 docs added to `sources.yml` and materialized via `ingest.py --apply`. Every doc already
had a sibling `.txt` beside its source PDF, so this was a copy — no OCR pass required.

| Group | Count | family / role / tier | Notes |
|---|---|---|---|
| CSA A23.3-14 spBeam DEs | 5 | csa / examples / 3 | **New code family.** cantilever, doubly-reinforced, moment-redistribution, simply-supported, continuous |
| ACI 318-14 beam DEs | 5 | aci / examples / 3 | doubly-reinforced, moment-redistribution, cantilever, simply-supported, continuous |
| ACI torsion reference | 1 | aci / code_guides / 2 | edition **unverified** — flagged in manifest note, confirm before citing |
| ACI 318-19 column DEs | 10 | aci / examples / 3 | biaxial interaction (rect/spiral/square), interaction (tied/circular/high-strength), manual biaxial procedure, slender sway/non-sway/sway |
| ACI 318-14 slab DEs | 6 | aci / examples / 3 | one-way, wide-module skip-joist, two-way w/ beams, flat-plate, flat-slab w/ drop panels, waffle |
| Pixelframe source thesis | 1 | pixelframe / research / 2 | Wongsittikan MIT SMArchS 2024 |

Previously staged, awaiting the PDFs: `asce-7-16`, `asce-7-22` (new `asce` family).

Text quality was spot-checked on the DEs: clean `PAGE` markers, legible design data and
numeric outputs. They share the StructurePoint OCR pattern seen on the footings
(multi-line equations garble in the text layer), so the equation-fabrication safety rule
below is in force.

## 2. Extraction run (launched, in progress)

`create_extraction_graph` → **run-d3306fbe**: 11 ACI beam + slab worked examples, schema
`building-code-extraction`, `synthesis_label: "aci-318"`. The run **reused the existing
`aci-318-canon` spine** (`missing_dims: []`, `partial: false`) — the new examples attach to
the same dimension nodes as the footing examples, not a fresh scaffold. 35 tasks total
(11× extractor→scribe→auditor + synthesizer + memory), extractors fanning out 4 at a time.

**Scribe-stall mitigation:** the graph assigns scribes `composer-2.5-fast` — the exact model
that silently stalled on the oversized AISC mega-slice. These worked examples are small
(~15–40 candidates each), and I am driving the wave loop myself and **overriding scribe
spawns with a stronger model**. The CSA graph is intentionally held until the first ACI
scribe commits cleanly, so a repeat stall can't burn the whole night.

First extractor wave (doubly-reinforced, moment-redistribution, cantilever, simply-supported
beams) is running as background opus planners with the safety rule baked into each prompt.

## 3. Equation-fabrication safety rule (enforced)

Every extractor prompt carries: **only** capture an equation as an `equation` note when its
LaTeX is legibly reconstructable from a clean, contiguous verbatim quote. If OCR-garbled,
unreadably split, or figure-only → emit a `question` candidate flagging it for a manual
PDF-vision pass. **Never** fabricate LaTeX, factors, or symbols. Numeric worked-example
OUTPUTS (the test oracles) are still captured as `example` findings even when a nearby
equation is garbled.

## 4. Deferred (documented, not fabricated)

- **ACI 318-19 column interaction-diagram DEs (10):** ingested → corpus-searchable, but ZK
  equation extraction deferred to a supervised PDF-vision pass. Interaction diagrams are
  inherently graphical and dense with garbled equations (high fabrication risk).
- **CSA beam DEs (5):** extraction graph (`csa-a23-3-canon`) to be created after the first
  ACI scribe commits cleanly.
- **Pixelframe thesis:** text-only for now; novel (non-code) research methods — extract
  under supervision, tagged research not normative.

All 28 docs are queryable via the corpus MCP tools regardless of ZK-extraction status.
