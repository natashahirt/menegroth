---
id: chec-3734ee8c
type: checkpoint
project: menegroth
parent_id: plan-b0000001
title: 'CSA A23.3-14 beam worked-examples: all 5 ZK graphs committed, grounded & verified
  clean'
node_label: 'CSA A23.3-14 beam worked-examples: all 5 ZK graphs'
tags: zettelkasten,csa,a23.3,worked-examples,extraction,grounding,verify,recovery,checkpoint
status: active
open_threads: 0
success: 'null'
files: scripts/runners/csa_graph_reset.py@e096c83
session_id: sess-01ff4cac
created_at: '2026-07-15T10:54:20.451325+00:00'
updated_at: '2026-07-15T10:54:20.451325+00:00'
---
## What landed
All five CSA A23.3-14 StructurePoint spBeam worked-example graphs are now fully committed to the zettelkasten, attached to the `csa-a23-3-canon` spine (7 schema dimensions), grounded, and `source verify` clean (`ok:true`, 0 blocking, 0 ungrounded, 0 orphan/unverified quotes, 0 page mismatches, 0 duplicate titles):

| Graph (corpus_id) | claims (+hub) | files |
|---|---|---|
| csa-de-simply-supported-beam-a23-3-14 | 35 | 128 |
| csa-de-doubly-reinforced-beam-a23-3-14 | 33 | 92 |
| csa-de-moment-redistribution-a23-3-14 | 21 | 76 |
| csa-de-cantilever-beam-a23-3-14 | 24 | 78 |
| csa-de-continuous-beam-a23-3-14 | 30 | 93 |

Each graph carries `family:csa`, `edition:csa-a23-3-14`, `role:examples`, `tier:3`, element/material/limit-state facets, and `clause:<section>` tags so synapse can pin to exact provisions. TEST-ORACLE claims (factored shear/moment, effective depth, provided reinforcement, comparison tables) preserved for downstream Julia checker validation. Cross-edition flag (A23.3-04 N9.8.2.5 vs A23.3-14 9.8.2.5) preserved verbatim in cantilever cand-22.

## Grounding discipline
Scribes re-grounded every quote against the ZK's authoritative `source.fulltext` rather than the extractor's reference-file text; many equation quotes differed only by OCR artifacts (Private-Use-Area glyphs for x/-, space-split digits). No claim dropped for lack of grounding. Genuinely OCR-garbled equations captured as `question`/GAP notes (not fabricated LaTeX) for a later PDF-vision transcription pass — GAP counts: simply 6, continuous 14, moment-redist 5, cantilever several.

## Recovery notes (this session)
- Twin-scribe collisions (coordinator auto-executor spawning composer scribes alongside manual strong-model scribes) corrupted simply-supported + doubly-reinforced; reset to hub via `scripts/runners/csa_graph_reset.py`, canon spine links stripped, re-scribed idempotently.
- Flapping billing (unpaid-invoice) repeatedly killed subagents mid-run; idempotent skip-existing resume scribes made cumulative progress.
- LESSON: a 20s filesystem-stability check is NOT sufficient to declare a scribe dead — scribes pause >20s reading source.fulltext. Declaring simply-supported's original scribe dead and spawning a resume caused a 1-claim duplicate (candidate 35 'Rationale for effective moment of inertia Ie'), surgically deduped (deleted dup claim + 2 quotes + canon commentary spine-member link). Prefer explicit completion notifications over inferred liveness.

## Known artifact
ZK server's in-memory per-graph index count lags on-disk after filesystem deletions (simply verify reported 131 notes vs 128 on disk) until a server reload; grounding results are disk-accurate regardless.

## Still deferred
- ACI: continuous + 6 slab worked examples (reuse aci-318 canon) — id aci-slabs.
- Manual PDF-vision transcription pass to fill GAP/question equation notes across CSA graphs.
