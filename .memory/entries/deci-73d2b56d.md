---
id: deci-73d2b56d
type: decision
project: menegroth
parent_id: plan-b0000001
title: Corpus identifiers are the zk join key; extract at clause granularity
node_label: corpus_id join key + clause-level notes
tags: zettelkasten,extraction,synapse,join-key,corpus,schema,decision
status: active
open_threads: 0
success: 'null'
files: .cursor/extraction-schemas.yaml@3fb6ce1, docs/angelo-knowledge-graph-plan.md@3fb6ce1
session_id: sess-068c9b66
created_at: '2026-07-12T22:57:30.223512+00:00'
updated_at: '2026-07-12T22:57:30.223512+00:00'
has_child_rationale: Locks the load-bearing, hard-to-change-post-extraction identity/granularity
  contract for the building-code extraction
---
Two load-bearing decisions for the `building-code-extraction` run, locked into the schema description as a JOIN-KEY CONTRACT and documented in the plan (§4.2a, §4.3a). Expensive to change after extraction, so decided up front.

## 1. Preserve `corpus_id` as the zk join key (no re-namespacing)
Existing Julia code + tests are already dotted with `corpus: aci-318-11`, `corpus: sp-de-combined-footing-aci318-14`, etc. Rather than mint fresh zk ids (which inherits a migration-mapping problem and stale citations), carry the identifiers across and swap the backend underneath them.
- **Document key = the graph name.** `create_extraction_graph` takes `sources[].name` as the kebab-case graph id -> set it to the manifest `corpus_id` verbatim (they're already kebab-case). The zk source graph literally IS `aci-318-11`, so every `corpus: <id>` citation upgrades to a live zk edge with no mapping table.
- **Clause key = alias + tag, NOT primary id.** `note(action=add)` has no id param (ids are server-minted from the title), so the clause key rides the ALIAS channel: the scribe stamps each provision/equation/parameters/applicability note with a `clause:<section>` tag AND an alias `<corpus_id>#<section>` (e.g. `aci-318-11#8.5.1`).

## 2. Extract at clause (sub-document) granularity
Verified against the grounded-extraction pipeline contract: the scribe mints `claim`+`quote` note pairs per schema dimension (~60 claims/source), NOT one blob per PDF. So a clause fans into separate notes; the per-source hub is only an overview spoke. Clause-granular NOTES are automatic; the clause-addressable KEY is not (dimension tags are `provision`/`equation`, never `§8.5.1`) -> hence the alias/tag convention above. This is what makes synapse pin an `implements` edge to the exact provision and lets the 'suspicious number -> exact clause' report loop land.

## 3. Manifest taxonomy IS the zk seed structure
`sources.yml` `family × role × tier` maps onto zk structure so the corpus's organizing metadata survives the pipeline swap:
- `family` (aci/aisc/fib/foundations/walls) -> spines (`synthesis_label` per family; primary matrix axis).
- `role` (codes/code_guides/examples/research/textbooks) -> note-type + authority + a second spine axis (canon vs worked-practice vs background). `examples` become machine-readable `finding`/`data` case notes that generate tests (goal c -> a).
- `tier` (1-4) -> `tier:<n>` facet for authority weighting on retrieval (primary standard outranks secondary guide on the same clause).

Credit: both refinements proposed by a collaborating agent; confirmed here against the live tool schemas (`create_extraction_graph`, `note`, `schema`) and the grounded-extraction rule.

Execution note: these are SCRIBE behaviors (facet tags + clause alias), so the join-key contract must be pasted into the scribe prompt at pilot time. Schema description edit requires a coordinator+zettelkasten reload to enter the registry.
