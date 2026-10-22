---
id: note-914c3cb1
type: note
project: menegroth
parent_id: deci-ca9fa6c1
title: Steel tower PDFs catalogued in the corpus manifest
node_label: Steel tower PDFs catalogued in the corpus manifest
tags: corpus,sources.yml,catalog
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-430ec00e
created_at: '2026-10-22T01:19:02.133721+00:00'
updated_at: '2026-10-22T01:19:02.133721+00:00'
---
Catalogued the steel-tower PDFs into corpus/manifests/sources.yml and corpus/text/ (source catalogue only; no LangExtract and no zettelkasten notes). 24 new manifest ids. Deleted as useless: the 4-page AISC Design Examples v15.0 cover, and the 13-page conference paper titled New SDI Diaphragm Design Manual.

Added and kept: the real SDI Diaphragm Design Manual, 3rd edition (2004), id sdi-ddm-3e-2004. Current diaphragm edition remains DDM04, which is not in the corpus.

Text gaps: ctbuh-outriggers is image-only (84 of 89 pages have no text layer; tesseract is not installed, so the body is not searchable). asce-7-10-wind-guide text was extracted with pdftotext after pdfplumber failed on a bad page box. Tier 3 entries aisc-341-22-draft, aisc-scm-14th, and asce-7-10-wind-guide are catalogued as background and are not current code.

Reload the menegroth-corpus MCP server before list_sources will show the new ids.
