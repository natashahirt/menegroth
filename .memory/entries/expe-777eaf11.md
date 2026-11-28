---
id: expe-777eaf11
type: experiment
project: menegroth
parent_id: deci-6241f871
title: 'grid/x1y1 steel two-way: the W36X652 failure is a stale frame stiffness matrix
  in story-shell beam sizing, not mainly the deflection measure'
node_label: Stale frame K in story-shell sizing
tags: deflection,stale-stiffness,story-shell,size_beams,reanalyze,asap,bug
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-1bf9dc40
created_at: '2026-11-17T23:24:57.472281+00:00'
updated_at: '2026-11-17T23:24:57.472281+00:00'
---
Runner: scripts/runners/diag_beam_deflection.jl (grid/x1y1, steel joists at 1.25 m, two-way RC slab). Design stops in the second size_beams! call of size_beams_with_story_shell! (pass 1, L1 joists).

At the stop: applied live 1424 kN vs cell live x area 1379 kN (loads fine). Live solve residual against model.S 3e-13, but rebuilding with Asap.update!(model) changes S by 88% and 100 of 157 frame element K matrices; the L0 grid beams' K matches the W10X22 placeholder (axial norm 2.79e8 on 6 m). Largest live sag 9.81 in as solved, 0.40 in after the rebuild.

Cause: size_beams! multi-pass skips `_reanalyze_after_section_change!` after the LAST pass when reanalyze=false (`if k < length(passes) || reanalyze`, size_beams.jl ~180). `_iterate_beams_columns!` follows with update_analysis!(:stiffness), but `size_beams_with_story_shell!` -> `_story_shell_passes!` calls size_beams! again (beam_kwargs reanalyze=false) with no rebuild in between, so frame strength and deflection demands are computed on stale stiffness. Strength demands (Mux 288 kN-m, Vu 576 kN on a 6 m joist) are also stale.

After the rebuild every group fits the preferred W catalog (largest live Ix need ~5600 in^4). The absolute-vs-support issue is still real: L1 joists need 2800-3500 in^4 by absolute deflection but only 44 in^4 from their own bending, so the support-relative deflection change is still needed after the stiffness fix.
