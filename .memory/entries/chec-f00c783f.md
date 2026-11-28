---
id: chec-f00c783f
type: checkpoint
project: menegroth
parent_id: deci-6241f871
title: Stale frame stiffness fixed in story-shell beam sizing; guard added; support-relative
  deflection is next
node_label: Stale K fixed
tags: deflection,stale-stiffness,story-shell,guard,asap
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c403bd93
created_at: '2026-11-17T23:53:41.558029+00:00'
updated_at: '2026-11-17T23:53:41.558029+00:00'
---
Done (uncommitted):
- Asap `stale_frame_elements(model; rtol=1e-9)` (external/Asap/src/Model/analysis/model_updates.jl, exported): frame elements whose stored K differs from global_K! of the current section; restores K. Test in external/Asap/test/integration_and_api/test_factorization_cache.jl.
- `member_group_demands` throws ArgumentError when any frame element is stale.
- size_beams_story_shell.jl: `_size_story_beams!` = size_beams! then `_reanalyze_after_section_change!`; replaces all five bare size_beams! calls (initial, each shell pass, trim free pick, trim put-back try/catch).
- Tests: Asap factorization-cache file passes; StructuralSynthesizer test_story_shell_beams, test_composite_context, test_deck_floor_building 555/555 pass, guard never fired.

grid/x1y1 steel two-way after the fix: 0 stale elements, largest live sag 0.30 in (was 9.81). Still stops: story shell does not settle in 10 passes, then group 6 (5 m L0 grid beam on the column-free x=6/x=18 lines, Lb 1.25 m) fails deflection_total at W36X652 (ratio 1.18). The 5 m beams on those lines ratchet to W40X593: absolute live need 27,000 in^4, own bending need 49-155 in^4. The need grows with the beam's own I_ref because support movement does not shrink, so the upward-only ratchet climbs to the catalog top. Next: support-relative deflection per deci-6241f871.
