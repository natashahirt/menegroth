---
id: deci-bd727faa
type: decision
project: menegroth
parent_id: todo-15a5fe44
title: 'Slenderness split: advisory §E2/§D1 as :warn in base axial sizer (default);
  mandatory AISC 341 brace limits in the step-4 seismic module'
node_label: 'Slenderness split: advisory §E2/§D1 as :warn in ba'
tags: axial-member,slenderness,aisc,chapter-e,chapter-d,aisc-341,scbf,phase-h,step-4,resolved-approach
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ddbef912
created_at: '2026-11-23T18:15:10.586351+00:00'
updated_at: '2026-11-23T18:15:10.586351+00:00'
has_child_rationale: User approved the split for the advisory-slenderness open question
  (todo-15a5fe44)
---
Resolution of todo-15a5fe44 (user approved 2026-11-23). Splits slenderness by code status:

**1. Advisory limits stay in the base axial sizer, non-fatal.** §E2 `KL/r ≤ 200` (compression) and §D1 `L/r ≤ 300` (tension) are AISC 'preferably' guidance, not strength requirements — §E2 rarely binds (compression strength forces a larger section first) and §D1 is pure serviceability. Add an opts knob `slenderness = :off | :warn | :hard`, DEFAULT `:warn`: emit a diagnostic/trace when the chosen section exceeds the limit, do NOT reject it. Never silently hard-reject on an advisory limit (would inflate members / mask catalog issues).

**2. Mandatory limits live in the step-4 AISC 341 seismic-detailing module**, NOT the base elastic sizer. SCBF/OCBF brace slenderness (e.g. SCBF `KL/r ≤ 4√(E/Fy)`) IS code — it belongs in the pluggable per-type seismic module scoped on deci-ff84d1d8, keeping the base sizer strength-only.

**3. Sequencing (user-approved default): BUNDLE the base-sizer `:warn` knob INTO step 4** alongside the 341 limits, so the just-landed `size_axial_members` is touched once, not twice. Not urgent since §E2 rarely binds.

**4. Corpus gate:** confirm exact wording of §E2 User Note, §D1, and the §341 brace limit (source_id + clause + page) before writing code. The clause-inventory agent (15c4a795) is retrieving these; fold its findings in.

todo-15a5fe44 stays OPEN as the implementation tracker (now with a decided approach), to be executed within step 4.
