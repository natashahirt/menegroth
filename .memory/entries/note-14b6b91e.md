---
id: note-14b6b91e
type: note
project: menegroth
parent_id: plan-cb717409
title: Findings from the tightening pass on the Table 12.2-1 lookup
node_label: Findings from the tightening pass on the Table 12.
tags: walls,phase-7,seismic-system,table-12.2-1,12.2.5.8,findings
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9da2d15e
created_at: '2026-11-02T16:01:23.686954+00:00'
updated_at: '2026-11-02T16:01:23.686954+00:00'
---
1. Cross-check: Table 12.14-1 text (asce-7-22 PDF p. 201) rows A.2 and B.5 give R = 4 and 5, P in SDC B and C, NP in D and E. This matches A.3 and B.6. Table 12.2-1 itself is image-only in the text extraction. Ω0, Cd, and rows C.7, E.8, and F rest on the rendered pages; the user still has to eyeball them. Comment added in seismic_systems.jl.
2. pdelta_ratio_probe.jl fixed: reads R, Cd, and Ω0 from the system row and no longer calls the deleted crack helper (to_asap! cracks the walls).
3. 12.2.5.8 (PDF p. 179) says only 'shear strength of the shear walls >= 75% of the design story shear at each story; frames capable of resisting >= 25% of the design story shear in every story'. It does not say nominal or design strength, nor whether the 1/(1-theta) factor applies. Vx is the 12.8.4 story shear (PDF p. 187). Row F is SDC B only, so rho = 1 (12.3.4.1).
4. A.3 vs B.6: a bearing wall is a concrete wall supporting > 200 lb/ft (2,919 N/m) beyond its own weight (PDF p. 103 definitions). A bearing wall system has walls supporting 'all or major portions' of the vertical loads. C12.2.1 (PDF p. 707-708): in a building frame, bearing walls carry 'a relatively small percentage of the floor or roof area'. There is no numeric threshold. The unified model can measure the share of vertical load the walls carry (the probe already prints walls/ΣP per story), but the cutoff has to be stated.
5. Frame-only model: no mode exists. The office fixtures (gen_medium_office, vault floor) have concrete beams and columns. The flat-plate fixture has no slab elements: the rigid diaphragm ties the floor in plane only, so a slab-column moment frame is not modeled. Punching functions accept Msc but nothing passes a lateral moment to them. The beam and column checkers are is_feasible(ACIBeamChecker / ACIColumnChecker, ...).
