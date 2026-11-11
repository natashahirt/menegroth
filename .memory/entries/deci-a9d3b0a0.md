---
id: deci-a9d3b0a0
type: decision
project: menegroth
parent_id: plan-3986c866
title: Slab bars come from the story shell; beams stay on tributary loads
node_label: Shell sizes slab bars
tags: story-shell,slab,reinforcement,wood-armer,tributary
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-8d0fdf55
created_at: '2026-11-03T18:55:38.223750+00:00'
updated_at: '2026-11-03T19:28:13.980543+00:00'
has_child_rationale: The shell moment tensor is the slab demand. The same shell under-assigns
  force to the beam.
---
Slab reinforcement is designed from the story shell. Each panel's service dead and live pressures are combined with the flat-plate shell's load combinations and with generate_load_patterns (one span per panel). Unit pressure on each panel, plus beam self-weight, gives the moment field by superposition. Element moments are rotated to the span axes, negated out of Asap's hogging-positive convention, and passed through the existing Wood-Armer area design.

Beam flexure and shear stay on the tributary loads. shell_beam_forces remains a report beside that design. The shell is gross, and a composite steel beam is slip-reduced, so the frame force is smaller than the force beam design assumes. Using it would undersize the beam. ACI 318-11 §13.5.1 (aci-318-11, page 248) and §8.3.1 (page 112) are why the slab bars follow the elastic analysis. §13.6.8 is the Direct Design Method's tributary shear rule; it is not an extra demand on this shell.

design_floors! does not call the story shell, so an unshelled panel stays :not_analyzed.
