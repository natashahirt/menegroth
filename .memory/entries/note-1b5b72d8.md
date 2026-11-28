---
id: note-1b5b72d8
type: note
project: menegroth
parent_id: note-47cbe98a
title: Added capabilities/archetype section + steel-high-rise gap list to sizing-map
  README
node_label: Added capabilities/archetype section + steel-high-
tags: sizing-map,capabilities,archetypes,steel,high-rise,phase-h,docs
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/README.md@bebf1dc
session_id: sess-3b801976
created_at: '2026-11-23T17:17:40.988878+00:00'
updated_at: '2026-11-23T17:17:40.988878+00:00'
has_child_rationale: Records the new capability table + the steel high-rise roadmap
  synthesis added to the map
---
Added an unnumbered 'Capabilities and building archetypes' section to docs/sizing-map/README.md (before §1 Stage graph): (a) by-element-type status table (full/partial/none), (b) building-archetype support table, (c) a ranked 'what's left for steel high-rise' list.

Steel high-rise blockers (grounded in Phase H plan-cecee16b + code): (1) no steel LFRS designer — lateral is concrete walls only; needs braced frames [H1] + moment frames w/ panel zones [H2]; OutriggerSystem typed-but-not-implemented. (2) sway/B2/design_column_moments bridge built but not consumed. (3) drift as a sizing driver + lateral-system selection [H4]. (4) AISC 341/358 seismic capacity design [H3, needs corpus ingestion]. (5) deep foundations + lateral-loads-reach-foundations (§6 item 4) [Phase G]. (6) dynamic/cross-wind + occupant comfort. (7) composite columns (CFT/encased). Items 1-3 = minimum for strength+drift steel frame in low seismic/ordinary wind.
