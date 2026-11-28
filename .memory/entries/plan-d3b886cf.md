---
id: plan-d3b886cf
type: plan
project: menegroth
parent_id: deci-25a744e3
title: 'Cracked service shell: three passes, then span scoring'
node_label: Cracked service shell
tags: story-shell,deflection,aci-318,cracking
status: active
open_threads: 1
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/story_shell_service.jl@ed14a42, StructuralSynthesizer/src/analyze/slabs/slabs/story_shell_service.jl@ed14a42,
  StructuralSynthesizer/src/analyze/slabs/slabs/story_shell.jl@ed14a42, StructuralSynthesizer/src/analyze/members/members/size_beams.jl@b3090e3,
  StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@b3090e3,
  StructuralSynthesizer/src/analyze/members/members/demands.jl@ed14a42
session_id: sess-b1b56ec8
created_at: '2026-11-04T16:00:15.350132+00:00'
updated_at: '2026-11-05T00:06:36.736201+00:00'
---
Build the cracked service shell on the existing story mesh and hand its spans to sizing.

1. Gross solve stays first. Slab bars and factored beam demands stay on it (ACI 318-11 §8.3.1 / §13.5.1).
2. For service levels dead, dead plus a sustained live fraction ψ, and dead plus all live: start from gross stiffness, scale each RC span's web and the plates inside its flange to Ie/Ig from Eq. 9-8 with the continuous-span average, soften steel and composite hogging strips the same way from the gross-shell top bars, and re-solve until the factors settle. ψ of 0 or 1 is not a third factorization. ψ defaults to 0 (dead only is sustained).
3. One RCShellSpan per span goes through shell_spans into the concrete discrete checker. Steel and composite chord deflections from the same solves raise the live and total deflection demands. The story-shell loop already re-solves when a section changes.

Strength demands stay on the gross shell. The bare-steel Ix scaler is not replaced; shell deflection only raises the demand the existing scaler sees.
