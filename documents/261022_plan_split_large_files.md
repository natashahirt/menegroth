# Plan: split the four largest source files (pure move refactor)

**Why:** an agent reading one of these whole costs ~40–60k tokens; topic-sized files cut that to a few thousand per read and make navigation easier.

**Scope rule:** move code only. No renames, no signature changes, no edits to engineering math, comments, or docstrings. `git diff -M --color-moved=dimmed-zebra` should show only moved blocks plus new `include(...)` lines.

**Execution:** one file per fresh chat, single agent, cheap model, no coordinator. Line ranges below are from `main` on 2026-10-22 and are approximate — confirm each boundary against the actual section banner before cutting.

## Per-file verification

1. Before: run the tests that exercise the file with `julia scripts/runners/test_quiet.jl <Pkg> <files...>`; save the summary.
2. Split; the original file becomes (or is replaced by) an ordered list of `include`s.
3. After: same tests, identical pass counts. Load the package once in a fresh process to catch include-order problems (structs/consts must be defined before any top-level code that uses them; plain method definitions can be in any order).
4. Check that multi-method functions split across files (e.g. `run_moment_analysis` in ddm.jl has methods at ~283 and ~4382) are all still defined.

## 1. `StructuralSynthesizer/src/api/chat.jl` (4,990 lines → `src/api/chat/`)

| New file | Approx. lines | Content |
|---|---|---|
| `config.jl` | 1–316 | Configuration, token budget, session history |
| `prompt.jl` | 317–569, 2696–2905 | System prompt assembly; turn summary contract; per-inference grounding |
| `structure_cache.jl` | 570–1299 | Chat-side structure cache |
| `geometry_stats.jl` | 1300–2592 | Pre-design geometry analysis (largest remaining piece; ok to split further later) |
| `recommendations.jl` | 2593–2695, 3488–3790 | Suggestions extraction; geometric recommendation detection |
| `llm_client.jl` | 2906–3487 | LLM streaming client |
| `tool_dispatch.jl` | 3791–4690 | Tool dispatch |
| `routes.jl` | 4691–end | Route registration |

## 2. `StructuralSynthesizer/src/analyze/members/utils.jl` (4,649 lines)

| New file | Approx. lines | Content |
|---|---|---|
| `initialize.jl` | 1–1276 | Segment/member init from skeleton edges, strategies |
| `split_edge.jl` | 1277–1652 | Split-edge fallback |
| `end_releases.jl` | 1653–1851 | End-release resolution |
| `steel_discrete_sizing.jl` | 1852–2555 | Discrete steel sizing (simultaneous, catalog) |
| `group_sizing.jl` | 2556–2810 | Single member-group sizing seam |
| `beam_dispatch.jl` | 2811–2981 | Beam sizing dispatcher + table |
| `beam_steel.jl` | 2982–3578 | Steel beams, per-group override narrowing, shared apply-results helper |
| `beam_concrete.jl` | 3579–3918 | Concrete beams (MIP + NLP) |
| `beam_pixelframe.jl` | 3919–4059 | PixelFrame beams |
| `column_sizing.jl` | 4060–4488 | Member sizing orchestrator, multi-material column sizing, apply results |
| `column_estimate.jl` | 4489–end | Initial column size estimation |

Note: `beam_steel.jl` holds the shared "apply MIP/NLP beam results" helper (~3522) used by the concrete paths — keep it in an earlier-included file or move it to `beam_dispatch.jl`.

## 3. `StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl` (4,475 lines → `analysis/ddm/`)

| New file | Approx. lines | Content |
|---|---|---|
| `moments.jl` | 1–505 | Column classification/ordering, per-span moments, `run_moment_analysis` (primary), secondary direction |
| `eq137_geometry.jl` | ~620–1270 | `_eq137_*` geometric primitives (polygons, cells, rays, cover runs) |
| `eq137_support_sides.jl` | 1271–2662 | `_eq137_*` far-support/side resolution, partway/drop/neighbour logic |
| `eq137_transfer.jl` | 2663–2928 | `_eq137_support_class`, `_eq137_transfer_moment` |
| `column_demands.jl` | 2929–3387 | DDM support moments, column demands from spans, frameline edge/transfer moments |
| `applicability.jl` | 3388–4136 | `DDMApplicabilityError`, applicability checks, `enforce_ddm_applicability` |
| `frameline.jl` | 4137–end | FrameLine-based DDM incl. second `run_moment_analysis` method |

Note: the "Column Demands from Per-Span Moments" banner (~506) precedes the `_eq137_*` block; confirm where the eq137 helpers actually start. Safety-critical file: move-only, keep every ACI citation comment with its code.

## 4. `StructuralSynthesizer/src/analyze/asap/utils.jl` (3,202 lines)

| New file | Approx. lines | Content |
|---|---|---|
| `model_build.jl` | 1–265 | Offset nodes, `to_asap!` |
| `diaphragms.jl` | 266–414, 1164–1448 | Shell props, shell/rigid diaphragms, joist lines, `create_slab_diaphragm_shells` |
| `tributary_loads.jl` | 415–567 | Cell tributary loads, width profiles |
| `sync.jl` | 568–756 | `sync_asap!` and companions |
| `pattern_loading.jl` | 757–1067 | Pattern-solve cache, pattern case generation |
| `load_push.jl` | 1068–1163 | `push_asap_loads!`, slab edge / vault thrust line loads |
| `releases_eccentricity.jl` | 1449–1647 | Edge release + eccentricity maps, load routing |
| `slab_loads.jl` | 1648–2438 | Shell area loads, framed-slab strip loads |
| `analysis_model.jl` | 2439–2879 | Slab boundary helpers, `build_analysis_model!` |
| `mesh_refinement.jl` | 2880–end | Shell mesh controls, refinement nodes, `add_coating_loads!` |

Note: `diaphragms.jl` defines `struct _DiaphragmJoistLine` (~1183); include it before any file whose top-level code references the type.
