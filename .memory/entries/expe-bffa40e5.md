---
id: expe-bffa40e5
type: experiment
project: menegroth
parent_id: expe-750f0a5d
title: v5 wall thickness is the slab-growth ratchet, and v6 keeps it
node_label: v5 walls thickened because the slab ratchet stuck
tags: core-office,v5,v6,wall-thickness,tributary
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-8f6d4b5d
created_at: '2026-11-08T20:33:44.648581+00:00'
updated_at: '2026-11-08T20:33:44.648581+00:00'
---
v5 and v6 both set every wall to 0.4826 m (19 in). v4 was 0.4064 m (16 in). The jump is the gravity-only ordinary-wall stage, grouping :all, one pass. After it, out-of-plane P-M sits at 0.97 to 1.00, so 19 in is the first inch that passes.

Two demands moved between v4 and v5. Roof-slab thickness stayed 0.2667 m, but the roof-level wall out-of-plane moments rose about 70 percent: the parked core-corner columns no longer take that slab edge. The three floor slabs went from 0.381 / 0.406 / 0.318 m to 0.521 m. During sizing a corner column at the 30 in cap had a punching ratio of about 1.69, and the grow-slab strategy raised h. h does not come back down. The finished columns are 21 in with punching near 0.54, so the 20.5 in floors are what the ratchet left behind. Their self-weight raises the wall moments on the stories below.

v6 recomputed the tributary split (columns 384 m2 and walls 148 m2 per floor; roof columns 384 and walls 192, including the interior walls). The design log matches v5, including the punching ratio 1.6903461434039344. The column that trips the ratchet is not one of the columns the wall split changed.

A tee split now divides the wall's tributary onto each piece. Width pieces are clipped to the piece and rewritten from its start. Area beyond the width law, the edge strip, is divided by length, and the strip cache is retargeted when to_asap! passes it.
