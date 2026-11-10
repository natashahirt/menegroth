---
id: deci-598f8d2b
type: decision
project: menegroth
parent_id: plan-a8387ad9
title: §18.10.6.2(b)(ii) is b ≥ √(0.025 ℓw c), and §18.10.6.5(a) is λ√f′c Acv
node_label: Radicals confirmed
tags: walls,aci-318-19,18.10,boundary-element,corpus,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ad654b18
created_at: '2026-11-10T17:10:33.262407+00:00'
updated_at: '2026-11-10T17:10:33.262407+00:00'
has_child_rationale: The two expressions the plan held back are now readable, so (ii)
  and §18.10.6.5 can be coded.
---
Both expressions were read from the rendered PDF, not the text layer. The radical is a drawn rule, so the text extraction drops it.

- §18.10.6.2(b)(ii), ACI 318-19 PDF page 326: b ≥ √(0.025 ℓw c). The radical covers 0.025ℓc with the w subscript on ℓ. Lead-in (page 326): if (a) requires a special boundary element, (i) and either (ii) or (iii) shall be satisfied. So (ii) is a shortcut: meeting it means (iii) need not be checked.
  Consistency with the commentary: setting Ve/(8 f′c Acv) = 1 and δu/hwcs = 0.015 in Eq. (18.10.6.2b) with δc/hwcs = 1.5 × 0.015 gives b² = ℓw c / 37.5 ≈ 0.0267 ℓw c, near 0.025.
  Published check: NEHRP 2020 Design Examples Vol. 1 (corpus: nehrp-2020-design-examples-v1, PDF page 158) writes b (= 26 in.) ≥ √(0.025 c ℓw) = √(0.025 × 95 × 164) and concludes (iii) is not necessary. The example prints 19.3 in.; the arithmetic is 19.74 in. The conclusion is the same.
- §18.10.6.5(a), PDF page 332: hooks or U-stirrups except where Vu in the plane of the wall is less than λ√f′c Acv. The radical covers f′c only. detail_wall's _wall_hook_free_ends already uses that term.

The corpus text still lacks both radicals; code comments cite the page and say the radical was read from the rendered page.
