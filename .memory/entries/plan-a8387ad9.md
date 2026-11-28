---
id: plan-a8387ad9
type: plan
project: menegroth
parent_id: todo-701f6fca
title: 'Next special-boundary development: flange, spacing, continuity, then a composer'
node_label: Next boundary development
tags: walls,aci-318-19,18.10,boundary-element,plan
status: active
open_threads: 3
success: 'null'
files: ''
session_id: sess-f21322f7
created_at: '2026-11-10T14:54:47.458702+00:00'
updated_at: '2026-11-10T17:10:33.262407+00:00'
has_child_rationale: The geometry, drift, stress, and confinement-amount checks are
  in, so the next work is the remaining §18.10.6 limits before any bars or building
  wiring.
---
Same discipline as the checks already in: one clause group at a time, tests that show which limit governs, arguments stay arguments. No bars, special=true stays off, and design_ordinary_walls! stays ordinary. SDC D–F stays refused until deformation compatibility exists. Coupling beams (§18.10.7) are a separate member.

Done in plan-347b59e9: the (a) displacement trigger, vertical extension (b)(i), horizontal length (a), compression-zone width (b) and (c), drift capacity except (ii), the §18.10.6.3 stress cuts, and Table 18.10.6.4(g) as an amount.

1. Flange geometry, §18.10.6.4(d) (corpus: aci-318-19, page 327). In a flanged section the boundary element includes the effective flange width in compression and extends at least 12 in. into the web. That width comes from §18.10.5.2, which this pass has not implemented. Read 18.10.5.2 first, then a check that reports the web extension and whether the flange is inside the element.

2. Spacing limits that do not place bars. §18.10.6.4(e): transverse spacing from 18.7.5.2(a)–(d) and 18.7.5.3, with the 18.7.5.3(a) limit reset to one-third of the least boundary-element dimension, and a second cap from Table 18.10.6.5(b) (page 328). §18.10.6.4(f): hx not exceeding the lesser of 14 in. and two-thirds of the boundary-element thickness.

3. Continuity limits, still as checks. (h) floor concrete at the boundary element at least 0.7 f′c of the wall. (i) web vertical bars laterally supported over the 18.10.6.2(b) distance, spacing ≤ 12 in. (j) into the support at least ℓd per 18.10.2.3, and into a footing, mat, or pile cap at least 12 in. unless 18.13.2.4 requires more. (k) horizontal web reinforcement to within 6 in. of the wall end, anchored to develop fy in the confined core.

4. Two expressions stay uncoded until the glyphs are confirmed. §18.10.6.2(b)(ii) is still split in the text layer as b ≥ 0.025ℓ with the subscripts on the next line; the commentary says it is derived from Eq. (18.10.6.2b). §18.10.6.5(a) is missing the radical on λ√f′c. After those are confirmed, code the path for when a special boundary element is not required.

5. A composer over the checks already written: required or not, horizontal length, width, vertical extent, and Ash/(s bc) or ρs. Still no bars. Bar placement, special=true, and opening SDC D–F wait on that composer plus a published example and deformation compatibility.
