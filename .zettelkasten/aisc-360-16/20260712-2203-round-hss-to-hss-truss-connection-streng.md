---
id: 20260712-2203-round-hss-to-hss-truss-connection-streng
title: "Round HSS-to-HSS truss connection strengths (\xA7K3, Table K3.1, Eq. K3-1\
  \ to K3-6)"
type: equation
source:
  page: "\xA7K3.2 Round HSS, Table K3.1 (AISC-360-16.pdf p.210; LaTeX transcribed\
    \ from rendered PDF page \u2014 OCR text layer corrupted)"
tags:
- equation
- clause:K3.2
- clause:K3-1
- clause:K3-2
- clause:K3-3
- clause:K3-4
- clause:K3-5
- clause:K3-6
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
- aisc-360-16#K3-1
- aisc-360-16#K3-2
- aisc-360-16#K3-3
- aisc-360-16#K3-4
- aisc-360-16#K3-5
- aisc-360-16#K3-6
grounding:
  verified: true
  method: render-validity
  valid: true
  locator: claimed
  page: "\xA7K3.2 Round HSS, Table K3.1 (AISC-360-16.pdf p.210; LaTeX transcribed\
    \ from rendered PDF page \u2014 OCR text layer corrupted)"
---

# Round HSS-to-HSS truss connection strengths (§K3, Table K3.1, Eq. K3-1 to K3-6)

\begin{aligned} P_n &= 0.6\,F_y\,t\,\pi D_b\left(\frac{1+\sin\theta}{2\sin^2\theta}\right) & (\text{K3-1, shear yielding/punching})\\ P_n\sin\theta &= F_y\,t^2(3.1 + 15.6\beta^2)\gamma^{0.2}Q_f & (\text{K3-2, T-/Y-, chord plastification})\\ P_n\sin\theta &= F_y\,t^2\left(\frac{5.7}{1-0.81\beta}\right)Q_f & (\text{K3-3, cross, chord plastification})\\ (P_n\sin\theta)_{comp} &= F_y\,t^2\left(2.0 + 11.33\,\frac{D_{b,comp}}{D}\right)Q_g\,Q_f & (\text{K3-4, K-conn.})\\ (P_n\sin\theta)_{tens} &= (P_n\sin\theta)_{comp} & (\text{K3-5})\\ Q_g &= \gamma^{0.2}\left[1 + \frac{0.024\,\gamma^{1.2}}{\exp(0.5g/t - 1.33) + 1}\right] & (\text{K3-6}) \end{aligned}
