---
id: deci-1b6285ff
type: decision
project: menegroth
parent_id: plan-1a66a544
title: Adopt documented grounded-extraction pipeline (new angelo rules) — methodology
  correction
node_label: Adopt documented grounded-extraction pipeline (new
tags: ''
status: active
open_threads: 0
success: 'null'
files: .cursor/rules/grounded-extraction.mdc@0c7c3c7
session_id: sess-176cc39e
created_at: '2026-07-17T09:50:56.890775+00:00'
updated_at: '2026-07-17T09:50:56.890775+00:00'
---
New angelo update ships .cursor/rules/grounded-extraction.mdc, zettelkasten.mdc, stream.mdc. Aligning the backfill run to the documented pipeline (supersedes ad-hoc extractor prompt).

CORRECTIONS:
1. PROMPT ASSEMBLY (per trio task): paste the WHOLE schema — dimensions AND the `relations` backbone — into all three roles (extractor/scribe/auditor), plus the SPINE block (synthesis graph, apex id, attach_relation, dim tag->node-id map) for scribe+auditor. Dropping the backbone 'collapses the graph back into a hub-and-spokes dandelion.' => the materialized SPINE (synthesis block) is the anti-dandelion structure the user wants; hub_per_source=false + scribe attaches each claim to its DIMENSION NODE (not a hub) is correct. building-code-extraction already declares a synthesis block, so create_extraction_graph pre-creates the spine (apex+7 dim nodes) automatically.
2. STRUCTURED REFERENCES (design-value tables: CLT grades, NDS Supplement ref design values, SJI/SDI load tables, ASCE7 coefficient tables): capture via the DATASET path, NOT prose. Mechanism: transcribe table -> committed CSV sidecar in the source folder -> dataset(action='add', graph=<source>, title, path=<csv>, format=csv, schema=[columns], source_page) -> dataset(action='snapshot') to pin content_hash -> dataset(action='attach', note_id=<dataset>, target_id=<provision/example note or dimension node>, relation='supports'). Optionally evidence:data claims grounded by a re-computable derivation (expr like mean:col/quantile:col:q or registered id), auditor RE-RUNS to verify (dataset-profile schema is the worked pattern). SAFETY: raw table transcription is safety-critical — needs an independent verification pass before trust.
3. SPINE FINISH (the 'synthesizer' step, manual/orchestrator — NOT a shipped agent): after scribes+auditor, per dimension node call note(action='follow', graph=<canon>, note_id=<dim node>, relation='input-to', direction='incoming', project=menegroth) to roll up cross-graph claims, author the node body (bold headline + grounded paragraph + 'Grounded in N claims across M sources'), then note(action='update', replace_body=..., synthesis_status='materialized'); apex last. Track via schema(action='spines') incomplete[]/materialized flag.
4. SPINE GRANULARITY (synthesis_label): codes = single-subject-per-family. One spine per code family (aci-318-canon, aisc-360-canon, nds-canon, aisi-s100-canon, ...); editions of one family (aci-318-11 + aci-318-19) roll into ONE family spine. NOT a cross-code comparison matrix.
5. BATCH: pilot 2-3 sources, verify scribe tags + auditor coverage matrix, then fan out (matches rule).

TOOL NOTE: MCP now via dynamic-tools interface (GetDynamicTools/CallDynamicTool), not CallMcpTool.
