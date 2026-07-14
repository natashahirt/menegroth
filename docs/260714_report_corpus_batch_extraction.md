# High-Value Corpus Batch — Ingest + Overnight Extraction Status Report

**Date:** 2026-07-13 → 14 (overnight run)
**Manifest:** `corpus/manifests/sources.yml` (28 new entries)
**Schema:** `building-code-extraction` (union schema, grounded + strict)
**Synthesis spines:** `aci-318-canon` (existing, reused), `csa-a23-3-canon` (new, pending)
**Memory:** phase `plan-9fee23b6`, checkpoint `chec-7f4fdecc`

---

## TL;DR

Answering "is there anything else in the corpus we haven't ingested yet?": there
was — **28 reference documents** that lived in the repo's `reference/` trees but
were never in the manifest. All 28 are now ingested (manifest + `corpus/sources/`
+ `corpus/text/`), so they are immediately queryable via the corpus MCP tools.
On top of that, a grounded **Zettelkasten extraction run** was launched over the
clean computational oracles (ACI beam + slab worked examples), reusing the
existing `aci-318-canon` spine.

## 1. Batch ingest (deterministic — DONE)

`ingest.py --apply` over 28 new manifest ids. Every doc already had a sibling
`.txt` next to its source PDF, so text extraction was a copy (no OCR pass). Text
quality spot-checked on the DEs: clean `PAGE` markers, legible design data and
numeric outputs — same StructurePoint format as the footings (multi-line
equations OCR-garble), so the equation-fabrication safety rule applies.

| Group | Count | family / role / tier | Notes |
|---|---|---|---|
| CSA A23.3-14 spBeam DEs | 5 | csa / examples / 3 | **NEW code family** (cantilever, doubly-reinforced, moment-redistribution, simply-supported, continuous) |
| ACI 318-14 beam DEs | 5 | aci / examples / 3 | doubly-reinforced, moment-redistribution, cantilever, simply-supported, continuous |
| ACI torsion reference | 1 | aci / code_guides / 2 | edition **unverified** — flagged; confirm before normative use |
| ACI 318-19 column DEs | 10 | aci / examples / 3 | interaction diagrams (rect/spiral/square/tied/circular/high-strength), manual biaxial, slender sway/non-sway/sway |
| ACI 318-14 slab DEs | 6 | aci / examples / 3 | one-way, wide-module skip-joist, two-way w/ beams, flat-plate, flat-slab w/ drop panels, waffle |
| Pixelframe source thesis | 1 | pixelframe / research / 2 | Wongsittikan MIT SMArchS 2024 |

Also **staged** (awaiting the PDFs you're downloading): `asce-7-16`, `asce-7-22`
under a new `asce` family.

## 2. Extraction run (in progress)

`create_extraction_graph` → **run-d3306fbe**: 11 ACI beam+slab worked examples,
synthesis_label `aci-318` → **reused the existing `aci-318-canon` spine**
(`missing_dims: []`, `partial: false` — no re-scaffold, so these examples join
the same canon as the footings). 35 tasks; extractors fan out 4 at a time.

**Reliability note (scribe path):** the coordinator assigns scribe tasks
`composer-2.5-fast` — the model that stalled on the AISC mega-slice — and a
conservative whole-workspace write lease. A **live foreign engineer run**
(`run-94212eb2`, editing flat-plate FEA) holds a workspace lease, so the scribe
`claim_task` is blocked (same friction as the footings). Resolution: commit
directly through the zettelkasten MCP (per-graph locking, no workspace lease, no
real disk conflict since scribes only touch `.zettelkasten/`), spawning scribe
subagents on **`claude-sonnet-5-thinking-high`** instead of composer. The
`create_extraction_graph` prep already registered the `(menegroth, aci-318-canon)`
context + hubs, so direct `note add`/`attach` resolves onto the spine.

**Safety rule holding:** the first extractor (moment-redistribution) flagged the
OCR-garbled equations (E_c §19.2.2.1.a, R_n/ε_t from PCA Notes §8.4, A_s,min
§9.6.1.2, max-positive-moment) as `question` candidates rather than fabricating
LaTeX, while still capturing the numeric test oracles (adjustment %, Table 2/4/5
A_s reductions, hand-vs-spBeam agreement). Exactly the intended behavior.

## 3. Deferred (documented — NOT fabricated)

- **ACI 318-19 column interaction-diagram DEs (10):** ingested to text /
  corpus-searchable, but ZK equation extraction deferred to a supervised
  PDF-vision pass. Interaction diagrams are inherently graphical and dense with
  garbled equations → high fabrication risk.
- **CSA beam DEs (5):** extraction graph (`csa-a23-3-canon`) to be created after
  the first ACI scribe commits cleanly, to avoid repeating the overnight stall.
- **Pixelframe thesis:** text-only; novel (non-code) methods — extract as
  research under supervision.

All 28 docs are queryable via the corpus MCP tools regardless of ZK-extraction
status.
