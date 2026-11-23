---
id: deci-7a4e26c2
type: decision
project: menegroth
parent_id: chec-2558ed85
title: 'Dual run: new dual_system_stage + graph node; moment frame = user-override-or-auto
  designation'
node_label: dual stage plan
tags: dual-system,stage,graph-builder,moment-frame,designation,architecture
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-080fe0f7
created_at: '2026-11-23T20:18:07.782340+00:00'
updated_at: '2026-11-23T20:18:07.782340+00:00'
has_child_rationale: Fixes the architecture for the dual analysis stage before building
  it
---
## Decisions (user)

### Stage architecture: NEW dual stage
Build a dedicated `dual_system_stage.jl` + a `graph_builder` node, reusing the wall FEM for the core and the ELF/wind/drift plumbing. Do NOT entangle the ~1000-line `ordinary_wall_stage` (which explicitly refuses non-wall systems at line 215). Cleaner separation of the dual path from the concrete-wall path.

### Moment-frame member designation: override-or-auto (both)
The 25% moment frame is identified by:
- **Manual override (recommended interaction)**: members the user flags `lateral_role = :moment_frame`. If ANY member is flagged, the flagged set IS the moment frame.
- **Auto default (fallback)**: if nothing is flagged, auto-designate primary girders (`role = :girder`) + all columns as the moment frame; everything else gravity.
This drives both the release assignment (moment-frame members get fixed/moment connections) and the frame-only capability model for the §12.2.5.1 gate.

## Build order (stage B, incremental)
1. `moment_frame_members(struc)` → (beams, columns, source=:override|:auto) — the designation unit, tested.
2. `dual_system_stage.jl`: to_asap! (frame + core), ELF (R/Cd/Ω₀ from `dual_seismic_system(row, sdc)`), wind, story shears + 25% share proxy, member checks (steel columns via the unified _aisc_amplified_forces second-order path; B2 from story stability), design story drift Cd·δxe/Ie.
3. Drift-governor wiring: core = background (non-sized); δ_allow = Δa·Ie/Cd.
4. §12.2.5.1 capability gate: frame-only model under 25% base shear, feasibility.
5. graph_builder node + 20–40 story end-to-end proof.

Parent hooks: chec-2558ed85 (prepare/seismic_members/system_checks/row + 25% share proxy already in dual_system.jl).
