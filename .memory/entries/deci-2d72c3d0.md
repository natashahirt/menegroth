---
id: deci-2d72c3d0
type: decision
project: menegroth
parent_id: plan-c431a82d
title: Two-flange walls and in-segment return bars; empty flexible drift fails
node_label: Two-flange walls and in-segment return bars; empty
tags: walls,aci318,18.10.5.2,22.2.2.4.1,flange,flexible-diaphragm,drift
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-955f6ace
created_at: '2026-11-14T20:19:07.151262+00:00'
updated_at: '2026-11-14T20:19:07.151262+00:00'
has_child_rationale: The catalog decision left the two section stops and the unchecked
  flexible drift open.
---
A pier with a return at each end is one section. The Whitney block is ACI 318-19 §22.2.2.4.1 (aci-318-19, page 400): 0.85f′c over the zone bounded by the edges of the cross section and a line parallel to the neutral axis at a = β1 c. Width is bf inside each flange and tw in the web. The web–flange corner is counted once. Each flange width is the §18.10.5.2 overhang already used for one flange (page 325). A second end whose width equals the web and whose bars are zero reproduces the one-flange result.

A pierced segment taller than 1.5ℓw stays its own rectangle. Only return bars whose station along the web falls inside the segment enter Mpr and the §21.2.4.1 shear at Mn. Bars that fill the segment are smeared with the web steel. The gross pier's flange concrete is not attached. Passing flanged=true with no bar geometry still throws.

A flexible lateral floor whose story-drift list is empty fails the design summary ("was not checked"). Gravity-only designs stay empty and passing. Drift at the center of mass between wall lines was already computed; this closes the empty-list pass. θ > 0.10 on a flexible floor still refuses, because member forces are first-order and the §12.8.7 1/(1−θ) alternative is not applied to those forces.

Tests: StructuralSizer flanged section 65/65. StructuralSynthesizer special boundary, special shear (including a three-story pier with flanges at both ends and pierced upper stories), and diaphragm idealization: the shear file 1411/1411, and the combined run 1866 passed with the one named-tuple error fixed on the rerun.

Not done: wall grouping :all, the ρ ratchet, and multiplying flexible-floor member forces by 1/(1−θ).
