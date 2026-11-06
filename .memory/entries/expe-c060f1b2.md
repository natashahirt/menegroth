---
id: expe-c060f1b2
type: experiment
project: menegroth
parent_id: plan-dc2e3168
title: Deep-beam spandrel checks passed on the unit suite
node_label: deep beam unit pass
tags: walls,deep-beam,strut-and-tie,aci-318-19
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-51fed68a
created_at: '2026-11-06T11:31:00.872014+00:00'
updated_at: '2026-11-06T11:31:00.872014+00:00'
---
A short opening band (clear span ≤ 4h, route :stm) is checked as one deep beam: one corner-to-corner strut, one horizontal tie, the §9.9.2.1 shear limit, and §9.9.3.1 / Table 23.5.1 side reinforcement. analyze/test_wall_pier_checks.jl passed 112/112 in 27.8s (log test_StructuralSynthesizer_20261106_062804.log). A 1 m by 1 m band with V = 10 kN and M = 20 kN·m passed the five records (shear limit, side steel, strut, tie, node). V = 100 MN failed the shear limit. An ordinary beam check still throws on a :stm segment. The three-story office lintel test is running next. §6.6.4.6 is still not applied.
