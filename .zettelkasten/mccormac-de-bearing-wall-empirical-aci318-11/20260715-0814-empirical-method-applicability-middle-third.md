---
id: 20260715-0814-empirical-method-applicability-middle-third
title: Empirical method applicability — middle-third eccentricity
type: concept
source:
  page: '549'
tags:
- applicability
- family:aci
- edition:aci-318-11
- role:textbooks
- tier:2
links:
- target: 20260713-0610-aci-318-applicability
  relation: input-to
  direction: outgoing
  graph: aci-318-canon
---

# Empirical method applicability — middle-third eccentricity

The empirical method may be used only if the resultant of all factored loads
falls within the middle third of the wall — i.e. eccentricity `e ≤ h/6`, and
the section is solid rectangular. For non-rectangular sections (e.g. ribbed
panels) or `e > h/6`, the rational column axial+bending procedure (code §14.4)
must be used; very slender walls use the §14.8 alternative method. The method
is intended for relatively short walls with approximately concentric loads
(lateral loads quickly push `e` past `h/6`). These gates are enforced in
`check_wall_bearing_empirical`.
