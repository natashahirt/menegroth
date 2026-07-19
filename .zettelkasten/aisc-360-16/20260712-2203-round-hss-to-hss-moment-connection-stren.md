---
id: 20260712-2203-round-hss-to-hss-moment-connection-stren
title: "Round HSS-to-HSS moment connection strengths (\xA7K4, Table K4.1, Eq. K4-1\
  \ to K4-6)"
type: equation
source:
  page: "\xA7K4, Table K4.1 (AISC-360-16.pdf p.215; LaTeX transcribed from rendered\
    \ PDF page \u2014 OCR text layer corrupted)"
tags:
- equation
- clause:K4
- clause:K4-1
- clause:K4-2
- clause:K4-3
- clause:K4-4
- clause:K4-5
- clause:K4-6
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
- aisc-360-16#K4-1
- aisc-360-16#K4-2
- aisc-360-16#K4-3
- aisc-360-16#K4-4
- aisc-360-16#K4-5
- aisc-360-16#K4-6
grounding:
  verified: true
  method: render-validity
  valid: true
  locator: claimed
  page: "\xA7K4, Table K4.1 (AISC-360-16.pdf p.215; LaTeX transcribed from rendered\
    \ PDF page \u2014 OCR text layer corrupted)"
---

# Round HSS-to-HSS moment connection strengths (§K4, Table K4.1, Eq. K4-1 to K4-6)

\begin{aligned} M_{n\text{-}ip}\sin\theta &= 5.39\,F_y\,t^2\,\gamma^{0.5}\beta D_b\,Q_f & (\text{K4-1, in-plane, chord plastification})\\ M_{n\text{-}ip} &= 0.6\,F_y\,t\,D_b^2\left(\frac{1+3\sin\theta}{4\sin^2\theta}\right) & (\text{K4-2, in-plane, punching})\\ M_{n\text{-}op} &= \frac{F_y\,t^2 D_b}{\sin\theta}\left(\frac{3.0}{1-0.81\beta}\right)Q_f & (\text{K4-3, out-of-plane, chord plast.})\\ M_{n\text{-}op} &= 0.6\,F_y\,t\,D_b^2\left(\frac{3+\sin\theta}{4\sin^2\theta}\right) & (\text{K4-4, out-of-plane, punching})\\ \frac{P_u}{\phi P_n} + \left(\frac{M_{r\text{-}ip}}{\phi M_{n\text{-}ip}}\right)^2 + \frac{M_{r\text{-}op}}{\phi M_{n\text{-}op}} &\le 1.0 & (\text{K4-5, LRFD combined})\\ \frac{P_a}{P_n/\Omega} + \left(\frac{M_{r\text{-}ip}}{M_{n\text{-}ip}/\Omega}\right)^2 + \frac{M_{r\text{-}op}}{M_{n\text{-}op}/\Omega} &\le 1.0 & (\text{K4-6, ASD combined}) \end{aligned}
