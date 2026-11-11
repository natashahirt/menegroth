---
id: plan-4fb2ee75
type: plan
project: menegroth
parent_id: plan-a7ebaacc
title: Remaining irregular-geometry fixes, stubs left alone
node_label: Remaining geometry fixes
tags: irregular,openings,diaphragm,ingest
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-9c8dccae
created_at: '2026-11-11T11:25:17.896151+00:00'
updated_at: '2026-11-11T15:49:02.700641+00:00'
has_child_rationale: User asked to work through every remaining irregular-geometry
  fix except the stubs.
---
Work through the open irregular-geometry fixes. Leave hollow core, CLT/DLT/NLT, mass-timber joists, and non-composite deck as stubs. Leave vault springing stress documented for the Haile update.

Order: frame rectangular openings with headers and trimmers and warn; unframed openings warn and take a cantilever check; vaults stay warn-only. Beam rings carry the surrounding slab. Level-2 hosts and solid-head splits stay on this slab and story, and column solid heads are wired. Re-entrant drop panels stay in every quadrant. Sloped faces are refused except where a system already supports them. Deck girders get wet-concrete load from the bare-steel solve. Diaphragm, semirigid mesh, and center of mass see holes; flat-plate bars stay inside the slab and the takeoff matches the placed bars. Ingest rejects duplicate vertices and beams that cross without a joint, and matches an L or U by an interior point.

Each change gets a correctness check and a sensitivity check.
