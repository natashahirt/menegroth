---
id: note-c050c3f0
type: note
project: menegroth
parent_id: deci-192838aa
title: Bowles 5th ed. Table 9-1 checked against soil preset ks values
node_label: Bowles Table 9-1 check
tags: foundations,soil,ks,bowles,corpus
status: active
open_threads: 0
success: 'null'
files: corpus/manifests/sources.yml@79f9bf8, StructuralSizer/src/foundations/types.jl@79f9bf8
session_id: sess-5d95b467
created_at: '2026-11-07T22:02:23.937610+00:00'
updated_at: '2026-11-07T22:02:23.937610+00:00'
has_child_rationale: User supplied the Bowles PDF; this records the table check against
  the soil presets
---
Bowles, Foundation Analysis and Design, 5th ed. (McGraw-Hill 1996; International Edition 1997) is registered as textbook-bowles-foundation-analysis-design-5e. Table 9-1 (section 9-6, PDF p. 533, printed p. 505) gives ranges of ks in kN/m^3, and the text says the ranges are guides and not to use a range average as the estimate.

Table 9-1:
- Loose sand: 4800-16000
- Medium dense sand: 9600-80000
- Dense sand: 64000-128000
- Clayey medium dense sand: 32000-80000
- Silty medium dense sand: 24000-48000
- Clayey soil, qa < 200 kPa: 12000-24000
- Clayey soil, 200 < qa < 800 kPa: 24000-48000
- Clayey soil, qa > 800 kPa: > 48000

Preset check (values left unchanged; comments now mark them as engineering judgment):
- loose_sand 5000: inside loose sand.
- medium_sand 25000: inside medium dense sand. The table has no "medium sand" row.
- dense_sand 100000: inside dense sand.
- soft_clay 12000 at qa 50 kPa: low end of clayey soil qa < 200 kPa. No "soft clay" row.
- stiff_clay 50000 at qa 150 kPa: outside. That qa is in the 12000-24000 band.
- hard_clay 150000 at qa 300 kPa: outside. That qa is in the 24000-48000 band. No "hard clay" row.

Numbers were not changed. Stiff and hard clay still need a decision.
