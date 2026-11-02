---
id: deci-7a357fe4
type: decision
project: menegroth
parent_id: deci-cedb2317
title: Frame-only 25% check uses the story geometric stiffness for P-delta
node_label: Frame-only 25% check uses the story geometric stif
tags: walls,phase-7,12.2.5.8,pdelta,frame-only,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-8c698d00
created_at: '2026-11-02T16:14:46.626237+00:00'
updated_at: '2026-11-02T16:14:46.626237+00:00'
---
Supersedes the P-delta line of deci-cedb2317 (user, 2026-11-02). The frame-only check solves on the story geometric stiffness K_G, not the 1/(1-theta) multiplier. Reasons: ASCE 7-22 12.8.7 (asce-7-22 PDF p. 188) requires rational analysis where theta > 0.10 and gives the multiplier as the alternative; the wall checks already use K_G, so both halves of 12.2.5.8 are on the same basis; K_G uses each combination's own factored gravity, while Eq. 12.8-18 limits Px factors to 1.0. Each factored-gravity K_G built in _build_story_second_order is reused (the story vertical load is the same in both models) and factored again on the frame-only system: about 4-5 factorizations. theta <= theta_max is still checked on the frame's own theta; 12.8.7 permits theta from the P-delta analysis to be divided by (1 + theta) first. Everything else in deci-cedb2317 stands.
