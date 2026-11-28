---
id: plan-a40306be
type: plan
project: menegroth
parent_id: plan-ad399e86
title: 'Waffle ribs: per-piece sections, collinear shared bars, one floor flange,
  one head per column'
node_label: Per-piece ribs, collinear bars
tags: waffle,grillage,ribs,collinear,rebar,solid-head,detailing
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-af5499d1
created_at: '2026-11-13T20:02:10.014993+00:00'
updated_at: '2026-11-13T22:11:11.879789+00:00'
has_child_rationale: User set the rib sizing policy from the 2024 scripts after the
  grid waffle showed scattered sizes, uneven heads, and changing rebar along ribs.
---
Policy (user, 2026-11-13): size each component individually and optimally; shared elements such as rebar stay constant along collinear lines; when uniformity is required, size up to the largest element in the collinear set. The same collinearity rule will later govern steel ribs.

Decisions:
- One flange thickness hf for every rib of the floor: the thickest topping any bay requires. Per-bay thickness is ignored for now.
- A rib piece (node to node, one cell) is one sizing unit: its own bw and h from its own demand and its own ACI 318-11 §8.12 flange. The frame is already split at every crossing with rigid joints.
- Collinear sets are floor-wide and continue across girders. Geometry only, material agnostic.
- Bars: one bar size per set. Shared continuous bars = what the least-demanding piece needs. Each piece adds bars of the same size up to its own need (base plus local additions). Bottom and top handled separately. Stirrups per piece. Bars must fit the narrowest web where they run.
- Uniform mode: after per-piece sizing, raise each piece to the set's max bw and max h (independent maxima only add capacity), then re-check bars. Floor-wide variant over all ribs.
- Solid heads: one head per column grown across every bay that meets there. Head pieces enter design results, are detailed, and are drawn distinctly in the viewer.
- Rib detail = stem plus the shared slab drawn as the flange. Hogging bars at their real depth inside the topping mat; d used in sizing matches. §24.3.4 flange distribution check.

Corpus checks before code: §8.12 flange widths per piece, §8.13 joist limits with bw varying along a line, bar spacing in the narrowest web, development where a continuous bar passes a section change, §24.3.4.

Phases: (1) floor hf; (2) per-piece sizing units; (3) collinear sets and shared bars; (4) uniform mode; (5) per-column heads, head detailing; (6) rib detail and drawing; (7) viewer head display; then rebuild grid and star waffle scenes.

Also done this session: missing-bay face-hole fix (perimeter taken as a hole); mid-length section cut in the cage drawing (vertical strips were hook tails seen end-on).
