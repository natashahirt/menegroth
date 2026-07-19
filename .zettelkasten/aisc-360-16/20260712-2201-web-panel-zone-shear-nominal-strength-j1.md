---
id: 20260712-2201-web-panel-zone-shear-nominal-strength-j1
title: "Web panel-zone shear nominal strength (\xA7J10.6, Eq. J10-9 to J10-12)"
type: equation
source:
  page: "\xA7J10.6, Eq. J10-9 to J10-12 (AISC-360-16.pdf p.202)"
tags:
- equation
- clause:J10.6
- clause:J10-9
- clause:J10-10
- clause:J10-11
- clause:J10-12
- family:aisc
- edition:aisc-360-16
- role:codes
- tier:1
- limit-state:panel-zone-shear
links:
- target: 20260712-1906-aisc-360-equation
  relation: input-to
  direction: outgoing
  graph: aisc-360-canon
aliases:
- aisc-360-16#J10-9
- aisc-360-16#J10-10
- aisc-360-16#J10-11
- aisc-360-16#J10-12
- aisc-360-16#J10.6
grounding:
  verified: true
  method: render-validity
  valid: true
  locator: claimed
  page: "\xA7J10.6, Eq. J10-9 to J10-12 (AISC-360-16.pdf p.202)"
---

# Web panel-zone shear nominal strength (§J10.6, Eq. J10-9 to J10-12)

\begin{aligned} R_n &= 0.60\,F_y\,d_c\,t_w & (\text{J10-9},\ \alpha P_r \le 0.4P_y)\\ R_n &= 0.60\,F_y\,d_c\,t_w\left(1.4 - \frac{\alpha P_r}{P_y}\right) & (\text{J10-10},\ \alpha P_r > 0.4P_y)\\ R_n &= 0.60\,F_y\,d_c\,t_w\left(1 + \frac{3 b_{cf} t_{cf}^2}{d_b d_c t_w}\right) & (\text{J10-11, inelastic},\ \alpha P_r \le 0.75P_y)\\ R_n &= 0.60\,F_y\,d_c\,t_w\left(1 + \frac{3 b_{cf} t_{cf}^2}{d_b d_c t_w}\right)\left(1.9 - \frac{1.2\,\alpha P_r}{P_y}\right) & (\text{J10-12},\ \alpha P_r > 0.75P_y) \end{aligned}
