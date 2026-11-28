---
id: chec-c04d083b
type: checkpoint
project: menegroth
parent_id: plan-267f93b4
title: RC objectives count ties and stirrups in kilograms
node_label: Ties and stirrups in kilograms
tags: rebar,ties,stirrups,objective
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7cc7a07f
created_at: '2026-11-13T23:14:41.190672+00:00'
updated_at: '2026-11-13T23:14:41.190672+00:00'
---
Discrete MinWeight and MinCarbon now add the ties, crossties, stirrups, or spiral on top of the longitudinal bars. Weight is kilograms for columns, beams, and T-beams. MinCost stays the gross volume.

Transverse steel is the amount the detailing places when shear does not close the spacing. Column ties use ACI 318-19 §25.7.2.1(b) plus §25.7.2.3 crossties. Spirals use Eq. (25.7.3.3), without the extra end turns. Beam stirrups use design_beam_shear at zero shear, which is the least steel that meets ACI 318-11 §11.4.6.3 and §11.4.5.1. A real shear can only put them closer.

The objective test passed 23/23. Loading it required including codes/aci/detailing.jl (hook centerline length) and columns/shear.jl (column_tie_legs); both files were already on the branch and unincluded. Recorded without files so the memory server does not pin the main checkout.
