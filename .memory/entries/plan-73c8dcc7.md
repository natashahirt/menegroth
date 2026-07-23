---
id: plan-73c8dcc7
type: plan
project: menegroth
parent_id: plan-66282b2f
title: 'Phase 1: DesignState substrate + explanation-layer grounding (vertical slice
  on medium_office)'
node_label: 'P1: DesignState + grounding'
tags: designstate,grounding,vertical-slice,medium_office,export-seam
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-8856e3bd
created_at: '2026-07-23T14:45:55.569359+00:00'
updated_at: '2026-07-23T14:46:50.365977+00:00'
---
First coordinator run for the harness. Scope: P0 (Unified DesignState) + P1 (explanation-layer grounding bridge), proven as a vertical slice on medium_office. Deferred: P2 exploration loop (second run once substrate is validated). No schema sign-off gate (engineer picks schema, caught in review).

Deliverables:
1. DesignState: serializable projection/adapter over BuildingDesign + DesignParameters + TraceCollector + a corpus citation set. NOT a rewrite. Reuse api/serialize.jl / deserialize.jl. Serialize to a domain-agnostic export seam (stable ids + explicit code/data/corpus refs) so angelo can index it later without coupling. Validate JSON round-trip on medium_office.
2. Grounding bridge: wire api/ontology.jl PROVISION_ONTOLOGY / CODE_RATIONALE to live corpus source_id+clause via the citation-join-key pattern; surface resolvable citations through explain_feasibility and /diagnose. Explanation-layer only — defer the safety-critical corpus_promote.jl --apply promotion pipeline.

Graph: explore -> engineer -> (reviewer + critic) -> memory. Rigor: medium.
