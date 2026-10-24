---
id: note-1a0beb0c
type: note
project: menegroth
parent_id: deci-77a5062f
title: Remaining production gaps in per-station composite steel sizing
node_label: Composite gaps
tags: composite,steel,studs,deck,deflection,construction
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/composite/per_station.jl@b075af9, StructuralSizer/src/members/codes/aisc/checker.jl@bcfe7d3
session_id: sess-4ba6bb84
created_at: '2026-10-24T00:49:16.286994+00:00'
updated_at: '2026-10-24T00:49:16.286994+00:00'
has_child_rationale: User asked to preserve the known omissions before planning the
  next pass
---
Known gaps after wiring `SteelBeamOptions(composite=true)` into production sizing:

1. Stud transfer/detailing: strength currently assumes full composite action (`ΣQn = Cf`) and does not select the number, spacing, layout, or per-station accumulation of studs; the nominal anchor stored in the context therefore does not change flexural strength.
2. Negative moment: production wiring does not derive developed slab reinforcement `Asr`, `Fysr`, or negative-region anchor presence. It deliberately leaves `neg_moment=false`, so hogging remains Chapter F steel-alone even though the checker can evaluate §I3.2b when these inputs are supplied.
3. Construction stage: production defaults to unshored and checks the steel section against the full final moment envelope as a proxy for pre-composite load. It does not separate wet-concrete/construction loads from post-cure loads or expose a production shoring schedule.
4. Metal deck: production payload constructs `SolidSlabOnBeam`; it does not derive `DeckSlabOnBeam` geometry/orientation from floor data. The composite-deck floor sizing stub remains unimplemented.
5. Deflection: FEM deflection is scaled using one governing-section `I_LB` for the whole member. Spatial stiffness, cracked hogging regions, load-stage separation, creep/shrinkage, and vibration are not modeled.
6. Scope still to audit: shear-transfer longitudinal splitting/half-span conventions, candidate/group aggregation, beam-to-slab adjacency and material provenance, multi-material catalogs, edge/profile degeneracies, axial-H1 pairing with station demand, explain/trace parity, emissions/cost from studs, fire effects, serviceability/load combinations, and end-to-end design_building coverage.
