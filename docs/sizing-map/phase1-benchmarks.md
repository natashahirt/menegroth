# Phase 1 — Benchmark set and measurement baseline (proposal)

Status: draft, research only (2026-11-11). Proposes the benchmark buildings
and the instrumentation needed for [`plan.md`](plan.md) Phase 1. Paths: `SS/` =
`StructuralSizer/src/`, `SY/` = `StructuralSynthesizer/src/`, `SYT/` =
`StructuralSynthesizer/test/`.

## Summary

- **Seven benchmarks (B1–B7)**, all built from `gen_medium_office`, cover every
  required system. Five reuse an existing test fixture with small changes. B6
  (steel composite frame with ordinary walls, ELF and wind) is new; nothing
  in the repo runs steel framing and walls together through `design_building`.
  An eighth (B8, the core office) is optional and slow (~16 min).
- **Instrumentation already present:** per-element-type carbon and material
  takeoff (`DesignSummary`), the trace collector, a global Asap factorization
  counter, FEA-cache rebuild/update counters, and `stage_diagnostics`. Missing:
  per-stage runtime on the default `design_building` path, any count of
  building analyses, round counts for four of the loops, a "why is it this
  size" tag on columns, walls and footings, and **wall carbon (walls are not in
  embodied carbon at all)**.
- **Proposal:** one opt-in `SizingProbe` carried in a `ScopedValue` (no
  signature changes, zero cost when off), counters in Asap keyed by a stage
  label, and `scripts/runners/sizing_baseline.jl` that writes one JSON per run
  plus four CSVs (runs, stages, loops, elements) and registers them in the
  run ledger.
- **Pin `solver = :highs`** in every benchmark. Gurobi is licensed on this
  machine (test logs show "Academic license … expires 2027-04-16"), so `:auto`
  picks Gurobi here and HiGHS elsewhere. That changes MIP picks and runtimes.

---

## 1. Inventory of existing building fixtures

`gen_medium_office(Lx, Ly, h_story, nx, ny, n_stories; irregular, offset)`
(`SY/generate/doe/medium_office.jl:17`) is the only building generator. Every
fixture below is a call to it plus edits to the skeleton groups (`:beams` →
`:slab_edges` for beamless floors, `:beams` → `:walls` for walls). Runtimes
are from `logs/` where a log exists; "est." means not measured.

Gurobi column: **none of these fixtures set `solver`**, so all MIP-based
member sizing uses `:auto` → Gurobi when licensed
(`SS/optimize/solvers/discrete/backends.jl:91-107`). "MIP" marks fixtures that
size steel/RC beams or columns by MIP (beam floors); flat-plate fixtures pick
columns by catalog scan and do not touch the MIP.

### 1a. Test fixtures that call `design_building`

| Path | Builds | Floor / method | Stories, bays, spans | Walls / lateral | Foundations | Runtime | MIP |
|---|---|---|---|---|---|---|---|
| `SYT/core/test_flat_plate_member_stage.jl:26` | `gen_medium_office(54ft,42ft,10ft,3,3,2)` | Flat plate, DDM/EFM/FEA loop | 2 st, 3×3, 18×14 ft | — | — | est. 1–3 min | no |
| `SYT/core/test_uniform_column_sizing.jl:35,103` | same plan, 1 or 2 st | Flat plate DDM, `uniform_column_sizing` on | 1–2 st, 3×3 | — | — | est. <1 min each | no |
| `SYT/design_graph/test_two_level_slabs.jl:33-50,111` | `gen_medium_office(20ft·nx, 20ft·ny, 12ft, …)`, `grouping=:individual` | Flat plate **FEA**, LL 125 psf, SDL 40 psf | 1 st, 2×2, 20 ft | — | — | est. 1–2 min | no |
| `SYT/integration/test_slab_system_regression.jl` | 24×24 ft 2×2 (framed) or 3×3 at 18 ft (beamless, `:beams`→`:slab_edges`) | one-way RC, **two-way RC on RC beams**, one-way on steel, two-way composite steel, composite deck 2VLI, flat plate DDM, **flat slab (drop panels)** | 1 st | — | — | est. 3–6 min file | yes (beam floors) |
| `SYT/core/test_two_way_support_pipeline.jl:46-100` | 18×14 ft bays beamless; 24 ft 1×1 with walls on every roof edge | two-way → flat plate reroute; two-way on walls | 1 st | gravity walls, `wall_thickness=0.3m` | — | est. 1–2 min | no |
| `SYT/core/test_member_stage_closure.jl:27-46,123` | 24×24 ft 2×2; 20×10 ft 2×1 | one-way RC; composite deck | 1 st | — | `:all_spread` | est. 1–2 min | yes |
| `SYT/integration/test_deck_floor_building.jl:24` | 20×10 ft 2×1 | Composite deck 2VLI, composite steel beams, steel columns, LL 100 psf | 1 st, 10 ft bays | — | — | **2m14s** (log 20261028) | yes |
| `SYT/analyze/test_story_shell_pipeline.jl:13` | 6×6 m, 2×1 | One-way RC on beams → **story shell** | 2 st | — | — | est. 1–2 min | yes |
| `SYT/analyze/test_ordinary_wall_stage.jl:166-181,734-800` | `_stage_office`: 12 m square, 3×3 at 4 m, 4 isolated piers stacked on 3 stories | Flat plate **FEA**, rigid diaphragm | 3 st, 3×3, 4 m | **Ordinary walls; `WallsSeismicSystem(:A3)`; ELF + wind** via `OrdinaryWallInputs` (`_stage_inputs`, :36-61, SDC B, SDS 0.05, qz 1.0–2.0 kPa); `jump_wall_thickness=false` | — | file 1–5 min (logs) | no |
| `SYT/integration/test_building_detailing.jl:9` | 54×42 ft 3×3 | Flat plate DDM | 2 st | — | — | est. 1–2 min | no |
| `SYT/integration/test_auto_framing_integration.jl:88-260` | 54×42 ft 3×3; 30 ft 1×1 | One-way + auto framing | 1 st | — | — | est. 2–4 min | yes |
| `SYT/analyze/test_design_equilibrium.jl:15` | 20 ft 1×1 | One-way | 1 st | — | — | <1 min | yes |
| `SYT/design_graph/test_design_graph_equivalence.jl:58,96`, `test_design_graph_incremental.jl` | flat-plate / beam offices | various | 1–2 st | — | `:all_spread` | long files (tens of min) | mixed |
| `SYT/report_generators/test_foundation_integration.jl:548-1070` | Isolated `MatParams` cases (Rigid, Shukla, Winkler) | — (direct foundation calls, not `design_building`) | — | — | **mat** (3 methods), spread, strip | est. 2–5 min | no |

### 1b. Runner scripts and studies

| Path | Builds | Notes | Runtime | MIP |
|---|---|---|---|---|
| `scripts/runners/run_smoke_medium_office_3storey.jl` | 159×108 ft, 8×5 (≈20×22 ft), 3 st, flat plate DDM, `max_iterations=3` | 162 columns; prints `compute_time_s` | est. 3–8 min | no |
| `scripts/run.jl`, `scripts/runners/run_engineering_report.jl` | 125×90 ft, 5×3 (25×30 ft), 13 ft, 3 st; flat plate EFM, studs `:always`, rect RC columns; foundations medium sand (`run.jl` `:auto`) | report driver | est. 5–15 min | no |
| `scripts/runners/profile_design_building_asap.jl` | 159×108 ft 8×5 3 st; cases `default`, `flat_ddm`, `flat_fea`, `steel` | **Profiles Asap share; reads `Asap._N_FACTORIZATIONS`** (:83, :101) | est. 5–20 min/case | `steel` yes |
| `scripts/runners/sweep_design_building.jl` + `sweep_case_runner.jl` + `sweep_specs/flat_plate_grid.jl` | flat plate 8×5 bays × span {20,24,28} × stories {3,6} × {DDM,FEA} | **Multi-process sweep, resumable CSV with EC by element × material** (`sweep_case_runner.jl:28-93`). Best existing template for the baseline runner | grid: hours | no |
| `scripts/runners/time_building_sweep.jl` | 28 ft bays 8×5, 3 st (StructuralStudies section-3 skeleton) | DDM vs FEA timing | est. 5–15 min | no |
| `scripts/runners/run_phase11_integration_fixtures.jl` | 54×42 ft 3×3, 10 ft, 1 st | A: steel framing + **steel joists at 24"** on one-way; B: RC rib grid; C: two-level steel joists | est. 3–6 min | yes |
| `scripts/runners/story_shell_multibay.jl` | 40×40 ft 2×2 1 st | calls `size_beams_with_story_shell!` directly, not `design_building` | <2 min | yes |
| `scripts/runners/design_core_office.jl` + `core_office_geometry.jl` | 3×3 at 8 m, 4 st × 3.6 m, central core walls 300 mm with shafts | Flat plate FEA `:strip`, rigid diaphragm, `:all_spread` (wall groups still become **mat / wall strip**); no lateral | **951 s** (pipeline 699 s, prepare 107 s; `logs/core_office_v5_design.log`), 46k shell triangles | no |
| `scripts/runners/core_office_foundations.jl` | same core office, foundations only | prints mat / wall strip / spread counts | est. 3–5 min | no |
| `scripts/benchmarks/bench_pipeline.jl` | 54×42 ft 3×3 1 st | Stage micro-timings for slabs (DDM, EFM) and one steel beam, **not `design_building`** | <1 min | no |
| `scripts/runners/bench_wall_lateral_baselines.jl` | 4-wall core, 2 st, `WallLine` only | lateral evaluator timing, no building | seconds | no |
| `scripts/api/test_payload.json` | 18 vertices, 2 levels, 9 supports (2×2 bays, 1 st) | API JSON: flat plate DDM, `size_foundations=true`, medium sand | <1 min | no |
| `StructuralStudies/src/flat_plate_methods/building_scale_analysis.jl`, `…/slab_design_factors/study.jl` | flat-plate method studies | research sweeps | long | no |

No other API request JSONs or example directories exist (`examples/` is absent).

### 1c. Coverage gaps in the existing fixtures

- **Steel composite frame with ordinary walls and lateral (ELF + wind):** none.
  Every walls + lateral `design_building` call uses a flat plate or vault floor.
- **Mat foundation through `design_building` on a small building:** only the
  core office (16 min). `strategy = :mat` is never set in a `design_building`
  test.
- **Column strip footings (`:all_strip`) through `design_building`:** none.
- **Flat slab with drop panels on more than one story:** none (regression test
  is one story).
- **Shared-column flat plate on more than one story** (stacking + lock
  together): none (`test_two_level_slabs.jl` is one story).
- **Wall thickness jump (L12) and the walls ⇄ members loop (L13) under
  lateral load:** the lateral `design_building` test passes
  `jump_wall_thickness = false`. The only jump-on run is a one-bay,
  one-story gravity wall cell (`SYT/design_graph/test_wall_thickness_provenance.jl:39-62,108`).

---

## 2. Proposed benchmark set

Routing fact that shapes the choice: every story whose slabs are all
`:one_way` / `:two_way` is sized by the **story shell** (L11), not the plain
beam ⇄ column loop (`SY/workflow/member_iteration.jl:316-325`;
`SY/analyze/members/members/size_beams_story_shell.jl:45-56`). So the two-way
and one-way benchmarks already exercise the story-shell path, and the plain
L9 loop is only reached by composite deck (and vault) floors. B6 uses
composite deck for that reason.

Common settings for every benchmark (differences from today's fixtures in
bold):

- `skip_visualization = true`; `SS_ENABLE_VISUALIZATION=false`.
- **`solver = :highs`** on every `*BeamOptions` / `*ColumnOptions`
  (`SS/optimize/core/options/concrete.jl:105,266`, `steel.jl`), so results do
  not depend on the Gurobi license.
- `max_iterations = 20` (the production default, `SY/design/parameters.jl:286`),
  not the 3 that several tests use. Several loop budgets derive from it
  (`monotone_budget`), so a lower value would hide rounds.
- Materials `NWC_4000` / `Rebar_60` / `A992_Steel`; loads stated per case.
- `restore = true` (the production `DesignSession` path).

### 2a. The set

| ID | Source | Geometry | Floor / members | Walls / lateral | Foundations | Loops exercised | Est. runtime (warm) |
|---|---|---|---|---|---|---|---|
| **B1** flat plate, multi-story | `test_flat_plate_member_stage.jl:26` | `gen_medium_office(54ft, 42ft, 10ft, 3, 3, 3)`, **3 stories** (18×14 ft bays) | `FlatPlateOptions(method=DDM())`, default `grouping=:by_floor` (one slab per story) | — | **`:all_spread`, medium sand** | L0, L1, L4–L7, L14 | 1–2 min |
| **B1f** (variant) | B1 | same | `FlatPlateOptions(method=FEA())` | — | `:all_spread` | as B1 + FEA cache (speed rank 4) | 3–6 min |
| **B2** flat plate, shared columns | `test_two_level_slabs.jl:33-50,111` | `gen_medium_office(40ft, 40ft, 12ft, 2, 2, 2)`, **2 stories** | `FlatPlateOptions(method=FEA(), grouping=:individual)`; LL 125 psf, SDL 40 psf | — | — | L0, **L2, L3**, L4–L7 (stacking across stories) | 2–5 min |
| **B3** flat slab | `test_slab_system_regression.jl:23-27,145-153` | `_beamless_office(3)`: 54×54 ft, 3×3 at 18 ft, **3 stories**, `:beams`→`:slab_edges` | `FlatSlabOptions()` (drop panels) | — | **`strategy=:mat`** (`RigidMat`, medium sand) | L0, L1, L4–L7, rank 12 (drop panels), mat (rank 7) | 2–4 min |
| **B4** two-way on beams (story shell) | `test_slab_system_regression.jl:86-97` | `gen_medium_office(24ft, 24ft, 12ft, 2, 2, 2)`, **2 stories**, 12 ft bays | `TwoWayOptions()`, `ConcreteBeamOptions(include_flange=true)`, `ConcreteColumnOptions` | — | **`:all_strip`** | L0, **L11** (story shell, ≤3 rounds) ⊃ L9, two-way h bound (rank 2) | 3–6 min |
| **B5** one-way + steel joists | `run_phase11_integration_fixtures.jl:92-104` (Fixture A) | `gen_medium_office(54ft, 42ft, 10ft, 3, 3, 1)`; **add 2nd story** | `OneWayOptions()`, steel framing, `framing_opts=(materials=(beam=A992_Steel,), spacing=24inch)` | — | `:all_spread` | L11 ⊃ L9 with joists (level-1 members), steel MIP | 3–6 min |
| **B6** steel composite + walls + ELF + wind | **new**, see 2b | 30×30 ft, 3×3 at 10 ft, 3 stories × 12 ft, 4 isolated RC piers | `CompositeDeckOptions("2VLI")`, `SteelBeamOptions(composite=true, composite_slab_type=:deck)`, `SteelColumnOptions()` | `WallsSeismicSystem(row)`, `OrdinaryWallInputs` (ELF + wind), **`jump_wall_thickness=true`**, rigid diaphragm | `:auto` (spread + wall strip) | **L9** (plain), L12, **L13**, row-F floors if row F used | 3–8 min |
| **B7** flat plate + walls + lateral | `test_ordinary_wall_stage.jl:166-181,734-786` | `_stage_office(x_bays=3, y_bays=3, segments=_STAGE_THREE_BAY)`: 12 m square, 4 m bays, 3 stories, 4 piers | `FlatPlateOptions(method=FEA())`, RC beams/columns | `WallsSeismicSystem(:A3)`, `_stage_inputs()` (ELF + wind), **`jump_wall_thickness=true`** | **`:auto`** (spread + wall strip) | L4–L7 inside **L13**, L12 | 3–8 min |
| **B8** (optional, weekly) | `design_core_office.jl` | core office, 4 st, 3×3 at 8 m, core walls | Flat plate FEA `:strip` | gravity walls | auto → **mat under core** + spread | everything at scale | ~16 min |

Total for B1–B7 (with B1f): roughly 20–45 min single process, or about 10 min
with `sweep_design_building.jl --workers 4`. The runtime column is an
estimate; the first baseline run replaces it.

Coverage check against the request:

| Requirement | Covered by |
|---|---|
| Flat plate, multi-story | B1, B1f |
| Flat plate, shared columns across slabs | B2 |
| Flat slab with drop panels | B3 |
| Beam-supported two-way slab | B4 |
| One-way / joist floor | B5 |
| Steel frame, composite beams, ordinary walls, ELF + wind | B6 |
| Story-shell path | B4, B5 |
| Mat foundation | B3 (column mat), B8 (wall mat) |
| Spread footings | B1, B5, B6, B7 |
| Strip footings | B4 (column strips), B6/B7 (wall strips) |

### 2b. Fixtures that need new code (sketches)

**B6 — steel composite frame with ordinary walls (new).** No fixture exists.
Geometry and walls follow the `_stage_office` pattern so the wall-claiming
helpers can be reused (move `_stage_claim_segments!` and friends,
`test_ordinary_wall_stage.jl:83-145`, into a shared test helper first).

```julia
# 3×3 bays of 10 ft (2VLI unshored span used by the deck tests), 3 stories.
skel = gen_medium_office(30.0u"ft", 30.0u"ft", 12.0u"ft", 3, 3, 3)
beams = Set(skel.groups_edges[:beams])
# One isolated one-bay pier per side, ends not shared (as _STAGE_THREE_BAY).
# The claim helpers take plan coordinates in metres.
a, b, L = (10.0, 20.0, 30.0) .* 0.3048
segs = ((0.0, 0.0, a, 0.0), (b, L, L, L), (L, 0.0, L, a), (0.0, b, 0.0, L))
_stage_claim_segments!(skel, beams, segs)                   # stories 0:2
NWC_145pcf = Concrete(NWC_4000.E, NWC_4000.fc′,
                      uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, NWC_4000.ecc)
params = DesignParameters(
    name = "B6_steel_composite_walls",
    floor = CompositeDeckOptions(deck_profile = "2VLI", fill_material = NWC_145pcf),
    beams = SteelBeamOptions(composite = true, composite_slab_type = :deck,
                             composite_deck_profile = "2VLI", solver = :highs),
    columns = SteelColumnOptions(solver = :highs),
    materials = MaterialOptions(concrete = NWC_145pcf, rebar = Rebar_60, steel = A992_Steel),
    loads = GravityLoads(floor_LL = 50psf, floor_SDL = 15psf, roof_LL = 20psf, roof_SDL = 15psf),
    wall_thickness = 0.25u"m",            # start thin so the jump loop runs
    diaphragm_mode = :rigid,
    jump_wall_thickness = true,
    lateral = LateralDesign(; system = WallsSeismicSystem(ROW), assignment = BuildingUnit()),
    wall_inputs = OrdinaryWallInputs(...),   # same fields as _stage_inputs, qz per story
    foundation_options = FoundationParameters(soil = medium_sand,
                                              options = FoundationOptions(strategy = :auto)),
    max_iterations = 20, skip_visualization = true,
)
```

Open items that need the user before this fixture is written (per
`code-accuracy.mdc`):

1. **Seismic row.** A steel gravity frame with RC walls reads as a building
   frame system (`:B4` special / `:B6` ordinary), not the bearing-wall `:A3`
   that B7 uses (`SY/analyze/lateral/approaches/types.jl:21-51`). Which row?
2. **Lateral inputs.** `_stage_inputs()` uses SDC B, S_DS = 0.05, S_1 = 0.02,
   q_z = 1.0/1.5/2.0 kPa (`test_ordinary_wall_stage.jl:36-61`). These are test
   values, not a site. Reuse them for parity with B7, or pick a site?
3. **Composite deck bearing on walls.** No test puts a deck slab edge on a
   wall. If `design_building` refuses it, fall back to `OneWayOptions()` +
   `SteelBeamOptions(composite=true, composite_slab_type=:solid)` (as in
   `test_slab_system_regression.jl:110-119`), which moves B6 onto the story
   shell path and leaves plain L9 covered only by `test_deck_floor_building`.

**B2, B3, B4, B5 — one-line changes.** Add stories (B2 → 2, B3 → 3, B4 → 2,
B5 → 2), add the foundation options shown, and set `solver = :highs`. These change the source tests'
behavior, so the benchmarks get their own builder functions in the runner
rather than editing the tests.

**B7 — flip one flag.** Same as the existing lateral test, with
`jump_wall_thickness = true` and foundations added. With jumps on, L12 and
L13 run, which is the point.

---

## 3. Instrumentation that exists today

### 3a. Carbon and quantities

- `DesignSummary` (`SY/design/summary.jl:36-81`) holds embodied carbon by
  element type (slabs, columns, beams, struts, foundations, fireproofing), by
  material (concrete, rebar, structural steel, timber, other), and an element ×
  material `MaterialTakeoff` for slabs, columns, beams, struts and foundations.
  Filled by `_compute_design_summary!` (`SY/workflow/summary.jl:260-294`) from
  `compute_building_ec` (`SY/postprocess/ec.jl:288-336`) and
  `takeoff_by_element` (`ec.jl:148-170`).
- `sweep_case_runner.jl:28-93` already flattens all of that into CSV columns
  (`ec_slabs_kgCO2e`, `slab_concrete_m3`, …). The baseline runner should reuse
  `_takeoff_row` as is.
- **Gap — walls have no carbon.** `compute_building_ec` and
  `takeoff_by_element` loop over slabs, beams, columns, struts and foundations
  only. `Wall` has a `MemberBase` with `volumes` (`SY/building_types/members.jl:441-456`),
  but nothing in `SY/analyze/lateral/` or `SY/walls*` writes them. B6, B7 and
  B8 would under-report carbon, and a wall thickness change would not show up
  in carbon at all.
- **Gap — drop panels, shear caps and punching studs** are only in the
  building totals `concrete_volume` / `rebar_weight`, not in the per-element
  takeoff (`summary.jl:64-67`). B3 needs them split out.

### 3b. Timing

- `design.phase_timings` and `compute_time_s` (`SY/design/building_design.jl:68-69,86`).
- The `restore = false` path records `prepare`, `pipeline`, `capture`,
  `analysis_model`, `restore` (`SY/workflow/execute.jl:182-186`).
- **The default `restore = true` path (`DesignSession`) records only
  `analysis_model` and `total`** (`execute.jl:237-238`). Nothing times slabs,
  members, walls or foundations separately on either path.
- `TraceEvent.timestamp` (`SS/trace/trace.jl:36-43`) is seconds since the
  collector started, so stage `:enter`/`:exit` events give stage times when a
  `TraceCollector` is passed. But the stage `:enter`/`:exit` events live in
  `build_pipeline` closures (`SY/workflow/pipeline_spec.jl:91,106,119,121,138,140`)
  and the shared-column slab level emits its own `:exit` (`graph_builder.jl:704-705`),
  so pairing is fragile. The barrier `sync_asap!` between levels is untimed.

### 3c. Loop round counts already emitted (needs a `TraceCollector`)

| Loop (README id) | Event | Where | Gap |
|---|---|---|---|
| L1/L2 slab kernel | `size_flat_plate!` `:exit` `iterations`, `governing_check`, `fea_rebuilds`, `fea_updates` | `SS/slabs/codes/concrete/flat_plate/pipeline/iteration.jl:1130-1135`, `:357-361` | flat plate / flat slab only |
| L3 shared-column lock | `size_slabs!` `:decision` `lock_rounds` | `SY/workflow/graph_builder.jl:698-699` | — |
| L4 stale-slab settle | `_design_flat_plate_members!` `:decision` `passes`, `n_redesigned` | `graph_builder.jl:399-401` | — |
| L5 reconcile | none | `SY/workflow/column_reconciliation.jl:266-337` | count of columns grown |
| L6 full-load check | `check_flat_plate_columns!` `rounds`, `stop`, `converged` | `SY/workflow/flat_plate_column_check.jl:712-724` | — |
| L7 stacking | none | `flat_plate_column_check.jl:492-551` | columns grown per call |
| L8 harmonize | none (returns a count) | `SY/workflow/member_iteration.jl:26-62` | count not recorded |
| L9 beams ⇄ columns | `_size_beams_columns!` `:decision` `iterations` | `member_iteration.jl:369-375` | one event per call; L11/L13 call it repeatedly |
| L10 columns only | `:exit` `converged`, no count | `member_iteration.jl:279-294` | iteration count |
| L11 story shell | `story_shell_round` `round`, `shell_passes` | `member_iteration.jl:446-450` | — |
| L12 wall jump | `@info` only | `SY/analyze/lateral/ordinary_wall_stage.jl:154-175` | **no event with `run.steps`** |
| L13 walls ⇄ members | `:decision` `round` only when members re-sized | `SY/workflow/pipeline_spec.jl:178-190` | no event on early return |
| Mat Winkler sweep | none | `SS/foundations/codes/aci/mat_footing.jl` | step count |

### 3d. Analysis counters

- `Asap._N_FACTORIZATIONS` (`external/Asap/src/Model/analysis/factorization_cache.jl:61-68`)
  is a global `Ref(0)` bumped on every uncached factorization of **any**
  model. It is read by `profile_design_building_asap.jl:83,101` and the two
  `ab_flat_fea_*` runners. It does not say which model (building frame, FEA
  slab mesh, story shell, composite subdivision, Winkler mat) or which stage.
- **It misses the rigid-diaphragm solves.** `solve!(model, links)` and
  `solve(model, cases, links)` (`external/Asap/src/Elements/rigidlink.jl:186-240,287-…`)
  factorize the reduced system with their own `cholesky` / `ldlt` / `lu` and
  never touch `_get_factorization`. `_solve_struc_model!`
  (`SY/analyze/asap/asap/model_sync.jl:203-210`) routes every building solve
  with diaphragm links through that path, as do the ELF and P-Δ solves
  (`SY/analyze/lateral/elf_story_cases.jl:242`,
  `interactive_checks.jl:470,588`). B6, B7 and B8 use `diaphragm_mode = :rigid`,
  so their building analyses are invisible to today's counter. The explicit
  `factorize!` (`factorization_cache.jl:14-29`) and P-Δ / buckling solves
  (`Nonlinear/pdelta.jl:115,197`, `buckling.jl:48`) are not counted either.
- `Asap._MESH_RNG_CALLS` (`Elements/shell/meshing/delaunay_mesh.jl:20`) counts
  mesher calls. `FEAModelCache.n_rebuilds` / `n_updates` count flat-plate FEA
  slab re-meshes and value updates.
- `_DISCRETE_MEMO_HITS` (`SS/optimize/solvers/discrete/cache.jl:27`) and
  `_RC_NLP_MEMO_HITS` (`SS/members/optimize/api/rc_columns_nlp.jl:518`) count
  MIP / NLP memo hits.
- `update_analysis!` emits `:decision change=…` (`model_sync.jl:340-341`), but
  only when a caller passes `tc`, and most building re-solves go through
  `sync_asap!`, `_reanalyze_after_section_change!` (`member_iteration.jl:174-186`)
  or `_resolve_after_column_change!` (`column_reconciliation.jl:227-233`)
  directly, without an event.

### 3e. Governing reason (what the code already knows)

Two different questions. Today's code answers the first; Phase 3 needs the
second.

1. **Which check is closest to its limit at the final size** (utilization
   governor). Available for every element:
   `column_diagnostic_governing_check` (`SY/design/results/beam.jl:26-60`),
   `slab_diagnostic_governing_check`, `beam_diagnostic_governing_check`,
   `foundation_diagnostic_governing_check` (`SY/design/results/foundation.jl:32-60`),
   `BeamDesignResult.governing_check` (`beam.jl:15-16`), `WallCheckRecord.check`
   / `.ratio` (`SY/design/results/wall.jl:24-33`). Used by
   `summary.critical_element`.
2. **Which rule set the size** (size provenance). A seed-governed 20×20
   column can have an interaction ratio of 0.3; question 1 calls that "P-M",
   which hides the oversizing the plan is about. What is known today:

| Element | Known now | Where | Missing |
|---|---|---|---|
| Flat-plate / flat-slab h | `governing_check` = last failing check (`punching_shear`, `two_way_deflection`, `one_way_shear`, `flexural_adequacy`, `transfer_reinforcement`, `column_pm`, `reinforcement_design`) or `table_minimum` / `search_floor` | `_governing_check_label` (`SS/slabs/codes/concrete/flat_plate/design/checks/governing.jl:8-11`), merged at `iteration.jl:1125-1128`, kept in `slab.design_details` | not copied to `SlabDesignResult`; no field |
| Two-way / one-way h | always the closed-form minimum; two-way uses the αfm-unknown bound | `SS/slabs/codes/concrete/min_thickness.jl:198-203` | no tag; a constant label suffices |
| Column c1/c2 inside the slab kernel | `max(c_span_min, c_pm, c_old)` — which term won is decidable at the line | `SS/.../flat_plate/pipeline/column_updates.jl:108-109`; punching growth `utils/column_growth.jl:157-315` via `punching_resolution.jl:129-138` | not recorded |
| Column after the slab stage | seven writers, each grow-only (plan.md §Assessment 1) | seed `size_columns.jl:517-597`; envelope `graph_builder.jl:484-495,555-573`; reconcile `column_reconciliation.jl:284-318`; full-load `flat_plate_column_check.jl:615-657`; stacking `:492-551`; harmonize `member_iteration.jl:65-150`; row-F floor `size_columns.jl:238-248` | nothing records which writer was last |
| Steel / RC beam and column (MIP) | governing check of the picked section; whether a section floor bound it | `BeamDesignResult.governing_check`; `section_floor` (`size_beams_story_shell.jl:200-216`), `frame_section_floors` | floor-bound flag |
| Wall thickness | input `wall_thickness` or a jump; the jump knows drift vs pier failure | `propose_wall_thicknesses` (`SY/analyze/lateral/wall_thickness_jump.jl:562-640`; drift scaling `:333-341`, pier failures `:486-495`) | not recorded |
| Footing | each check ratio and `governing_ratio` | `SY/design/results/foundation.jl:14-21` | B vs h driver; whether the group envelope (not its own demand) set it (`SY/analyze/foundations/grouping.jl:144-151,300-325`) |

### 3f. Run ledger

No benchmark or sweep registers runs yet. `.cursor/rules/experience.mdc`
describes `angelo ledger record <csv> --graph runs --study <name> --params …
--metrics … --context … --code-files … --command …`, one registration per
result file, LF line endings, stable column names with units.

---

## 4. Proposed instrumentation

All of it hangs off one opt-in object. When the runner does not install it,
every hook is a single `ScopedValue` read that returns `nothing` (Julia
≥ 1.11; the repo targets 1.12.4), so production cost is nil and no function
signature changes.

### 4a. Analysis log in Asap (counts every factorization, by model and stage)

New file `external/Asap/src/Model/analysis/analysis_log.jl`:

```julia
struct AnalysisEvent
    label::String        # stage path set by the caller, e.g. "members/fp_column_check"
    model_id::UInt       # objectid(model)
    kind::Symbol         # :assemble, :factor, :refactor, :rhs, :dense_factor
    n_free::Int          # size of the factored system
    n_rhs::Int           # right-hand sides solved against it
end
mutable struct AnalysisLog
    lock::ReentrantLock
    events::Vector{AnalysisEvent}
end
const ANALYSIS_LOG   = ScopedValue{Union{Nothing,AnalysisLog}}(nothing)
const ANALYSIS_LABEL = ScopedValue{String}("unlabeled")
@inline function log_analysis!(model, kind; n_free = 0, n_rhs = 0)
    log = ANALYSIS_LOG[]
    log === nothing && return nothing
    lock(log.lock) do
        push!(log.events, AnalysisEvent(ANALYSIS_LABEL[], objectid(model), kind, n_free, n_rhs))
    end
end
```

The lock is there because slab sizing and the MIP loops may run tasks in
parallel; `ScopedValue`s are inherited by spawned tasks, so labels stay right.

Hook points (one line each):

| Event | Where |
|---|---|
| `:factor` / `:refactor` | `factorization_cache.jl:68` (next to `_N_FACTORIZATIONS[] += 1`); `:refactor` when the `cholesky!(old, K)` branch at `:73` succeeds, `:factor` otherwise (`:82`) |
| `:factor` (explicit) | `factorization_cache.jl:14-24` (`factorize!`) |
| `:factor` + `:rhs` (rigid diaphragm, today uncounted) | `Elements/rigidlink.jl:217` (`solve!(model, links)`, n_rhs = 1) and `:337` (`solve(model, cases, links)`, n_rhs = `length(cases)`) |
| `:rhs` | `linear_static.jl:11,39,65,93` (n_rhs = 1); `load_case_solves.jl:11,29,48,82,114,127,141,158` (n_rhs = number of cases) |
| `:assemble` | `processing_pipeline.jl:12,37,57,80` (`process!`); `model_updates.jl:133,168,204,230` (`update!` unless `loads_only`) |
| `:dense_factor` | `Nonlinear/pdelta.jl:115,197`, `buckling.jl:48` |

Keep `_N_FACTORIZATIONS` as is; the existing profiling runners read it.

**What counts as a "full FE analysis".** A `:factor` or `:refactor` event
whose `model_id` is the building frame model. SY registers that id: after
`struc.asap_model = Asap.Model(...)` at `SY/analyze/asap/asap/model_builder.jl:582`
and after the archive restore at `SY/design/archive.jl:184`, call
`probe_register_building_model!(struc.asap_model)`. A wall-thickness jump that
rebuilds the model registers the new id automatically. Every other
factorization is reported by model class instead of discarded: FEA slab mesh,
story shell, composite subdivision, mat Winkler — the class is the `label`
leaf (4b), so no Asap-side type tagging is needed. Building RHS solves
(`:rhs` on a building id) are reported separately: one factorization with
12 load cases is one analysis, not 12.

### 4b. Stage labels and stage timing in SY

New file `SY/workflow/sizing_probe.jl`:

```julia
mutable struct SizingProbe
    log::Asap.AnalysisLog
    building_models::Set{UInt}
    spans::Vector{NamedTuple{(:label, :t0, :t1), Tuple{String, Float64, Float64}}}
    loops::Vector{NamedTuple}       # 4c
    sizes::Vector{NamedTuple}       # 4d
end
const SIZING_PROBE = ScopedValue{Union{Nothing,SizingProbe}}(nothing)

"Run `f` under stage `name`; nests as \"parent/name\". No-op without a probe."
function probe_stage(f, name::AbstractString)
    p = SIZING_PROBE[]
    p === nothing && return f()
    label = Asap.ANALYSIS_LABEL[] == "unlabeled" ? name : string(Asap.ANALYSIS_LABEL[], "/", name)
    t0 = time()
    try
        return with(f, Asap.ANALYSIS_LABEL => label)
    finally
        push!(p.spans, (; label, t0, t1 = time()))
    end
end
```

Wrap these call sites (top level = the graph node key, which already names
the stage):

| Label | Hook |
|---|---|
| `prepare` | `SY/design_graph/scheduler.jl:248` (`prepare!`, incremental path); `SY/workflow/execute.jl:130` (`restore = false` path) |
| `<node key>` (`slabs`, `shared_slabs`, `members`, `walls`, `foundations`, …) | body of `run!(node::StageNode, …)`, `SY/design_graph/node.jl:227`; covers both executors |
| `sync/<level>` (barrier analysis, untimed today) | `SY/design_graph/executor.jl:49` and `scheduler.jl:659` |
| `capture` | `scheduler.jl:727-730` (`capture_incremental_design`); `execute.jl:156` |
| `fp_stale_redesign` (L4) | `SY/workflow/graph_builder.jl:382` (settle body) |
| `fp_column_check` (L6) | `SY/workflow/flat_plate_column_check.jl:697` |
| `story_shell` (L11) | `SY/workflow/member_iteration.jl:412` |
| `beam_column` (L9) | `member_iteration.jl:349` |
| `wall_jump` (L12), `wall_rebuild` | `SY/analyze/lateral/ordinary_wall_stage.jl:154`, `:166` (`apply_wall_thickness!`) |
| `walls_member_recheck` (L13) | `SY/workflow/pipeline_spec.jl:184-185` |

Stage runtime = inclusive span time; "self" time = span minus child spans.
This replaces the fragile `:enter`/`:exit` pairing (3b) and gives per-stage
times on the default `restore = true` path, which records nothing today.

### 4c. Loop round counts

One helper, `probe_loop!(id::Symbol; rounds, budget, converged, stop, extra...)`,
called once per loop exit. The four `settle!` loops already return
`(; converged, steps, stop)`, so their hook is the line after the call;
`StructuralSizer.settle!` itself stays untouched.

| Loop | Hook (after) | Fields beyond rounds/budget/converged |
|---|---|---|
| L1/L2 slab kernel | read `iterations`, `fea_rebuilds`, `fea_updates` where `size_flat_plate!` returns into SY (or from the existing `:exit` event, `SS/.../iteration.jl:1130-1135`) | `governing_check` |
| L3 shared-column lock | `graph_builder.jl:687` settle | `n_columns_locked` |
| L4 stale slab | `graph_builder.jl:382` settle | `n_redesigned` |
| L5 reconcile | `column_reconciliation.jl:266-337` exit | `n_grown` (rounds = 1) |
| L6 full-load check | `flat_plate_column_check.jl:697` settle | `n_grown` |
| L7 stacking | `flat_plate_column_check.jl:492-551` exit | `n_grown` |
| L8 harmonize | `member_iteration.jl:26-62` return value | `n_changed` |
| L9 beams ⇄ columns | `member_iteration.jl:369-375` (each call, tagged with the enclosing stage label so L11/L13 calls are separable) | `caller` |
| L10 columns only | `member_iteration.jl:279-294` | — |
| L11 story shell | `member_iteration.jl:446-454` | `shell_passes` |
| L12 wall jump | `ordinary_wall_stage.jl:154` settle | `t_wall_final` per wall group |
| L13 walls ⇄ members | `pipeline_spec.jl:178-193`, **including the early return** | `members_resized::Bool` |
| Mat Winkler | `SS/foundations/codes/aci/mat_footing.jl` sweep exit (SS side: emit a `TraceEvent`; SY copies it) | `steps` |

Keep the existing `TraceCollector` events; the probe does not replace them.

### 4d. Governing reason per element

Report two columns per element, matching the two questions in 3e:

- `util_governor` / `util_ratio` — from the existing
  `*_diagnostic_governing_check` helpers (no new code).
- `size_driver` — **the last rule that changed the size**. Recorded by
  `probe_size!(kind, idx, driver, old, new)` at each writer, only when
  `new != old`. The final driver is the last record for that element; no
  struct fields change.

Column writers (each grow-only):

| `size_driver` | Writer (hook at the assignment) |
|---|---|
| `seed` (with `detail` = which branch: span, axial, clamp to `max_size`) | `SY/analyze/members/members/size_columns.jl:553-554,568-580,584-585` |
| `slab_span_min` / `slab_pm` / `slab_old` | which term wins in `max(c_span_min, c_pm, c_old)`, `SS/.../flat_plate/pipeline/column_updates.jl:108-109` |
| `punching_growth` | `SS/.../flat_plate/pipeline/punching_resolution.jl:129-138` |
| `slab_envelope` | `SY/workflow/graph_builder.jl:489-490` |
| `reconcile_axial` | `SY/workflow/column_reconciliation.jl:284-318` |
| `full_load_pm` | `SY/workflow/flat_plate_column_check.jl:647-648` |
| `stacking` | `flat_plate_column_check.jl:541-542` |
| `harmonize` | `SY/workflow/member_iteration.jl:84-85` |
| `mip_section` / `section_floor` | MIP pick in L9; `section_floor` when the floor from `size_beams_story_shell.jl:200-216` / `frame_section_floors` was binding (picked == floor) |
| `row_f_floor` | `size_columns.jl:238-248` |

The SS-side writers (`column_updates.jl`, `punching_resolution.jl`) cannot see
an SY probe. Have them emit a `TraceEvent` with the column index and term
(SS already emits from these files), and let SY copy the event into the probe.

Slab `size_driver`: flat plate / flat slab use the existing
`governing_check` (copy from `slab.design_details` into the row;
`table_minimum` and `search_floor` already mean "not demand-governed").
Two-way and one-way: constant `min_thickness` (`SS/slabs/codes/concrete/min_thickness.jl:198-203`).
Composite deck: to be confirmed while writing B6 — I did not find where the
deck selection records its governing check.

Wall `size_driver`: `input` if never jumped; otherwise `drift` or
`pier_failure`, recorded where `propose_wall_thicknesses` decides
(`SY/analyze/lateral/wall_thickness_jump.jl:333-341` drift scaling,
`:486-495` pier failures) and applied at `ordinary_wall_stage.jl:166`.

Footing `size_driver`: `group_envelope` when a footing's size came from its
group rather than its own demand (`SY/analyze/foundations/grouping.jl:144-151,300-325`);
otherwise split B and h. I did not trace the exact lines where spread/strip
`B` and `h` are chosen; until they are hooked, report the largest of the
bearing ratio (`B` driver) and the shear/flexure ratios (`h` driver) from
`SY/design/results/foundation.jl:14-21`, labelled `inferred`. Mat:
`mat_bearing` / `mat_punching` / `mat_flexure` likewise inferred.

Add an `oversize` column = `1 / util_ratio` for every element. Seed- or
floor-driven elements with high `oversize` are exactly the Phase 3 targets.

### 4e. Carbon gaps to close before the baseline

1. **Walls**: add `ec_walls` / wall takeoff to `compute_building_ec` and
   `takeoff_by_element` (`SY/postprocess/ec.jl:148-170,288-336`), computing
   volume from wall length × height × thickness at capture time. Without
   this B6–B8 baselines are wrong, and the next fix would look like a carbon
   regression.
2. **Drop panels / shear caps / studs**: split them out of the building totals
   (`SY/design/summary.jl:64-67`) for B3.

Both change reported numbers, so they belong in Phase 0, before the first
baseline is frozen.

---

## 5. Runner and output format

### 5a. `scripts/runners/sizing_baseline.jl`

```bash
SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
  julia --project=StructuralSynthesizer scripts/runners/sizing_baseline.jl \
  --bench B1,B2,B3,B4,B5,B6,B7 --repeat 2 --out logs/sizing_baseline \
  [--workers 4] [--register]
```

- Fixture builders (`build_B1() -> (skel, params)` …) live in
  `scripts/runners/sizing_baseline_fixtures.jl`, so the runner stays small and
  the tests are not edited.
- Each benchmark runs `repeat` times in the same process. Run 1 includes
  compilation: keep its counts, drop its times. Assert that rounds, analysis
  counts, sizes and carbon are identical across repeats (they must be, with
  `:highs` pinned); a mismatch fails the run.
- `--workers` reuses the process pool in `scripts/runners/sweep_design_building.jl`.
- Output directory: `logs/sizing_baseline/<git-short-sha>[-dirty]/`.
- `--register` calls `angelo ledger record` once per CSV (5c).

### 5b. Files

`<bench>.json` — everything for one run:

```json
{
  "bench": "B4", "git_sha": "…", "dirty": false, "julia": "1.12.4",
  "solver": "highs", "threads": 8, "repeat": 2, "status": "ok",
  "params": { "floor": "TwoWayOptions", "stories": 2, "nx": 2, "ny": 2,
              "foundation_strategy": "all_strip", "max_iterations": 20 },
  "stages":   [ { "label": "members/story_shell", "t_incl_s": 41.2, "t_self_s": 3.1,
                  "building_factor": 6, "building_rhs": 72, "local_factor": 18, "assemble": 9 } ],
  "loops":    [ { "loop": "L11", "label": "members", "call": 1, "rounds": 2, "budget": 3,
                  "converged": true, "stop": "settled", "extra": { "shell_passes": 2 } } ],
  "elements": [ { "kind": "column", "id": 7, "story": 1, "size": "20x20 in",
                  "size_driver": "full_load_pm", "detail": "", "util_governor": "pm_interaction",
                  "util_ratio": 0.71, "oversize": 1.41, "ec_kgCO2e": 412.0 } ],
  "summary":  { "...": "DesignSummary flattened as in sweep_case_runner._takeoff_row" }
}
```

`runs.csv` (one row per benchmark run; the ledger file):

| Column | Role | Unit |
|---|---|---|
| `bench`, `floor_type`, `stories`, `nx`, `ny`, `bay_x_m`, `bay_y_m`, `foundation_strategy`, `lateral` | param | — / m |
| `git_sha`, `dirty`, `julia`, `solver`, `threads`, `repeat`, `host` | context | — |
| `status`, `error` | metric | — |
| `t_total_s`, `t_prepare_s`, `t_slabs_s`, `t_members_s`, `t_walls_s`, `t_foundations_s`, `t_sync_s`, `t_capture_s` | metric | s |
| `n_building_factor`, `n_building_rhs`, `n_local_factor`, `n_assemble` | metric | count |
| `ec_total_kgCO2e`, `ec_slabs_kgCO2e`, `ec_beams_kgCO2e`, `ec_columns_kgCO2e`, `ec_walls_kgCO2e`, `ec_foundations_kgCO2e`, `ec_fireproofing_kgCO2e` | metric | kgCO2e |
| existing `_takeoff_row` columns (`slab_concrete_m3`, …) | metric | m³ / kg |
| `rounds_L1` … `rounds_L13`, `rounds_mat` (sum over calls) | metric | count |
| `n_seed_driven_columns`, `n_floor_driven_members`, `max_oversize` | metric | — |

`stages.csv`: `bench, git_sha, label, depth, t_incl_s, t_self_s,
n_building_factor, n_building_rhs, n_local_factor, n_assemble`.

`loops.csv`: `bench, git_sha, loop, label, call, rounds, budget, converged,
stop, extra_json`.

`elements.csv`: `bench, git_sha, kind, id, level, story, size_1, size_2,
size_unit, size_driver, detail, util_governor, util_ratio, oversize,
ec_kgCO2e, volume_m3`. `kind` ∈ {`slab`, `column`, `beam`, `wall`,
`footing`, `mat`}.

### 5c. Ledger registration

```bash
angelo ledger record logs/sizing_baseline/<sha>/runs.csv --graph runs \
  --study sizing_baseline \
  --params bench,floor_type,stories,nx,ny,foundation_strategy,lateral \
  --metrics t_total_s,n_building_factor,ec_total_kgCO2e,… \
  --context git_sha,dirty,julia,solver,threads \
  --code-files StructuralSynthesizer/src/workflow,StructuralSizer/src/slabs \
  --command "julia … sizing_baseline.jl --bench …"
```

Register `stages.csv`, `loops.csv` and `elements.csv` the same way under
studies `sizing_baseline_stages`, `…_loops`, `…_elements`. Every refactor PR
then reruns the runner and compares against the frozen baseline sha.

---

## 6. Order of work and sign-off items

1. **Phase 0 (changes numbers):** wall carbon and drop-panel split (4e).
   Freeze nothing before these land.
2. **Instrumentation (no number changes):** 4a Asap log, 4b stage labels,
   4c loop hooks, 4d size drivers. Verify with B1 that totals match today's
   `DesignSummary` exactly and that `n_building_factor` from the new log
   equals `_N_FACTORIZATIONS` on a non-diaphragm model (B1 has no links).
3. **Fixtures:** B1–B5, B7 builders (small edits), then B6 after the
   sign-off below.
4. **Baseline:** two repeats per benchmark, registered in the ledger.

Needs the user before code is written:

- B6 seismic system row and lateral inputs (2b items 1–2).
- B6 fallback if a deck edge cannot bear on a wall (2b item 3).
- Whether B8 (~16 min) runs in the baseline or weekly only.
- Wall carbon: concrete and rebar EC factors for walls — reuse the column
  concrete/rebar factors, or a wall-specific rebar ratio? (Rebar quantity in
  walls is not captured anywhere today.)
- Whether `oversize = 1 / util_ratio` is the right target metric (plan O4 proposes the second), or
  oversize should be measured against the size the MIP/kernel would pick with
  the seed removed (more informative, but costs one extra sizing run per
  benchmark).
