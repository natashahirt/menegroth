---
id: plan-3c70ba75
type: plan
project: menegroth
parent_id: plan-b45b0d7f
title: Add wall, column, and beam self-weight to ELF seismic weight W and P-delta
  Px
node_label: self-weight in W and Px
tags: walls,phase-7,elf,p-delta,seismic-weight,px,asce-7-22
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1cf8ff4f
created_at: '2026-10-31T13:21:18.621461+00:00'
updated_at: '2026-10-31T13:21:18.621461+00:00'
---
Finding (scripts/runners/pdelta_ratio_probe.jl, logs/pdelta_ratio_probe.log): the M2/M1 about 1.5 on the office fixtures is Y-direction sway amplification. Both fixtures have walls only along X. ELF W and Px are summed from Cell self_weight + sdl + live only. Wall self-weight (and column/beam self-weight) is missing, so the vertical force through each story cut under 1.0D is 2.6-5.1x the ELF Px (3.4-6.9x under 1.2D+1.6Lr). Corrected Y theta is about 0.39-0.43, above theta_max 0.125; the measured K_G amplification (1.56-1.75) matches 1/(1-theta_corrected). The story geometric stiffness is correct; theta and W are understated.

Code basis: ASCE 7-22 12.7.2 (corpus asce-7-22, PDF p. 184): W shall include the dead load above the base. 12.8.7 (PDF p. 188): Px = total vertical design load at and above level x per 12.8.6.1 (PDF p. 187), expected gravity no less than 1.0D + 0.5L with L = 0.4L0 (0.8L0 above 100 psf), no individual load factor above 1.0.

User decisions (2026-10-31):
- Lumping: half of each story's walls and columns to the level above and half to the level below. The lower half of the lowest story goes to the base and is outside W. The same lumped weights feed W and Px. (Not a code instruction; a modeling choice.)
- Commit the untracked ordinary-wall stage, its test, design/, approaches/, and ordinary_wall_inputs.jl together with this work once tests pass.

Steps:
1. Cite 12.7.2 and 12.8.6.1/12.8.7 at the new lines.
2. Add wall self-weight (density x t x length x height x g, from the same wall geometry as the mesh) and frame member self-weight (from the unfactored member gravity loads) to each ElfLevel weight_kN and gravity_kN, half-story lumped.
3. Cross-checks: total dead above the base equals the vertical base reaction of the unfactored D case (less the base half-story share); per story, Px consistent with the story-cut axial force under expected gravity up to the lumping difference.
4. Fixtures: add Y-direction walls to the stiff office so theta <= 0.10 both ways; retune the flexible fixture to 0.10 < theta <= theta_max; add a test that the current Y-weak office is refused by theta_max. Update ELF tests whose weights change.
5. Re-run the ratio probe on the new fixtures; M2/M1 should approach 1/(1-theta). Investigate the separate open question: X-direction walls carry about 84 kN m in-plane moment under Y wind with almost no floor rotation.
6. Run ELF, story-cut, story-pdelta, ordinary-wall stage tests; record; commit.
