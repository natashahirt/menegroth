---
id: deci-ea62644b
type: decision
project: menegroth
parent_id: plan-1a66a544
title: 'Book-scale ZK ingest fix: ingest from corpus/text/*.txt, not PDF re-extraction'
node_label: 'Book-scale ZK ingest fix: ingest from corpus/text/'
tags: ''
status: active
open_threads: 0
success: 'null'
files: .zettelkasten/aisc-360-16/_meta.yaml@24b811e
session_id: sess-b1aee5d2
created_at: '2026-07-17T10:10:43.682138+00:00'
updated_at: '2026-07-17T10:10:43.682138+00:00'
---
Root cause found for the stale/partial AISC 360-16 ZK ingest: the aisc-360-16 source graph was bound (in .zettelkasten/aisc-360-16/_meta.yaml) to a hand-made EXCERPT file (corpus/text/codes/aisc/txt_extracts/aisc_extract_F.txt, 261,942 chars, 'Ch. J-N + Appendices + Commentary') — which is why all 72 prior notes are connection chapters (J10/K/L/M/N) and the member chapters (E/F/G/H) were absent. Re-ingesting the PDF was a no-op (dedup on unchanged PDF hash 8c237...).

Fix (generalizes to ALL book-scale codes): bind the ZK source to the COMPLETE corpus/text/*.txt (produced by the corpus ingest pipeline), not re-extract the PDF. For AISC: repointed _meta.yaml content_hash -> e597ba10... and source_path -> corpus/text/codes/aisc/AISC-360-16.txt, then rebuild_global_index. Source now serves the full 1,887,712 chars (byte-identical to corpus/text, so chapter char-offsets map directly), with the 72 prior notes preserved. Pattern for fan-out: for any book code whose ZK cache is thin/partial, repoint _meta.yaml to the corpus/text .txt (or ingest fresh from it) rather than fighting PDF extraction.

Spine architecture confirmed: building-code-extraction schema stamps facet tags (family/edition/limit-state/element/material) on every atomic note, so ONE grounded extraction feeds BOTH axes — Axis A code/provenance spine ({label}-canon, claim-type dimensions) attached at extraction time, and Axis B building-system spines (element x workflow-stage) built afterward by re-mining the facet tags. No hand-built hub nodes (hub_per_source=false); rely on the spine/synthesis architecture. Overnight run now caffeinated.
