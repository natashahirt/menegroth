---
id: plan-7318fba7
type: plan
project: menegroth
parent_id: chec-dfe2b0cb
title: Remaining member and foundation sizing gaps, one verified chunk at a time
node_label: Open sizing gaps
tags: nlp,deflection,joist,section-floor,foundations,two-way
status: active
open_threads: 3
success: 'null'
files: ''
session_id: sess-37be5cf1
created_at: '2026-11-13T14:56:22.634267+00:00'
updated_at: '2026-11-13T15:33:06.506415+00:00'
has_child_rationale: User asked to walk the remaining open items autonomously.
---
Autonomous pass on row-f-nlp after 3b231dad. Do not take sliding, partial contact, the overturning reduction, Ev = 0, the 0.5 live factor, or a qa increase.

Order:
1. Rectangular beam NLP deflection, reusing the existing ACI deflection check.
2. Joist ribs on the NLP path, reusing the discrete §8.13 checks.
3. Section floors that never relax: trim on the last round from the stored rows.
4. Grade walls into the wall-strip and mat paths, including framed-member stiffness when the beams are already sized.
5. Two-way thickness from beam αfm once the beams exist.
6. Ranked size-changers that reuse an existing check: column shrink-and-verify, group envelopes of non-concurrent demands, RC objectives that ignore rebar.

No new code equations. Commit each chunk that tests clean. Leave scene/ and logs/ untracked.
