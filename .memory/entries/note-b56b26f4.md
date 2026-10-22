---
id: note-b56b26f4
type: note
project: menegroth
parent_id: deci-ca9fa6c1
title: Skyscraper documents and systems still to build
node_label: Skyscraper documents and systems still to build
tags: skyscraper,corpus,aisc-360-22,asce-7-22,lateral,deck,foundations
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-430ec00e
created_at: '2026-10-22T01:23:32.785799+00:00'
updated_at: '2026-10-22T01:23:32.785799+00:00'
has_child_rationale: User asked for one note covering the skyscraper document set
  and the systems still to build.
---
Reference map for a steel skyscraper. The manuals are in the corpus so later work can look provisions up. This note is the map, not a digest of the manuals. Citation rule is in deci-ca9fa6c1. Catalogue note is note-914c3cb1.

## Documents to cite

Loads and stability
- asce-7-22 (already in the corpus): wind and seismic demand. asce-7-10-wind-guide is the 7-10 examples book; do not use its numbers.
- nehrp-2020-design-examples-v1: seismic-loading check problems for that generation. Volume 1 only.
- aisc-360-22: steel members, Chapter C stability, Chapter I composite, Chapter J connections. This is the current steel specification. aisc-360-16 stays for existing member checks.
- aisc-dg28-stability: worked stability guidance paired with 360-22.

Seismic steel
- aisc-341-16 (already in the corpus) plus aisc-seismic-manual-3e (2018 examples). This pair is the seismic-steel basis.
- aisc-358-22 (already in the corpus): prequalified moment connections.
- nist-gcr-16-917-41: steel special moment frames, 2nd edition, older than 341-22. Guide only.
- aisc-341-22-draft is a January 5, 2022 review draft. Not a code source.
- aisc-scm-14th is the 2011 manual (360-10). Not a source of current table values.

Floors and diaphragms
- sdi-c-2017 and sdi-nc-2017: composite and non-composite deck design methods.
- vulcraft-deck-solutions-2020: ASD property and load tables for 1.5VL, 2VLI, 3VLI and the other listed profiles. Diaphragm strength and unshored spans are web tools and are not in the PDF.
- nist-gcr-11-917-10: composite steel-deck diaphragms.
- sdi-ddm-3e-2004: bare steel-deck diaphragm method and tables. The current edition is DDM04, which we do not have.
- aisc-dg11-vibrations: floor vibration.

Concrete core
- ACI 318-19 (already in the corpus).
- nist-gcr-16-917-40: concrete special moment frames. nist-gcr-16-917-42: concrete diaphragms, chords, and collectors.

Foundations
- fhwa-gec-10: drilled shafts. nhi-16009-v1 and nhi-16009-v2: driven piles. crsi-pile-caps: pile caps. Cap design still follows ACI 318-19 Chapter 13.

Tall-building behavior
- ctbuh-outriggers: 2012 outrigger and belt-truss guide. The PDF body is a scan (84 of 89 pages have no text layer), so search will not see the chapters.
- latbsdc-alternative-procedure: performance-based seismic procedure for tall buildings. Confirm the edition year from the cover before citing a clause.
- aisc-dg19-fire and aisc-dg29-vertical-bracing: fire resistance, and vertical bracing connections.

Shapes are already in the repo: AISC Shapes Database v15 at StructuralSizer/src/members/sections/steel/catalogs/data/. Only W and HSS have loaders.

## Systems still to build

Nothing here generates lateral load yet. StructuralSizer/src/loads/ is gravity, pattern loading, and combination factors. A steel tower is usually governed by wind and drift, so this comes first.

1. Lateral demand and analysis. ASCE 7-22 wind and seismic story forces. Diaphragms (rigid / semi-rigid / flexible). P-delta and AISC Chapter C second-order effects. Story drift. Modal response spectrum later, when the equivalent-force method is not allowed. Wind occupant acceleration is not on the roadmap and often governs tall steel buildings.
2. Concrete core walls, already underway. For a tower core that means openings and coupling beams, then special walls. The core is the main lateral system of a typical steel tower, with a steel perimeter frame.
3. Composite steel deck floors. CompositeDeck sizing is still a stub. Design from SDI C-2017 and check against the Vulcraft ASD tables. Floor vibration from Design Guide 11.
4. Steel braced frames and moment frames, to AISC 341-16, with the 3rd edition Seismic Design Manual as the example set. Buckling-restrained braces wait on manufacturer qualification data.
5. Outriggers and belt trusses. Not on the roadmap. The CTBUH guide is the reference, once its pages can be read.
6. Piles, pile caps, and global stability (overturning, uplift, sliding). A tall building puts tension into its piles.
7. Heavier steel sections and composite columns. The shapes database already contains jumbo W14s, channels, angles, tees, and HP piles. Loaders and AISC Chapter I column checks do not. Built-up plate sections are not in the database.
8. A steel high-rise generator. Existing generators cover low-rise steel offices and concrete high-rises. A tower case is a concrete core, a steel perimeter frame, and outrigger levels.

Connections, transfer levels, and structural fire design stay later. Column axial shortening between core and perimeter is a real tall-building effect and is not on the roadmap.

## Accepted gaps

No Design Examples v16, no published AISC 341-22, no 16th edition Manual, no DDM04, no SCBF or BRBF NIST briefs, no Taranath, no PEER TBI, no ACI 543R, no buckling-restrained-brace manufacturer data. None of those block the sequence above. Bare-deck diaphragm fastener tables are the 2004 manual, not the current one. Composite-slab diaphragms can proceed from the NIST brief and ACI.
