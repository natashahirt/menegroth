---
id: deci-e8a484b0
type: decision
project: menegroth
parent_id: deci-bb66c7e5
title: Joist depth is the stem below the slab
node_label: Stem depth, not total
tags: aci-318-11,joists,rib-depth
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7aebb121
created_at: '2026-11-06T03:01:36.793118+00:00'
updated_at: '2026-11-06T03:01:36.793118+00:00'
has_child_rationale: The 3.5 depth limit is on the rib stem. The slab thickness stays
  in its own check.
---
Refines the depth sentence in deci-bb66c7e5. ACI 318-11 §8.13.2 limits rib depth, and §8.13.1 treats the ribs and the top slab as separate parts (corpus: aci-318-11, PDF page 120). `JoistConstruction.rib_depth` is the stem from the bottom of the rib to the underside of the slab. Slab thickness is not added into that depth.

ACI 318-19 §9.8.1.3 calls the same 3.5 limit the overall depth of the ribs (corpus: aci-318-19, PDF page 153). The StructurePoint waffle example that applies that sentence uses a 14 in rib and a separate 3 in slab, 17 in total (sp-de-two-way-waffle-slab-aci318-14, PDF pages 12–13).

A prismatic `RCTBeamSection` builds the check as stem = h − hf and clear spacing = center-to-center spacing − bw. A tapered rib uses the positional constructor with its minimum width and its maximum clear spacing.

The waffle `min_thickness` span/22 value is unchanged. Its comment no longer cites ACI 318-11 §9.8, which is not the joist section in that edition. Tests: 30 passed.
