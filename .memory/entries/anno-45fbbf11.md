---
id: anno-45fbbf11
type: annotation
project: menegroth
parent_id: plan-b2670c25
title: 'User preference: always pick the ''proper'' (code-correct) option over the
  blanket-conservative one'
node_label: 'User preference: always pick the ''proper'' (code-co'
tags: preference,engineering-judgment
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-5e63661e
created_at: '2026-10-21T02:25:32.406464+00:00'
updated_at: '2026-10-21T02:25:32.406464+00:00'
---
When a choice exists between a blanket-conservative shortcut and the proper, code-grounded method, implement the proper method, provided the source exists in the corpus. Use a conservative fallback only when the proper mechanics cannot be grounded, and label it ENGINEERING JUDGMENT. Examples confirmed 2026-10-20: drop the double-counted column hogging check in favour of a single AISC 360-16 Chapter F check with the actual Lb and Cb per §F1 Eq. F1-1; implement edge-column biaxial punching from PCA EB712 Fig. 16-13 (p.486); adopt the ACI 318-11 §13.7.6.3 0.75L pattern for EFM slabs with the §13.7.6.4 floor; add the §8.11.2 adjacent-span pattern to the frame path; composite §I3.1a effective width from the minimum spacing over the middle half of the span, with a per-beam override (still a design proposal); forward Pu_t to the steel checker for columns and beams, with concurrent P-M pairs and an §H1.2 tension + hogging check.
