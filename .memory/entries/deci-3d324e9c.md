---
id: deci-3d324e9c
type: decision
project: menegroth
parent_id: chec-dbb027b0
title: Curtain-wall weight is a line load on the edge that carries it
node_label: cladding on the carrying edge
tags: cladding,wall_SDL,flat-plate,load-path
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-37686af7
created_at: '2026-11-19T14:55:55.828071+00:00'
updated_at: '2026-11-19T14:55:55.828071+00:00'
has_child_rationale: User agreed a slab-edge line load is the right gravity path for
  curtain-wall weight.
---
wall_SDL stays the unfactored curtain-wall pressure (default 10 psf). Zero leaves the façade off. A structural wall or a pier that covers the band is still omitted, so the wall shell is not also given curtain-wall weight.

Gravity is one line load along the edge that actually carries the band, split half to each floor (engineering judgment; ASCE 7-22 §3.1.1 and §12.7.2 do not assign the band). On a beam-framed floor that edge is the perimeter beam, and the existing :cladding LineLoad stays. On a flat plate or flat slab the panel edge is a zero-stiffness frame placeholder, and a LineLoad on it reaches only the two end columns. The same intensity goes onto the shell nodes along that perimeter edge, so the slab bends and shears it to the columns. No edge beam is added.

Seismic weight and Px stay a separate lump: half of each band at the story elevations, with the base share left out of W. Strength cases keep the dead factor; service and foundation dead stay unfactored. Cladding is dead on every pattern case.

A fixture written to sit on the θ limit sets wall_SDL = 0. The production default stays 10 psf. The ordinary-wall P-delta building is that fixture: θ moved from under 0.125 to 0.129 because the default façade entered Px.
