---
id: deci-52e08be1
type: decision
project: menegroth
parent_id: plan-19b46cbe
title: Discrete beam sizing requires As,min; the published check keeps §10.5.3
node_label: Discrete beam sizing requires As,min; the publishe
tags: waffle,beams,min-reinforcement,aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-da054dbc
created_at: '2026-11-25T00:27:55.668490+00:00'
updated_at: '2026-11-25T00:27:55.668490+00:00'
---
Discrete T-beam sizing, rectangular beam sizing, and rib-set selection set ACIBeamChecker.size_to_as_min. A candidate that analysis says needs tension steel is rejected when As < As,min (ACI 318-11 §10.5.1 Eq. 10-3, page 144). ENGINEERING JUDGMENT: §10.5.3 (page 145) still waives that minimum in the published check, including check_tbeam_section and the settle report, because the waiver is legal for a finished moment. Sizing does not take it, because the moment of the current pass can rise until the waiver drops.

The member loop's installed-design verify is unchanged and still does not resize. Collinear sharing is unchanged: a shared section already has to meet As,min, and the section it keeps now comes from a sizer that does too.

Tested: StructuralSizer concrete_beam/test_tbeam.jl, 68 passed. A two-#5 section under As,min still passes the checker on a light moment via §10.5.3, and both discrete sizers throw on a catalog of only that section and return the bar count that meets As,min when it is available. explain_feasibility still agrees with is_feasible when the switch is off.
