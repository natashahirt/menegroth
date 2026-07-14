---
id: todo-76ac2b1c
type: todo
project: menegroth
parent_id: plan-97498959
title: E7 — Ingest & wire full ASCE 7-22 wind/seismic/snow provisions
node_label: 'E7: Full ASCE 7-22'
tags: todo,corpus,ingest,asce7,wind,seismic,snow,phase-e
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4ae8c09e
created_at: '2026-07-14T01:43:35.236722+00:00'
updated_at: '2026-07-14T01:43:35.236722+00:00'
has_child_rationale: Only load combinations are used today; the demand-generating
  chapters are needed for A3/A6
---
# E7 — Full ASCE 7-22 wind/seismic/snow

ASCE 7-16/7-22 are ingested but only the **load-combination** chapter is used. The demand-generating chapters are what A3/A6 need: Ch. 7 (snow), Ch. 8 (rain), Ch. 11–12 + 20–22 (seismic ELF/MRSA, site coefficients, SDC), Ch. 26–30 (wind MWFRS/C&C). **Do:** confirm these chapters are ingested/extractable (they may already be in `corpus/`), fill gaps, and structure the key tables/figures for retrieval. **Unblocks:** A3, A6, and every lateral typology.
