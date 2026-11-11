---
id: deci-610bd5f9
type: decision
project: menegroth
parent_id: deci-3a2bf98e
title: Hogging rebar counts only with the negative-region anchor strength
node_label: Hogging rebar counts only with the negative-region
tags: composite,phase-5,asr,hogging,aisc
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-138f33cf
created_at: '2026-10-26T20:43:54.683563+00:00'
updated_at: '2026-10-27T13:42:06.320300+00:00'
---
Phase 5 closes on these calls.

Asr stays one caller-supplied area: the longitudinal reinforcement inside b_eff at the section of maximum negative moment. asr_at_section places a strip band and keeps one location (:ext_neg or :int_neg). The building path does not read a flat-plate panel, because the panel does not store where the strip sits relative to the beam. A positive Asr asserts the bars at that section are developed (AISC 360-22 §I3.2b(c), PDF p. 170). Development length is not computed; strip totals do not carry bar lengths.

ΣQn_neg is the nominal strength of the anchors between that maximum negative moment and the adjacent zero (§I3.2d.2 Eqs. I3-2a and I3-2b, PDF p. 171). The sagging stud total is not that sum. A missing ΣQn_neg keeps hogging on Chapter F, including when neg_moment is set and reinforcement is present. Supplying a sum that can develop the bars uses the composite plastic strength when the section is compact and Lb ≤ Lp.

Left for later phases, not changed here: Lbr for continuous deck is still undefined, so brace stiffness stays unevaluated. The omitted-stud Fu = 65 ksi default is still not built. SEI/ASCE 37-02 stays flagged as older than 37-14. Commentary Eq. C-F1-5 still uses the member span because the moment field does not record twist restraints. Skewed ribs stay out.

Phases 3, 4, 4b, and 5 land in one commit. The same files carry those phases, so they are not split.
