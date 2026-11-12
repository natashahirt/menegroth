---
id: chec-fc3c54b6
type: checkpoint
project: menegroth
parent_id: plan-c431a82d
title: Gravity-column hoops are spaced for the probable-moment shear
node_label: column Ve
tags: aci-318, gravity-column, 18.7.6, shear
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-878db501
created_at: '2026-11-12T14:07:33.986600+00:00'
updated_at: '2026-11-12T14:07:33.986600+00:00'
---
The gravity-column detail now computes §18.7.6 instead of waiting for a spacing.

Mpr is the nominal moment of the existing column P–M diagram rebuilt at 1.25 times the longitudinal yield strength, so φ stays 1 (R18.7.6.1.1, aci-318-19 PDF page 312). With a range of factored axial forces, the moment is the largest in that range. With none, it is the largest on the diagram. The same moment is used at both ends. Ve is that shear, capped by the beam-joint shear when one is passed, and never below the factored analysis shear (special_column_design_shear).

Over ℓo, Vc is set to 0 only when the earthquake-induced shear is at least half of Ve and the smallest compression in the range is below Ag f′c/20. Equality of that axial keeps Vc. The middle of the column is designed with Vc counted. The placed hoop spacing is the tighter of this shear spacing and the §18.7.5 confinement spacing.

Pass the column material to detail_column. Without it, the detail records that §18.7.6 was not computed. A section that cannot reach φVn is a warning, and the hoops stay at the closest spacing.

Detailing tests: 266 passed, 266 total.
