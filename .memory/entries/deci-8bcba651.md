---
id: deci-8bcba651
type: decision
project: menegroth
parent_id: plan-c431a82d
title: Column and wall catalogs are hard or soft
node_label: Hard or soft catalogs
tags: columns,walls,catalog,sizing
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-955f6ace
created_at: '2026-11-14T19:39:05.757412+00:00'
updated_at: '2026-11-14T19:39:05.757412+00:00'
---
Concrete columns and beams, and the wall thickness grid, take catalog_constraint :hard or :soft. :soft is the default. A soft named column catalog merges the next tier and warns (:low_capacity → :standard → :high_capacity → :all). The first step off :standard or :square adds squares only. :hard errors inside the named catalog. A custom catalog is never grown. Beams use the same switch; their growth is unchanged when the constraint is soft.

The wall thickness catalog starts at wall_thickness_limit (36 in). :hard errors when nothing in it passes or a §18.10.6.4 shortfall is past it. :soft steps the limit by 12 in, warns, and errors at 72 in. It no longer clamps a shortfall to 36 in and continues.

Tests: StructuralSizer column and beam catalog growth 23/23; StructuralSynthesizer wall thickness jump 320/320.

Still open from the same pass: a pier with a flange at both ends, a pierced flanged segment taller than 1.5ℓw, one thickness for every wall in a group, the wall reinforcement ratchet, and flexible-diaphragm drift that fails open.
