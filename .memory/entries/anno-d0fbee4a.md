---
id: anno-d0fbee4a
type: annotation
project: menegroth
parent_id: plan-9fee23b6
title: Orphan overnight scribe duplicated moment-redist ZK graph; deduped on disk,
  reload pending
node_label: Dedup moment-redist orphan
tags: zettelkasten,duplication,recovery,orphan-run,dedupe
status: active
open_threads: 0
success: 'null'
files: docs/260714_report_corpus_batch_extraction.md@2ca51e5
session_id: sess-7454f420
created_at: '2026-07-14T10:04:32.232409+00:00'
updated_at: '2026-07-14T10:04:32.232409+00:00'
---
After the ZK MCP reload, I dispatched 4 strong-model scribes (doubly, moment-redist, cantilever, simply) to commit the preserved ACI-beam extractor candidates. A ROGUE scribe `edacc232` (NOT one I launched) also committed the SAME 25 moment-redistribution candidates concurrently with my `f10bb56c` — almost certainly an orphaned background scribe subagent from the LOST overnight coordinator run `run-d3306fbe` (its run record was released on the process restart, but an already-spawned scribe subagent survived and finished at ~05:52). Result: `sp-de-moment-redistribution-aci318-14` had every note doubled (134 files).

DEDUP (surgical, deterministic): partitioned by claim-id membership — deleted edacc232's 25 claim notes + the 41 quote notes whose `supports` target was one of those claims (66 files). Kept f10bb56c's complete, internally-consistent set (25 claims + 41 quotes + hub = 67). Verified on disk: 0 doubled titles, all 41 remaining quote targets resolve (0 dangling).

KNOWN ARTIFACT: `rebuild_global_index` does NOT refresh the per-graph in-memory index; `note search` still returns the deleted ids until a ZK server RELOAD. On-disk state is the source of truth and is correct. RELOAD PENDING — deliberately deferred until the 3 still-running scribes (doubly/cantilever/simply, different graphs) finish, to avoid disrupting their in-flight writes.

FOLLOW-UP RISK: edacc232 may have SIBLING orphan scribes (same lost run) for doubly/cantilever/simply that could duplicate those graphs too. As of dedup, doubly (82) and simply (123) showed 0 doubled titles, cantilever not yet written. MUST re-sweep all 4 graphs for doubled titles once every scribe completes, and dedup any further doubles the same way, THEN reload ZK and re-verify disk state persisted (guard against the in-memory index re-flushing phantoms).
