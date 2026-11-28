---
id: note-bcccfa14
type: note
project: menegroth
parent_id: plan-0e3e4710
title: Drop-panel size and rib deflection stiffness, ACI 318-11
node_label: 'Drop-panel size and rib deflection stiffness, ACI '
tags: aci-318-11,drop-panel,shear-cap,deflection,Ie
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f89cd62c
created_at: '2026-11-08T21:40:08.486546+00:00'
updated_at: '2026-11-08T21:40:08.486546+00:00'
---
Looked up before coding the head classifier and the rib deflection check. Corpus: aci-318-11.

Drop panel vs shear cap, PDF page 244 (printed 240):
- §13.2.5: to reduce negative reinforcement or minimum slab thickness, a drop panel projects below the slab at least one-quarter of the adjacent slab thickness, and extends each way from the support centerline at least one-sixth of the center-to-center span in that direction.
- §13.2.6: a shear cap, used to enlarge the shear section, projects below the slab and extends horizontally from the column face at least the thickness of that projection.
- R13.2.5 and R13.2.6: a projection smaller than §13.2.5 may be used as a shear cap. It increases shear strength and does not reduce flexural reinforcement or minimum thickness. Thickness changes are checked at several sections (§11.11.1.2).

Deflection, PDF pages 132–133 (printed 128–129):
- §9.5.2.3 Eq. (9-8): immediate deflection uses Ec from §8.5.1 and Ie = (Mcr/Ma)^3 Ig + [1 − (Mcr/Ma)^3] Icr, not greater than Ig. Mcr = fr Ig / yt, fr = 7.5 λ √f'c.
- §9.5.2.4: for a prismatic continuous member, Ie may be the midspan value.
- §9.5.2.5 Eq. (9-11): additional long-term deflection is the immediate deflection from the sustained load times λΔ = ξ / (1 + 50ρ'). ξ = 2.0 at 5 years, 1.4 at 12 months, 1.2 at 6 months, 1.0 at 3 months. ρ' is at midspan for simple and continuous spans.
- §9.5.2.6: the sum is limited by Table 9.5(b). The strength-model I_factor is not this stiffness.
