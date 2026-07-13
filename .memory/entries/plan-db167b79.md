---
id: plan-db167b79
type: plan
project: menegroth
parent_id: plan-b0000001
title: 'Overnight coordinator run: extract ACI foundation worked examples → test-oracle
  library'
node_label: 'Overnight coordinator run: extract ACI foundation '
tags: zettelkasten,extraction,coordinator,aci,worked-example,test-oracle,plan
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1ca2448a
created_at: '2026-07-13T10:09:25.395774+00:00'
updated_at: '2026-07-13T10:09:25.395774+00:00'
---
**Goal:** Chew through the deferred backlog overnight via a coordinator extraction run, safely and autonomously (user is out).

**Scope this run:** two ACI foundation StructurePoint worked examples — `sp-de-square-spread-footing-aci318-14` (18 in sq column, DL=400/LL=270 kips) and `sp-de-combined-footing-aci318-14`. Both `role:examples`, ACI 318-14, most relevant to this repo's foundation/flat-plate work.

**Pipeline:** create_extraction_graph, schema=building-code-extraction, synthesis_label=`aci-318` (mints `aci-318-canon`), synthesize=true. Standard extractor→scribe→auditor per source + synthesizer + memory.

**Why safe to automate (vs. AISC appendices):** worked-example DEs do NOT define new design equations — they plug numbers into ACI code equations. The extraction value is test-oracle NUMBERS + clause citations, both verbatim-grounded (auditor gate = exact-match). No novel safety-critical formula is being invented, so a fast scribe cannot fabricate a dangerous equation. Contrast: AISC App 1–8 (ponding/stability-bracing/2nd-order) define real equations that OCR garbles — fabrication there would be unsafe → DEFERRED to hand-transcription like slice-1.

**Join-key contract:** source graph name == corpus_id verbatim; every provision/parameters/applicability note carries `clause:<section>` tag + `<corpus_id>#<section>` alias.

**Risks watched:** (1) scribe stall (composer-2.5-fast) — mitigated by short DEs = small trios; extractors are read-only planners (no gating). (2) auto-review gating scribe writes overnight — if scribes stall on gates, pivot to committing notes myself from the extractor candidate lists.

**Deferred (documented for next session):** AISC slice-2 (App 1–8 + Commentary, equation-heavy, same-graph); 7 remaining wall DEs (cantilever/bearing/shear/tilt-up/openings); spine materialization + Synapse edges to Julia checkers.
