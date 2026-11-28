---
id: todo-5c7ae728
type: todo
project: menegroth
parent_id: plan-b0095736
title: Deformation compatibility for SDC D–F waits on induced actions from δDE
node_label: Deformation compatibility for SDC D–F waits on ind
tags: asce-7-22,aci-318-19,deformation-compatibility,sdc,18.14
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d0c1ea81
created_at: '2026-11-06T14:14:34.694348+00:00'
updated_at: '2026-11-06T14:14:34.694348+00:00'
---
ASCE 7-22 §12.12.4 (corpus: asce-7-22, PDF p. 195) requires every structural component not in the seismic force-resisting system, for Seismic Design Category D, E, or F, to be designed for gravity load effects and for the seismic forces from the Design Earthquake Displacements δDE and the associated drifts of §12.8.6. The exception sends a reinforced concrete frame member that is not part of the system to ACI 318 §18.14. Stiffening from adjoining rigid structural and nonstructural elements shall be considered, with a rational member stiffness.

ACI 318-19 §18.14.1.1 (corpus: aci-318-19, PDF p. 353) applies to members not designated as part of the system in SDC D, E, or F. §18.14.2.1 evaluates them for the §5.3 gravity combinations, including vertical ground motion, acting with the design displacement δu. §18.14.3.1: if the moments and shears induced by δu are not calculated, §18.14.3.3 applies (special-moment-frame materials and detailing). §18.14.3.2 is the lighter transverse reinforcement, and it applies only when those induced actions are calculated and do not exceed the member strengths. §18.14.5 is the slab-column drift gate and does not require induced moments.

What is already stored: ELF design displacement δDE at the center of mass with δdi = 0, and the design story drift. WallsSeismicSystem marks every wall in the system and every beam and column out of it. Concrete gravity members stay monolithic in the analysis, so the force solve already shares some lateral load with them. That share is not the force from imposing δDE.

Not enough to build the check. The induced moments and shears from imposing δDE on the gravity members are not computed. The special detailing in §18.14.3.3 (18.6.5, 18.7.4, 18.7.5, 18.7.6, 18.4.4.1) is not built. Nonstructural stiffness is not in the model. Do not treat the stored center-of-mass drift as those induced actions. The slab-column gate in §18.14.5 is the only slice whose inputs, story drift ratio and gravity punching stress, already exist, and it is not this check.

The stage still throws for SDC D, E, or F. Leave the throw until the induced-action path exists.
