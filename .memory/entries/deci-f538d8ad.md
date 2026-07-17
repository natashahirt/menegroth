---
id: deci-f538d8ad
type: decision
project: menegroth
parent_id: plan-1a66a544
title: 'Knowledge-graph-as-index: two-tier notes + mandatory resolvable locators'
node_label: 'Knowledge-graph-as-index: two-tier notes + mandato'
tags: ''
status: active
open_threads: 0
success: 'null'
files: corpus/manifests/sources.yml@14c1eb9
session_id: sess-0a3217ba
created_at: '2026-07-17T18:51:28.857036+00:00'
updated_at: '2026-07-17T18:51:28.857036+00:00'
---
Reframe of the extraction goal (user decision, 2026-07-17). We will NOT try to fully atomize the entire building code — tables, figures, scans, and OCR-garbled math resist clean atomic capture and consume disproportionate effort. Instead the zettelkasten doubles as an INDEX into the source PDFs.

TWO-TIER MODEL:
- Tier 1 (implement-grade atomic notes): equations with LaTeX + variable defs + units, governing phi/Omega factors, applicability limits, key provisions — enough to write Julia without reopening the PDF.
- Tier 2 (pointer/index notes): everything else gets a lightweight note stating what lives there and pointing at the exact source location. Coverage is redefined as 'no section without at least a resolvable pointer' rather than 'every clause fully atomized'.

MANDATORY LOCATOR on EVERY note (both tiers):
- source_book = corpus source_id (e.g. aisc-360-16)
- source_chapter = clause/section (e.g. G2.1)
- source_page = printed label (human citation, e.g. 16.1-72)
- data.locator = {source_id, pdf_page, char_start, char_end, printed_page, text_path} — exact machine-resolvable pointer; pdf_page comes from the 'PAGE N' markers in corpus/text/*.txt and is dereferenced by corpus.page_window / get_source_text.
- snapshot = {page_index, rect} for equations (visual ground-truth).

Precision baseline chosen: PDF page + char-offset range on every note; snapshots reserved for equations/tables/figures.

IMPLEMENTATION NOTES / CONSTRAINTS:
- Grounded verbatim quotes already act as searchable locators; the explicit pdf_page/char-range makes the index openable and precise.
- LIMITATION: the note tool only auto-captures 'snapshot' when type=='equation' (server.py ~line 1013), so table/figure visual snapshots need a separate capture path (tracked, not blocking).
- Standalone scribe scripts SEGFAULT/SIGFPE when a second process touches a box the MCP server holds (kglite native mmap conflict + model2vec unmasking FP exceptions). Therefore all note writes go through the live MCP note tool, not in-process scripts. Locator COMPUTATION (reading corpus/text only) is safe to script.

ROLLOUT: enforce locators on all new notes now (starting with the AISC Ch.F/G pilot); backfill the existing ~70 2026-07-12 AISC notes with locators in a dedicated pass afterward.
