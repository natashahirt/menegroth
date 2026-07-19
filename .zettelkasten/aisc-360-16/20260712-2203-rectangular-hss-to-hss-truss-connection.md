---
id: 20260712-2203-rectangular-hss-to-hss-truss-connection
title: "Rectangular HSS-to-HSS truss connection strengths (\xA7K3.3, Table K3.2, Eq.\
  \ K3-7 to K3-12)"
type: equation
source:
  page: "\xA7K3.3, Table K3.2 (AISC-360-16.pdf p.211-212)"
tags:
- equation
- clause:K3.3
- clause:K3-7
- clause:K3-8
- clause:K3-9
- clause:K3-11
- clause:K3-12
- family:aisc
- edition:aisc-360-16
- role:codes
- tier:1
- limit-state:hss-connection
links:
- target: 20260712-1906-aisc-360-equation
  relation: input-to
  direction: outgoing
  graph: aisc-360-canon
aliases:
- aisc-360-16#K3-7
- aisc-360-16#K3-8
- aisc-360-16#K3-9
- aisc-360-16#K3-11
- aisc-360-16#K3-12
grounding:
  verified: true
  method: render-validity
  valid: true
  locator: claimed
  page: "\xA7K3.3, Table K3.2 (AISC-360-16.pdf p.211-212)"
---

# Rectangular HSS-to-HSS truss connection strengths (§K3.3, Table K3.2, Eq. K3-7 to K3-12)

\begin{aligned} P_n\sin\theta &= F_y\,t^2 (9.8\,\beta_{eff}\,\gamma^{0.5})Q_f & (\text{K3-7, chord wall plastification})\\ P_n\sin\theta &= 0.6\,F_y\,t\,B\,(2\eta+\beta+\beta_{eop}) & (\text{K3-8, punching shear})\\ P_n &= F_{yb}\,t_b\,(2H_b + B_b + B_e - 4t_b) & (\text{K3-9, branch yielding})\\ P_{n,i} &= F_{ybi}\,t_{bi}(2H_{bi} - 4t_{bi} + B_{ei} + B_{ej}) & (\text{K3-11, }50\%\le O_v<80\%)\\ P_{n,i} &= F_{ybi}\,t_{bi}(2H_{bi} - 4t_{bi} + B_{bi} + B_{ej}) & (\text{K3-12, }80\%\le O_v\le100\%) \end{aligned}
