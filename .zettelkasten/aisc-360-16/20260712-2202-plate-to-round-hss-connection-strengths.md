---
id: 20260712-2202-plate-to-round-hss-connection-strengths
title: "Plate-to-round-HSS connection strengths (\xA7K2, Table K2.1, Eq. K2-1a to\
  \ K2-4)"
type: equation
source:
  page: "\xA7K2, Table K2.1 (AISC-360-16.pdf p.207; round-HSS forms transcribed from\
    \ rendered PDF page)"
tags:
- equation
- clause:K2
- clause:K2-1a
- clause:K2-1b
- clause:K2-2a
- clause:K2-2b
- clause:K2-3
- clause:K2-4
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
- aisc-360-16#K2-1a
- aisc-360-16#K2-1b
- aisc-360-16#K2-2a
- aisc-360-16#K2-2b
- aisc-360-16#K2-3
- aisc-360-16#K2-4
grounding:
  verified: true
  method: render-validity
  valid: true
  locator: claimed
  page: "\xA7K2, Table K2.1 (AISC-360-16.pdf p.207; round-HSS forms transcribed from\
    \ rendered PDF page)"
---

# Plate-to-round-HSS connection strengths (§K2, Table K2.1, Eq. K2-1a to K2-4)

\begin{aligned} R_n\sin\theta &= F_y\,t^2\left(\frac{5.5}{1 - 0.81\,B_b/D}\right)Q_f & (\text{K2-1a, local yielding, axial})\\ M_n &= 0.5\,B_b\,R_n & (\text{K2-1b, out-of-plane bending})\\ R_n\sin\theta &= 5.5\,F_y\,t^2\left(1 + 0.25\,\frac{l_b}{D}\right)Q_f & (\text{K2-2a, plastification, axial})\\ M_n &= 0.8\,l_b\,R_n & (\text{K2-2b, in-plane bending})\\ Q_f &= 1.0 - 0.3\,U(1+U) & (\text{K2-3, compression; }=1\text{ tension})\\ U &= \left|\frac{P_{ro}}{F_c A_g}\right| + \left|\frac{M_{ro}}{F_c S}\right| & (\text{K2-4}) \end{aligned}
