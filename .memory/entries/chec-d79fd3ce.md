---
id: chec-d79fd3ce
type: checkpoint
project: menegroth
parent_id: plan-b0000001
title: 4 ACI-318-14 beam worked examples fully committed + grounding-verified
node_label: '4 ACI-318-14 beam worked examples fully committed '
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6b5ec605
created_at: '2026-07-15T02:02:34.904632+00:00'
updated_at: '2026-07-15T02:02:34.904632+00:00'
---
All four ACI beam worked-example graphs are committed to the zettelkasten and pass `source verify` with 0 blocking issues (0 ungrounded claims, 0 unverified/orphan quotes, 0 page mismatches):
- sp-de-doubly-reinforced-beam-aci318-14: 82 notes
- sp-de-moment-redistribution-aci318-14: 67 notes (deduped after an orphan run-d3306fbe scribe collision; surgical on-disk removal of 66 dup files verified clean post ZK reload)
- sp-de-simply-supported-beam-aci318-14: 143 notes
- sp-de-cantilever-beam-aci318-14: 116 notes

Cantilever fix: its scribe was cut off mid-run by a ZK MCP reload, leaving 4 ungrounded deflection/serviceability test-oracle findings (immediate & long-term deflection, effective-inertia summary, hand-vs-spBeam comparison). Grounded each with a byte-exact comparison-table quote (Tables 1/2/5/6, OCR-clean, free of \uf0b4 PUA glyphs) via `note add` (method=exact, score 1.0); re-verify now clean. Connection edges being wired by a follow-up subagent.

All claims attach to the aci-318-canon spine. Safety rule held throughout: OCR-garbled symbolic equations were flagged as `question`/GAP notes for supervised PDF-vision transcription rather than fabricated as LaTeX.

Next: extract remaining ACI (continuous + 6 slabs, aci-318 canon) + 5 CSA A23.3-14 beams (new csa-a23-3 canon). Launching CSA first (new code family, lowest OCR-equation risk).
