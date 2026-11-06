---
id: chec-85eecada
type: checkpoint
project: menegroth
parent_id: plan-0501eab9
title: Tributary profiles conserve net floor area, including openings
node_label: Exact tributary profiles
tags: tributary,asap,one-way,two-way,openings,balance
status: active
open_threads: 0
success: 'null'
files: external/Asap/src/Tributary/utils.jl@4a17325, external/Asap/src/Tributary/one_way.jl@4a17325,
  external/Asap/src/Tributary/isotropic/api.jl@4a17325, external/Asap/src/Tributary/_tributary.jl@4a17325,
  external/Asap/src/Loads/shell_loads/depth_profiles.jl@4a17325, external/Asap/test/tributary/test_tributary_balance.jl@4a17325,
  external/Asap/test/runtests.jl@4a17325
session_id: sess-7b8c7796
created_at: '2026-11-06T21:37:01.757906+00:00'
updated_at: '2026-11-06T21:37:01.757906+00:00'
---
Each TributaryPolygon now carries the load profile the partition computed, and every consumer reads that instead of rebuilding a width from the drawing outline and clamping it.

One-way width is the strip depth along the span times the sine of the beam angle, so a skewed edge keeps its whole strip. An opening edge carries nothing: a one-way strip ending on an opening goes to the beam at the other end, and a strip between two openings throws. Two-way regions lose the part inside an opening. A face an opening fills is not a cell. At a re-entrant corner the wedge past a beam end is mirrored back onto that beam beside the support.

Asap throws if a profile misses its area or the areas miss the net floor. On all 13 Slab Design Factors plans, both systems, beam area matches the polygons and beam load matches cell load. Two-way polygons sit within 1.4e-5 m² of the net floor, which is the skeleton's own precision.

The Asap commit also lands the module splits and line-ending normalization that were already dirty in that tree. The Synthesizer and Studies sides of this change are not in that commit.
