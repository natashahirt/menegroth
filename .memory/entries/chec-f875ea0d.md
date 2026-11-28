---
id: chec-f875ea0d
type: checkpoint
project: menegroth
parent_id: plan-8b00b305
title: 'Phase A done: FootingLoads container + unified design_footing, migrated +
  equivalence-tested'
node_label: 'Phase A done: FootingLoads container + unified des'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/loads.jl@68991c0, StructuralSizer/src/foundations/_foundations.jl@68991c0,
  StructuralSizer/src/StructuralSizer.jl@68991c0, StructuralSizer/test/foundations/test_footing_loads.jl@68991c0,
  StructuralSizer/test/runtests.jl@68991c0, StructuralSynthesizer/src/analyze/foundations/size_isolated.jl@68991c0,
  StructuralSynthesizer/src/analyze/foundations/wall_groups.jl@68991c0, StructuralSynthesizer/src/analyze/foundations/grouping.jl@68991c0
session_id: sess-278ee43a
created_at: '2026-11-26T04:32:32.914574+00:00'
updated_at: '2026-11-26T04:32:32.914574+00:00'
---
Phase A of the footing-API unification is complete and behavior-neutral.

Done:
- StructuralSizer/src/foundations/loads.jl: FootingLoads struct + footing_loads(...) constructor with inner-constructor invariants (length/label alignment of column actions, wall-case alignment, wall-vs-column case-count match on mats), accessors, and _narrow_positions to re-type homogeneous abstract vectors so they dispatch to the strict positional methods.
- Unified design_footing(::SpreadFooting/::StripFooting/::MatFoundation, loads::FootingLoads, soil; opts, ...) methods that unpack FootingLoads and delegate to the existing positional designers. Exported FootingLoads + footing_loads.
- Migrated Synthesizer call sites to build FootingLoads and call the unified entry: size_isolated.jl (spread/strip/mat), wall_groups.jl (mat/strip grade walls), grouping.jl (grouped spread).

Verification (all green, via StructuralSizer test server on 18400):
- NEW test/foundations/test_footing_loads.jl: 7 assertions proving footing_loads+unified reproduces the positional call exactly (spread w/ & w/o combos, column strip, flexible mat via Winkler, wall strip) + rejection guards for misaligned inputs. Added to runtests.jl.
- Sizer foundation suite: spread 44, strip 13, wall_footing 41, mat_rigid_statics 10, wall_strip 16.
- Synthesizer analyze/test_wall_foundations.jl: 24.

Not yet committed. Next: Phase B (extract shared plan engine: centroid-on-gravity-resultant, kern/_eccentric_soil_pressure, length-vs-width step growth, envelope) called by spread/strip/mat/wall.
