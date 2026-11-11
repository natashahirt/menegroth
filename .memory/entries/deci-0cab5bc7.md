---
id: deci-0cab5bc7
type: decision
project: menegroth
parent_id: plan-4b6f6344
title: Seismic wall provisions are required inputs or refusals
node_label: Seismic wall provisions are required inputs or ref
tags: walls,asce-7-22,aci-318-19,phase-7
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-416e6404
created_at: '2026-10-28T21:34:24.901790+00:00'
updated_at: '2026-10-28T21:45:55.833576+00:00'
has_child_rationale: Corpus gate before seismic wall factors
---
Corpus gate before any new seismic-wall factor. Each item is a required caller statement or a refusal. `require_seismic_wall_demand_provisions` does not apply a number. ELF story cases are unchanged.

1. Cracked stiffness. ASCE 7-22 §12.7.3 item 1 (asce-7-22, PDF page 184) requires concrete stiffness to consider cracked sections. ACI 318-19 Table 6.6.3.1.1(a) (aci-318-19, PDF page 78) permits 0.70Ig uncracked and 0.35Ig cracked, axial area 1.0Ag. Sustained lateral load divides I for columns and walls by (1 + βds). The gross shell model is refused. Neither factor is written into the mesh. The caller must state that the model already uses the table, and, when sustained lateral load is present, that the divisor was applied.

2. ρ in Eh. Eq. 12.4-3 (PDF page 183) is Eh = ρ QE. §12.3.4.1 (PDF page 182) permits ρ = 1.0 for Seismic Design Category B or C, so Eh may stay QE there. For D, E, or F, §12.3.4.2 sets ρ = 1.3 unless its conditions are met. Those conditions are not evaluated. The demand is refused until the caller states ρ was applied to Eh.

3. Ax. §12.8.4.3 Eq. 12.8-15 (PDF page 187) applies to Category C, D, E, or F with a Type 1 horizontal irregularity. Ax is not computed or applied. Category B is outside that section. A stated Type 1 irregularity in C–F is refused until the caller states Ax was applied to Mta.

4. Orthogonal directions. §12.5.2 (PDF page 183) permits the independent procedure for Category B. §12.5.3 (PDF page 184) permits it for Category C unless there is a Type 5 horizontal irregularity. §12.5.4 permits it for D, E, or F only when 12.5.4(a)–(g) are absent; a stated Type 1 or Type 5 irregularity overrides a claim that they are absent. One seismic direction is otherwise refused. The 100/30 combination is not applied.

5. P-delta on strength. §12.8.7 (PDF page 188): member forces need not include P-delta when θ ≤ 0.10. Above 0.10 the demand is refused until the caller states member forces already include it. 1/(1 − θ) is not applied. θmax is not judged here because it depends on β and Cd.

6. Flange width. ACI 318-19 §18.10.5.2 (aci-318-19, PDF page 325) is the special structural wall width: from the face of the web, the lesser of one-half the distance to an adjacent wall web and 25 percent of the total wall height above the section. It is not applied to an ordinary wall. `refuse_joined_wall_design` still throws.

Tests: analyze/test_seismic_wall_gates.jl, 29 passed. Not committed.
