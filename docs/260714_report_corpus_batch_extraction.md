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

## 2. Extraction run — extractors DONE, commit BLOCKED on ZK MCP

`create_extraction_graph` → **run-d3306fbe**: 11 ACI beam+slab worked examples,
synthesis_label `aci-318` → **reused the existing `aci-318-canon` spine**
(`missing_dims: []`, `partial: false` — no re-scaffold, so these examples join
the same canon as the footings). 35 tasks; extractors fan out 4 at a time.

**First extractor wave (4/4) completed cleanly.** doubly-reinforced,
moment-redistribution, cantilever, and simply-supported beams each produced a
grounded candidate set. **Safety rule held:** OCR-garbled equations (e.g. E_c
§19.2.2.1.a, R_n/ε_t from PCA Notes §8.4, A_s,min §9.6.1.2) were flagged as
`question` candidates rather than fabricated as LaTeX, while numeric test oracles
(adjustment %, Table 2/4/5 A_s reductions, hand-vs-spBeam agreement) were
captured. Full candidate lists live in the run-d3306fbe agent transcripts.

### ⛔ BLOCKER — zettelkasten MCP server not connected

The **`project-0-menegroth-zettelkasten` MCP server is not registered in this
Cursor session.** `GetMcpTools` shows only `coordinator`, `memory`,
`memory-artifacts`, and `corpus` — there is **no `note`/`attach` tool**. So **no
zettelkasten note can be committed** — not by scribe subagents, and not directly
by the parent. The first scribe subagent failed for exactly this reason (not a
content/quality failure).

- `create_extraction_graph` still seeded per-source hubs (`20260713-2137-*`)
  because the *coordinator* server reaches the ZK store internally; only the ZK's
  own MCP **tool surface** (writes) is missing.
- Config is correct: `.cursor/mcp.json` declares `zettelkasten` →
  `/Users/tashahirt/.venvs/angelo/bin/angelo-zettelkasten` (binary present). It
  needs an **MCP reload** to register.
- **Not attempted:** hand-authoring note `.md` files directly. That would bypass
  grounding validation + spine-edge resolution on safety-critical structural
  content — declined per the code-accuracy rule.

**Remediation (needs user, ~1 min):**
1. Cursor → Command Palette → **"Reload MCP Servers"** (or restart Cursor).
2. Confirm `zettelkasten` shows connected in Settings → MCP.
3. Re-run the scribe wave / resume run-d3306fbe — extractor candidates are
   preserved, no re-extraction needed.

Memory breadcrumb: `anno-49cde79d` under phase `plan-9fee23b6`.

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
