---
id: chec-f5c605b8
type: checkpoint
project: menegroth
parent_id: deci-63970067
title: Rigid footing gate uses ACI 336.2R Eq. 5-1 and Eq. 5-3
node_label: Kr and lambda
tags: foundations,aci-336,kr,lambda,rigid,winkler
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-87953a16
created_at: '2026-11-12T14:46:04.958303+00:00'
updated_at: '2026-11-12T14:46:04.958303+00:00'
---
Implemented in the row-f-nlp worktree, not yet committed.

wall_footing_kr is ACI 336.2R §5.2 Eq. (5-1) and (5-2), corpus aci-336-combined-footings-mats, PDF page 8. Kr = E' I_B / (Es B^3). I_F = h^3/12 per unit width so Kr stays dimensionless (§1.1, PDF page 2, says Kr is dimensionless; the printed ℓ^4 on I_F and I_B does not). Each wall adds (t_w h_w^3/12)/B. The framed-member sum is omitted: the footing call does not receive beam stiffness. That omission is engineering judgment.

footing_lambda is §5.3 Eq. (5-3), PDF page 9, with the 2026-11-07 ruling (deci-8b45eb4b): K_s = k_s B and I = B h^3/12. B cancels. The 1.75/λ and 20% gates were already written.

A mat that fails the gate still falls back to Winkler when on_inapplicable is :fallback and soil.ks is set. The method-comparison tests call the strip designer directly so they still measure strip steel. Hand checks passed 7/7.

Shukla and Winkler results now record analysis :shukla and :winkler.
