---
id: expe-80ebb8bf
type: experiment
project: menegroth
parent_id: plan-a6412144
title: Flexible story force uses one builder and stays first-order
node_label: Flexible story force
tags: walls,diaphragm,flexible,force-path
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-fcb6e9ee
created_at: '2026-11-06T15:46:54.377959+00:00'
updated_at: '2026-11-06T15:46:54.377959+00:00'
---
One builder places a story force. With rigid links, the force and the accidental torsion stay on the master. Without them, each floor's (Fx, Fy) is split by the stored tributary area of the columns and walls whose top is that floor. A column takes one node force. A wall takes a uniform line load on its top-edge shell nodes, integrated with the edge shape functions; the tributary width is not integrated again. A zero area receives nothing. A strut still throws. The 5% accidental eccentricity is not applied on a flexible diaphragm, and a semirigid shell diaphragm is refused. to_asap! still writes no story force.

The ordinary-wall lateral stage no longer requires rigid masters. A flexible run stays first-order: no story stiffness, no rigid-floor drift, and θ is reported as unset (0, with an empty drift list). The wall share of unfactored dead load is the first-order story cut. Row F still requires the story stiffness.

A beam lintel and a deep-beam lintel now share one pair of end cuts, and both write the owner wall's reinforcement back onto the segment.

Tests: diaphragm idealization 87/87, log test_StructuralSynthesizer_20261106_104223.log. ELF, wind, and the rigid office piers 293/293, log test_StructuralSynthesizer_20261106_104326.log. The 10×6 office ground wall at y=0 keeps 30 m²; upper walls with an empty complement take no force; a walls-only office sums to the story force; design_ordinary_walls! on the flexible office returns.
