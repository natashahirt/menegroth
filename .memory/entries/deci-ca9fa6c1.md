---
id: deci-ca9fa6c1
type: decision
project: menegroth
parent_id: menegroth
title: 'Steel tower reference set: use the documents on hand'
node_label: Tower reference basis
tags: aisc-360-22,aisc-341-16,sdi,asce-7-22,corpus,skyscraper
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-78933dbd
created_at: '2026-10-22T00:28:19.413792+00:00'
updated_at: '2026-10-22T01:23:32.785799+00:00'
has_child_rationale: 'User constraint: the PDFs in corpus/sources/unsorted are the
  best available set.'
---
User confirmed (2026-10-21) that corpus/sources/unsorted is the best reference set they can obtain for the steel skyscraper. Later implementation cites these sources and does not wait on the missing editions.

## Cite
- Steel members, stability, composite, connections: published ANSI/AISC 360-22 (August 1, 2022) in unsorted.
- Seismic steel systems: published AISC 341-16 already in the corpus, checked against the Seismic Design Manual 3rd edition (2018). The January 5, 2022 AISC 341-22 file is a watermarked review draft and is not a code source.
- Wind and seismic demand: ASCE 7-22 already in the corpus. The ASCE 7-10 wind-provisions guide is not used for numbers. 2020 NEHRP design examples Volume 1 is the loading oracle.
- Deck gravity: ANSI/SDI C-2017 and NC-2017, checked against Vulcraft Deck Solutions (Sept 2020) ASD property and superimposed-load tables (1.5VL, 2VLI, 3VLI). Diaphragm strength and unshored spans in that catalog are web tools and are not in the PDF.
- Composite floor diaphragms: NIST GCR 11-917-10 plus ACI. Concrete core: ACI 318-19. Concrete diaphragm chords/collectors: NIST GCR 16-917-42.
- Guides: AISC DG 11 (vibration), DG 19 (fire), DG 28 (stability), DG 29 (bracing connections). Prequalified moment connections: AISC 358-22 already in the corpus.
- Foundations: FHWA GEC 10 (drilled shafts), NHI 16009 Vol I–II (driven piles), CRSI pile-cap guide, ACI 318-19 Ch. 13.
- Outriggers: CTBUH Outrigger Design for High-Rise Buildings. Performance-based seismic alternative: LATBSDC.
- Shapes: AISC Shapes Database v15 already at StructuralSizer/src/members/sections/steel/catalogs/data/aisc-shapes-v15.csv.

## Do not cite as current code
- AISC Design Examples v15.0 file is 4 cover pages only.
- "New SDI Diaphragm Design Manual" is a 13-page 2016 conference paper about DDM04, not DDM04.
- Steel Construction Manual 14th edition (2011, AISC 360-10): geometry familiarity only. Connection numbers come from 360-22 Chapter J and AISC 358-22.
- AISC 341-22 review draft.

## Accepted gaps
- Bare steel-deck diaphragm fastener tables (DDM04 / AISI S310). Composite-slab diaphragms proceed without them.
- Buckling-restrained braces, until manufacturer qualification data exists. Braced frames and moment frames are in scope.
- Design Examples v16.0. Checks use the specification, design-guide examples, the seismic manual, Vulcraft ASD tables, and NEHRP Volume 1.
- Taranath, PEER TBI, and ACI 543R are optional, not blockers.
