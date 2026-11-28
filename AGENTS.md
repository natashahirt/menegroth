# AGENTS.md

**menegroth** is a Julia codebase for automated structural engineering design. Dependency chain: `Asap` (FEM + units, git submodule at `external/Asap`) → `StructuralSizer` (sizing library) → `StructuralSynthesizer` (building workflow + REST API). Targets **Julia 1.12.4**.

**Environment / setup issues** (Cursor Cloud, backslash paths in `Project.toml`, submodules, Gurobi license, Slack bot, doc & trace audit workflows, corpus MCP registration): read `docs/agent-setup.md`.

**Sizing loops and element dependencies:** before changing how any element is sized, read `docs/sizing-map/README.md` (stage order, every iterative loop, decision space, ranked size/speed issues, open sign-off items).

## Running tests

**Use the quiet runner** — it logs full output to `logs/` and prints only the summary and failure excerpts. Prefer targeted test files over the full suite.

```bash
julia scripts/runners/test_quiet.jl StructuralSynthesizer core/test_walls_bridge.jl   # files relative to <Pkg>/test/
julia scripts/runners/test_quiet.jl StructuralSizer                                  # full suite
```

**Persistent test server (avoids re-precompiling after every edit).** Start one per package in a long-lived terminal; `test_quiet.jl` then routes to it automatically and Revise applies source edits in seconds. Pass `--fresh` to `test_quiet.jl` to force a clean process (use it for final verification, since package-level state persists in the server). If Revise cannot apply an edit, the run fails without testing; fix the error or restart the server.

```bash
julia scripts/runners/test_server.jl StructuralSynthesizer   # leave running; Ctrl-C to stop
```

Raw `Pkg.test()` (verbose; avoid in agent sessions):

```bash
# StructuralSizer (~6 min)
SS_ENABLE_VISUALIZATION=false julia --project=StructuralSizer -e 'using Pkg; Pkg.test()'
# StructuralSynthesizer (~20 min)
SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer -e 'using Pkg; Pkg.test()'
```

Known failures: `test_voronoi_vis.jl` needs a display (fails headless); Gurobi-dependent tests error without a license (HiGHS is the production fallback).

## Running the API

```bash
SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
```

`/health` and `/status` respond immediately; `/design`, `/validate`, `/schema` after ~60 s background load.

## Conventions

- Runner scripts go in `scripts/runners/`; prefer Julia runners over shell one-liners.
- Env vars: `SS_ENABLE_VISUALIZATION=false` (skip GLMakie), `SS_SKIP_SOLVER_WARMUP=true` (skip JuMP warmup in short-lived processes).
- Precompile workloads are set by preferences, not env vars: `julia scripts/runners/dev_precompile.jl off|on|heavy|status`. StructuralSynthesizer's heavy workload is opt-in (`heavy`); `SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD` is no longer read.
- After changing dependencies, run `julia scripts/runners/compare_manifests.jl`; version mismatches between environments cause duplicate precompiles.
